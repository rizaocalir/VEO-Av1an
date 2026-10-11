"""Convert VEO (Video Encoding Optimizer) output into an Av1an ``--zones`` file.

Supported inputs
----------------
1. ``veo per-segment analyze`` stdout table (primary path - VEO currently has
   no ``-o`` flag on this command, so the human-readable table is parsed).
2. ``veo per-shot analyze`` stdout: shot headers plus the Trellis assignment
   table (requires ``--target-bitrate > 0`` so VEO emits the table).
3. ``veo per-shot detect`` stdout table (boundaries only, no CRF).
4. A JSON dump in VEO's ``Result`` schema (e.g. produced by a patched VEO that
   calls ``SaveJSON``). NOTE: Go's ``time.Duration`` serializes as *nanoseconds*;
   this module auto-detects ns vs s.

The module is pure: no subprocess calls, so it is fully unit-testable.
"""

from __future__ import annotations

import json
import math
import re
import statistics
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Encoder mapping: VEO reports FFmpeg codec names (libx264, libsvtav1, ...),
# Av1an wants its own encoder names. Each entry maps to the Av1an encoder id,
# the encoder flag used to set CRF inside a zone line, and the valid CRF range.
# ---------------------------------------------------------------------------
ENCODER_MAP: dict[str, tuple[str, str, int, int]] = {
    "libsvtav1": ("svt-av1", "--crf {}", 0, 63),
    "svt-av1": ("svt-av1", "--crf {}", 0, 63),
    "libx264": ("x264", "--crf {}", 0, 51),
    "x264": ("x264", "--crf {}", 0, 51),
    "libx265": ("x265", "--crf {}", 0, 51),
    "x265": ("x265", "--crf {}", 0, 51),
    "libaom-av1": ("aom", "--cq-level={}", 0, 63),
    "aom": ("aom", "--cq-level={}", 0, 63),
    # rav1e uses a quantizer scale (0-255), not CRF - mapping is not linear,
    # so it is intentionally unsupported for now. TODO: map CRF -> quantizer.
}

# Time values coming from VEO JSON are Go time.Duration = nanoseconds.
# Any duration > ~11 days in seconds must actually be nanoseconds.
_NS_THRESHOLD = 1_000_000.0


@dataclass
class Segment:
    """A time range with an optional CRF decision (seconds, end-exclusive)."""

    start: float
    end: float
    crf: float | None = None


@dataclass
class Zone:
    """One line of an Av1an zones file."""

    start_frame: int
    end_frame: int  # exclusive; -1 = end of video
    encoder: str
    video_params: str


@dataclass
class ConvertReport:
    """Statistics about the conversion, surfaced to the user."""

    input_segments: int = 0
    output_zones: int = 0
    dropped_short: int = 0
    merged_adjacent: int = 0
    clipped_overlaps: int = 0
    clamped_crf: int = 0
    uncovered_lead: float = 0.0  # seconds before the first zone
    uncovered_tail: float = 0.0  # seconds after the last zone
    warnings: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Stdout parsing (VEO table formats, verified against terranvigil/veo main)
# ---------------------------------------------------------------------------

# per-segment row: "  1   0.0-2.0s    45   28   1234 kbps   93.2   3"
_RE_SEGMENT = re.compile(
    r"^\s*\d+\s+"
    r"(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)s\s+"   # start-end s
    r"(\d+(?:\.\d+)?)\s+"                   # complexity
    r"(\d+)\s+"                             # crf
    r"(\d+(?:\.\d+)?)\s*kbps\s+"            # bitrate
    r"(\d+(?:\.\d+)?)\s+"                   # vmaf
    r"\d+\s*$"                              # iterations
)

# per-shot header: "  Shot 2 (4.2s - 9.8s, 5.6s):"
_RE_SHOT_HEADER = re.compile(
    r"^\s*Shot\s+(\d+)\s*\(\s*(\d+(?:\.\d+)?)s\s*-\s*(\d+(?:\.\d+)?)s"
)

# Trellis assignment row: "    1   720p   libx264   28   1500 kbps   94.5"
_RE_TRELLIS = re.compile(
    r"^\s*(\d+)\s+"                         # shot index (1-based)
    r"\S+\s+"                               # resolution label
    r"\S+\s+"                               # codec
    r"(\d+)\s+"                             # crf
    r"(\d+(?:\.\d+)?)\s*kbps\s+"            # bitrate
    r"(\d+(?:\.\d+)?)\s*$"                  # vmaf
)

# per-shot detect row: "  1   0.00s   4.17s   4.17s" (index start end duration)
_RE_DETECT = re.compile(
    r"^\s*(\d+)\s+"
    r"(\d+(?:\.\d+)?)s\s+"
    r"(\d+(?:\.\d+)?)s\s+"
    r"(\d+(?:\.\d+)?)s\s*$"
)


def parse_veo_stdout(text: str) -> list[Segment]:
    """Parse any VEO stdout table into segments.

    Tries, in order: per-segment analyze rows, per-shot analyze headers
    combined with the Trellis table, per-shot detect rows.
    """
    # 1) per-segment analyze table
    segments: list[Segment] = []
    for line in text.splitlines():
        m = _RE_SEGMENT.match(line)
        if m:
            start, end = float(m.group(1)), float(m.group(2))
            segments.append(Segment(start=start, end=end, crf=int(m.group(4))))
    if segments:
        return segments

    # 2) per-shot analyze: shot headers + trellis CRF per shot index
    shots: dict[int, Segment] = {}
    for line in text.splitlines():
        m = _RE_SHOT_HEADER.match(line)
        if m:
            idx = int(m.group(1))
            shots[idx] = Segment(start=float(m.group(2)), end=float(m.group(3)))
    trellis: dict[int, int] = {}
    for line in text.splitlines():
        m = _RE_TRELLIS.match(line)
        if m:
            trellis[int(m.group(1))] = int(m.group(2))
    if shots:
        return [
            Segment(start=s.start, end=s.end, crf=trellis.get(i))
            for i, s in sorted(shots.items())
        ]

    # 3) per-shot detect table (no CRF available)
    for line in text.splitlines():
        m = _RE_DETECT.match(line)
        if m:
            segments.append(
                Segment(start=float(m.group(2)), end=float(m.group(3)))
            )
    return segments


# ---------------------------------------------------------------------------
# JSON parsing (VEO Result schema - nanosecond durations)
# ---------------------------------------------------------------------------

def _to_seconds(value: float, max_val: float) -> float:
    """Return seconds; treat the value as nanoseconds when it is implausibly
    large to be seconds (Go time.Duration marshals as int64 ns)."""
    if max_val > _NS_THRESHOLD:
        return value / 1e9
    return value


def _crf_pick(crf_data: dict | list | float | int | None, strategy: str) -> float | None:
    """Resolve a single CRF from whatever VEO emitted: scalar, {min,max},
    or a list of candidate values."""
    if crf_data is None:
        return None
    if isinstance(crf_data, (int, float)):
        return float(crf_data)
    if isinstance(crf_data, list):
        vals = [float(v) for v in crf_data]
        if not vals:
            return None
        if strategy == "median":
            return statistics.median(vals)
        if strategy == "midpoint":
            return (min(vals) + max(vals)) / 2
        if strategy == "min":
            return min(vals)
        if strategy == "max":
            return max(vals)
        return statistics.median(vals)
    if isinstance(crf_data, dict):
        lo, hi = crf_data.get("min"), crf_data.get("max")
        if lo is not None and hi is not None:
            return (float(lo) + float(hi)) / 2
        return None
    return None


def parse_veo_json(data: dict | str | Path, crf_strategy: str = "median",
                   target_vmaf: float | None = None) -> list[Segment]:
    """Parse a VEO JSON dump (per-segment or per-shot Result schema)."""
    if isinstance(data, (str, Path)):
        data = json.loads(Path(data).read_text())

    segments: list[Segment] = []

    # --- per-segment schema ---
    if "segments" in data:
        ends = [float(s.get("end", 0)) for s in data["segments"]]
        max_end = max(ends, default=0.0)
        for s in data["segments"]:
            crf = _crf_pick(
                s.get("crf", s.get("crf_range", s.get("crf_values"))),
                crf_strategy,
            )
            segments.append(
                Segment(
                    start=_to_seconds(float(s["start"]), max_end),
                    end=_to_seconds(float(s["end"]), max_end),
                    crf=crf,
                )
            )
        return segments

    # --- per-shot schema ---
    if "shots" in data:
        ends = [
            float(sr.get("shot", {}).get("end", 0)) for sr in data["shots"]
        ]
        max_end = max(ends, default=0.0)

        # Trellis assignments (authoritative CRF per shot when present)
        assign: dict[int, float] = {}
        for a in data.get("assignments", []):
            assign[int(a["shot_index"])] = float(a["crf"])

        for i, sr in enumerate(data["shots"]):
            shot = sr.get("shot", sr)
            crf = assign.get(i, assign.get(i + 1))
            if crf is None:
                # Fall back to the hull point closest to the target VMAF.
                crf = _crf_from_hull(sr.get("hull"), target_vmaf)
            segments.append(
                Segment(
                    start=_to_seconds(float(shot.get("start", 0)), max_end),
                    end=_to_seconds(float(shot.get("end", 0)), max_end),
                    crf=crf,
                )
            )
    return segments


def _crf_from_hull(hull: dict | None, target_vmaf: float | None) -> float | None:
    """Pick the hull point whose VMAF is closest to the target."""
    if not hull or target_vmaf is None:
        return None
    points = hull.get("points") or []
    if not points:
        return None
    best = min(points, key=lambda p: abs(float(p.get("vmaf", 0)) - target_vmaf))
    return float(best.get("crf", 0))


# ---------------------------------------------------------------------------
# Conversion to Av1an zones
# ---------------------------------------------------------------------------

def seconds_to_frames(t: float, fps: float) -> int:
    return int(round(t * fps))


def _clamp(v: float, lo: int, hi: int) -> int:
    return int(max(lo, min(hi, round(v))))


def to_zone_frames(
    segments: list[Segment],
    fps: float,
    total_frames: int,
    encoder: str,
    default_crf: int | None = None,
    min_scene_frames: int = 24,
    extra_zone_params: str = "",
    report: ConvertReport | None = None,
) -> list[Zone]:
    """Normalize time segments into Av1an zone rows.

    Steps: sort, clip overlaps, convert s->frames, clamp CRF, merge adjacent
    identical zones, merge too-short zones into their neighbour.
    """
    if report is None:
        report = ConvertReport()
    if encoder not in {v[0] for v in ENCODER_MAP.values()}:
        raise ValueError(
            f"unsupported Av1an encoder {encoder!r}; "
            f"supported: {sorted({v[0] for v in ENCODER_MAP.values()})}"
        )
    enc_entry = next(v for v in ENCODER_MAP.values() if v[0] == encoder)
    _, crf_flag, crf_lo, crf_hi = enc_entry

    report.input_segments = len(segments)
    segs = sorted(
        (s for s in segments if s.end > s.start), key=lambda s: s.start
    )
    if not segs:
        report.warnings.append("no usable segments from VEO output")
        return []

    # Clip overlaps: a later segment's start wins over an earlier segment's end.
    clipped: list[Segment] = []
    for s in segs:
        if clipped and s.start < clipped[-1].end:
            clipped[-1] = Segment(
                clipped[-1].start, s.start, clipped[-1].crf
            )
            report.clipped_overlaps += 1
        clipped.append(s)
    segs = [s for s in clipped if s.end > s.start]

    # Convert to frame boundaries.
    zones: list[Zone] = []
    for s in segs:
        crf = s.crf if s.crf is not None else default_crf
        if crf is None:
            report.warnings.append(
                f"segment {s.start:.2f}-{s.end:.2f}s has no CRF; "
                "zone inherits Av1an defaults (skipped)"
            )
            continue
        clamped = _clamp(crf, crf_lo, crf_hi)
        if clamped != round(crf):
            report.clamped_crf += 1
        params = crf_flag.format(clamped)
        if extra_zone_params:
            params = f"{params} {extra_zone_params}"
        zones.append(
            Zone(
                start_frame=seconds_to_frames(s.start, fps),
                end_frame=seconds_to_frames(s.end, fps),
                encoder=encoder,
                video_params=params,
            )
        )
    if not zones:
        return []

    # Merge adjacent zones with identical params (avoid pointless splits).
    merged: list[Zone] = []
    for z in zones:
        if (
            merged
            and z.start_frame <= merged[-1].end_frame
            and z.video_params == merged[-1].video_params
            and z.encoder == merged[-1].encoder
        ):
            merged[-1].end_frame = max(merged[-1].end_frame, z.end_frame)
            report.merged_adjacent += 1
        else:
            merged.append(Zone(z.start_frame, z.end_frame, z.encoder,
                               z.video_params))
    zones = merged

    # Enforce minimum scene length by merging short zones into the neighbour
    # with the closest CRF distance (previous wins on ties).
    zones = _enforce_min_length(zones, min_scene_frames, report)

    # Clamp into [0, total_frames]; last zone ending at the video end uses -1.
    zones = [z for z in zones if z.end_frame > 0 and z.start_frame < total_frames]
    for z in zones:
        z.start_frame = max(0, z.start_frame)
        z.end_frame = min(z.end_frame, total_frames)
    if zones:
        if zones[0].start_frame > 0:
            report.uncovered_lead = zones[0].start_frame / fps
        if zones[-1].end_frame >= total_frames - 1:
            zones[-1].end_frame = -1
        elif zones[-1].end_frame > 0:
            report.uncovered_tail = (total_frames - zones[-1].end_frame) / fps

    report.output_zones = len(zones)
    return zones


def _crf_of(zone: Zone) -> float:
    m = re.search(r"(\d+(?:\.\d+)?)", zone.video_params)
    return float(m.group(1)) if m else 0.0


def _enforce_min_length(
    zones: list[Zone], min_frames: int, report: ConvertReport
) -> list[Zone]:
    """Merge zones shorter than min_frames into the neighbouring zone whose
    CRF is closest. Repeats until stable (a merge can create new shorts)."""
    zones = [Zone(z.start_frame, z.end_frame, z.encoder, z.video_params)
             for z in zones]
    changed = True
    while changed and len(zones) > 1:
        changed = False
        for i, z in enumerate(zones):
            if z.end_frame - z.start_frame >= min_frames:
                continue
            prev_ok = i > 0
            next_ok = i < len(zones) - 1
            if not prev_ok and not next_ok:
                break
            # choose merge target by CRF proximity
            crf = _crf_of(z)
            candidates = []
            if prev_ok:
                candidates.append((abs(_crf_of(zones[i - 1]) - crf), i - 1))
            if next_ok:
                candidates.append((abs(_crf_of(zones[i + 1]) - crf), i + 1))
            candidates.sort(key=lambda c: (c[0], -c[1]))  # prev wins ties
            j = candidates[0][1]
            if j < i:
                zones[j].end_frame = z.end_frame
            else:
                zones[j].start_frame = z.start_frame
            del zones[i]
            report.dropped_short += 1
            changed = True
            break
    return zones


def render_zones(zones: list[Zone]) -> str:
    """Render zones to the Av1an zones file format:
    ``start_frame end_frame encoder video_params`` (end exclusive, -1 = EOF).
    """
    lines = [f"{z.start_frame} {z.end_frame} {z.encoder} {z.video_params}"
             for z in zones]
    return "\n".join(lines) + "\n" if lines else ""


def convert(
    veo_text: str | None,
    veo_json: str | Path | None,
    fps: float,
    total_frames: int,
    encoder: str,
    **kwargs,
) -> tuple[str, ConvertReport]:
    """High-level helper: parse VEO output and render the zones file text."""
    report = ConvertReport()
    if veo_json is not None:
        segments = parse_veo_json(veo_json, target_vmaf=kwargs.get("target_vmaf"))
    elif veo_text is not None:
        segments = parse_veo_stdout(veo_text)
    else:
        raise ValueError("either veo_text or veo_json is required")

    zones = to_zone_frames(
        segments,
        fps=fps,
        total_frames=total_frames,
        encoder=encoder,
        default_crf=kwargs.get("default_crf"),
        min_scene_frames=kwargs.get("min_scene_frames", 24),
        extra_zone_params=kwargs.get("extra_zone_params", ""),
        report=report,
    )
    return render_zones(zones), report
