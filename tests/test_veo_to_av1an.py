"""Unit tests for veo_to_av1an. Run:  python -m unittest discover -s tests -v
(or: pytest tests/)"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import veo_to_av1an as conv

EXAMPLES = Path(__file__).resolve().parent.parent / "examples"


class ParseStdoutTests(unittest.TestCase):
    def test_persegment_table(self):
        text = (EXAMPLES / "veo_persegment_stdout.txt").read_text()
        segs = conv.parse_veo_stdout(text)
        self.assertEqual(len(segs), 5)
        self.assertEqual(segs[0], conv.Segment(0.0, 2.0, 38))
        self.assertEqual(segs[3], conv.Segment(6.0, 8.0, 21))

    def test_pershot_table_with_trellis(self):
        text = (EXAMPLES / "veo_pershot_stdout.txt").read_text()
        segs = conv.parse_veo_stdout(text)
        self.assertEqual(len(segs), 3)
        self.assertEqual(segs[0], conv.Segment(0.0, 4.2, 30))
        self.assertEqual(segs[1], conv.Segment(4.2, 9.8, 24))
        self.assertEqual(segs[2], conv.Segment(9.8, 12.0, 34))

    def test_detect_table_no_crf(self):
        text = (EXAMPLES / "veo_detect_stdout.txt").read_text()
        segs = conv.parse_veo_stdout(text)
        self.assertEqual(len(segs), 3)
        self.assertIsNone(segs[0].crf)
        self.assertAlmostEqual(segs[1].start, 4.17)

    def test_garbage_input(self):
        self.assertEqual(conv.parse_veo_stdout("not a table\nfoo bar"), [])


class ParseJsonTests(unittest.TestCase):
    def test_persegment_nanoseconds(self):
        data = json.loads((EXAMPLES / "veo_persegment.json").read_text())
        segs = conv.parse_veo_json(data)
        self.assertEqual(len(segs), 3)
        # durations in the file are Go nanoseconds -> converted to seconds
        self.assertEqual(segs[1], conv.Segment(2.0, 4.0, 24))

    def test_seconds_passthrough(self):
        # If a future VEO emits seconds, nothing changes.
        data = {"segments": [{"start": 0.0, "end": 2.0, "crf": 33}]}
        segs = conv.parse_veo_json(data)
        self.assertEqual(segs[0], conv.Segment(0.0, 2.0, 33.0))

    def test_pershot_with_assignments(self):
        data = {
            "shots": [
                {"shot": {"index": 0, "start": 0, "end": 4200000000}},
                {"shot": {"index": 1, "start": 4200000000,
                          "end": 9800000000}},
            ],
            "assignments": [
                {"shot_index": 0, "crf": 30, "bitrate": 1800, "vmaf": 94.2},
                {"shot_index": 1, "crf": 24, "bitrate": 3100, "vmaf": 94.8},
            ],
        }
        segs = conv.parse_veo_json(data)
        self.assertEqual([s.crf for s in segs], [30, 24])
        self.assertAlmostEqual(segs[1].end, 9.8)

    def test_pershot_hull_fallback(self):
        data = {
            "shots": [
                {"shot": {"start": 0.0, "end": 4.0},
                 "hull": {"points": [
                     {"crf": 20, "vmaf": 97.0},
                     {"crf": 32, "vmaf": 93.5},
                     {"crf": 40, "vmaf": 90.0},
                 ]}},
            ],
        }
        segs = conv.parse_veo_json(data, target_vmaf=93.0)
        self.assertEqual(segs[0].crf, 32)

    def test_crf_range_strategies(self):
        self.assertEqual(conv._crf_pick({"min": 20, "max": 30}, "midpoint"),
                         25.0)
        self.assertEqual(conv._crf_pick([20, 30, 26], "median"), 26.0)
        self.assertEqual(conv._crf_pick([20, 30, 26], "min"), 20.0)
        self.assertIsNone(conv._crf_pick(None, "median"))


class ZoneConversionTests(unittest.TestCase):
    KW = dict(fps=24.0, total_frames=240, encoder="svt-av1",
              min_scene_frames=24)

    def zones(self, segs, **kw):
        opts = dict(self.KW)
        opts.update(kw)
        report = conv.ConvertReport()
        zones = conv.to_zone_frames(segs, report=report, **opts)
        return zones, report

    def test_basic(self):
        segs = [conv.Segment(0, 2, 38), conv.Segment(2, 10, 24)]
        zones, _ = self.zones(segs)
        self.assertEqual(
            conv.render_zones(zones),
            "0 48 svt-av1 --crf 38\n48 -1 svt-av1 --crf 24\n",
        )

    def test_overlap_clipped(self):
        segs = [conv.Segment(0, 3, 30), conv.Segment(2, 6, 25)]
        zones, report = self.zones(segs)
        self.assertEqual(report.clipped_overlaps, 1)
        self.assertEqual(zones[0].end_frame, 48)  # clipped at next start
        self.assertEqual(zones[1].start_frame, 48)

    def test_adjacent_same_crf_merged(self):
        segs = [conv.Segment(0, 1, 30), conv.Segment(1, 5, 30),
                conv.Segment(5, 10, 22)]
        zones, report = self.zones(segs)
        self.assertEqual(len(zones), 2)
        self.assertEqual(report.merged_adjacent, 1)

    def test_short_zone_merged_into_neighbour(self):
        # 0.25s = 6 frames at 24fps < min 24 -> merges into the closest CRF
        segs = [conv.Segment(0, 4, 30), conv.Segment(4, 4.25, 50),
                conv.Segment(4.25, 10, 32)]
        zones, report = self.zones(segs)
        self.assertEqual(len(zones), 2)
        self.assertEqual(report.dropped_short, 1)
        # closer CRF distance: |32-50|=18 < |30-50|=20 -> merged forward
        self.assertEqual(zones[1].start_frame, 96)

    def test_crf_clamped_to_encoder_range(self):
        segs = [conv.Segment(0, 5, 80)]  # > 63 for svt-av1
        zones, report = self.zones(segs)
        self.assertIn("--crf 63", zones[0].video_params)
        self.assertEqual(report.clamped_crf, 1)

    def test_encoder_specific_flag(self):
        segs = [conv.Segment(0, 5, 28)]
        zones, _ = self.zones(segs, encoder="aom")
        self.assertIn("--cq-level=28", zones[0].video_params)
        zones, _ = self.zones(segs, encoder="x265")
        self.assertIn("--crf 28", zones[0].video_params)

    def test_last_zone_eof_marker(self):
        segs = [conv.Segment(0, 3, 30), conv.Segment(3, 10, 25)]
        zones, _ = self.zones(segs)
        self.assertEqual(zones[-1].end_frame, -1)
        self.assertEqual(zones[0].end_frame, 72)

    def test_uncovered_lead_and_tail_reported(self):
        segs = [conv.Segment(2, 8, 30)]
        zones, report = self.zones(segs)
        self.assertAlmostEqual(report.uncovered_lead, 2.0)
        self.assertAlmostEqual(report.uncovered_tail, 2.0)
        self.assertEqual(zones[0].start_frame, 48)
        self.assertEqual(zones[0].end_frame, 192)  # not -1, tail uncovered

    def test_missing_crf_uses_default(self):
        segs = [conv.Segment(0, 5, None)]
        zones, _ = self.zones(segs, default_crf=31)
        self.assertIn("--crf 31", zones[0].video_params)

    def test_no_crf_no_default_skips_with_warning(self):
        segs = [conv.Segment(0, 5, None)]
        zones, report = self.zones(segs)
        self.assertEqual(zones, [])
        self.assertTrue(report.warnings)

    def test_extra_zone_params_appended(self):
        segs = [conv.Segment(0, 5, 30)]
        zones, _ = self.zones(segs, extra_zone_params="--photon-noise 4")
        self.assertEqual(zones[0].video_params, "--crf 30 --photon-noise 4")

    def test_unsupported_encoder_raises(self):
        with self.assertRaises(ValueError):
            self.zones([conv.Segment(0, 5, 30)], encoder="rav1e")

    def test_empty_input(self):
        zones, report = self.zones([])
        self.assertEqual(zones, [])
        self.assertTrue(report.warnings)


class EndToEndTests(unittest.TestCase):
    def test_example_round_trip(self):
        text = (EXAMPLES / "veo_persegment_stdout.txt").read_text()
        zones_text, report = conv.convert(
            veo_text=text, veo_json=None, fps=24.0, total_frames=240,
            encoder="svt-av1", default_crf=30, min_scene_frames=24,
        )
        expected = (EXAMPLES / "zones_example.txt").read_text()
        self.assertEqual(zones_text, expected)
        self.assertEqual(report.output_zones, 5)

    def test_json_and_stdout_agree(self):
        text = (EXAMPLES / "veo_persegment_stdout.txt").read_text()
        data = json.loads((EXAMPLES / "veo_persegment.json").read_text())
        kw = dict(fps=24.0, total_frames=144, encoder="svt-av1",
                  min_scene_frames=24)
        a, _ = conv.convert(veo_text=text, veo_json=None, **kw)
        b, _ = conv.convert(veo_text=None, veo_json=data, **kw)
        # The JSON example is a prefix of the stdout example.
        self.assertTrue(a.startswith(b))


if __name__ == "__main__":
    unittest.main()
