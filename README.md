![VEO-Av1an Bridge](docs/banner.png)

# VEO-Av1an Bridge

**[Türkçe](README.tr.md)** | English

One command: run **VEO** ([terranvigil/veo](https://github.com/terranvigil/veo))
scene/segment CRF analysis, convert the results into **Av1an** `--zones`
format, and encode in parallel to a single output file.

```
input.mkv ──► VEO analysis ──► (start, end, CRF) ──► zones.txt ──► Av1an ──► out.mkv
```

A native macOS app lives in [`macos/`](macos/README.md) — it embeds
patched `veo`/`av1an`/encoder binaries so nothing needs to be installed
except ffmpeg.

## Why Python (not Rust)?

- The bridge is pure *orchestration*: subprocess calls + table/JSON
  parsing + text generation. No compiled language needed.
- VEO is Go, Av1an is Rust — neither is used as a library; both are
  CLIs. Rust would gain no integration advantage.
- Python 3.10+ stdlib is almost sufficient (only dependency: PyYAML,
  used only for `--config`). Unit tests run on plain `unittest` with
  zero dependencies.
- Portable and readable across macOS/Linux/Windows.

## Project layout

```
VEO-Av1an/
├── bridge.py            # CLI + orchestration (subprocess, error handling)
├── veo_to_av1an.py      # pure converter module (no IO, unit-tested)
├── config.yaml          # all defaults
├── requirements.txt     # PyYAML (single dependency, optional use)
├── examples/            # real VEO output samples + expected zones.txt
├── tests/               # unit tests (python -m unittest)
├── macos/               # native SwiftUI app (bundled tools)
├── patches/             # patches applied to the bundled veo/av1an
└── README.md
```

## Install

```bash
# Requirements: Python 3.10+, FFmpeg (incl. ffprobe), VEO, Av1an
pip install -r requirements.txt   # only if you use --config
```

VEO and Av1an must be on PATH:

```bash
# VEO (Go):
git clone https://github.com/terranvigil/veo && cd veo && make build
# Av1an (Rust): https://github.com/rust-av/Av1an — cargo install av1an
```

## Usage

```bash
python bridge.py --input video.mkv --output out.mkv \
    --target-vmaf 95 --encoder svt-av1 --workers 8
```

Per-shot (Trellis) mode:

```bash
python bridge.py --input video.mkv --output out.mkv \
    --veo-mode per-shot --target-bitrate 2000 --encoder svt-av1
```

With a pre-saved VEO JSON (skips running VEO again):

```bash
python bridge.py --input video.mkv --output out.mkv --veo-json result.json
```

Use `--dry-run` to print the commands without executing, and
`python bridge.py --help` or `config.yaml` for all options.

## Architecture

```
┌────────────┐   ┌─────────────────┐   ┌──────────────────┐   ┌─────────┐
│  ffprobe   │──►│  VEO (subproc.) │──►│ veo_to_av1an.py  │──►│ Av1an   │
│ fps+frames │   │ per-segment/    │   │ parse→normalize→ │   │ --zones │
│            │   │ per-shot        │   │ zones.txt        │   │         │
└────────────┘   └─────────────────┘   └──────────────────┘   └─────────┘
                                            │
                              optional: --verify-vmaf
                              (ffmpeg libvmaf, target check)
```

## IMPORTANT: VEO's real output status (verified from source)

In VEO's current `main` (terranvigil/veo):

| Command | `-o` JSON? | Real output |
|---|---|---|
| `per-title analyze` | ✅ works | `results.json` |
| `per-shot analyze` | ⚠️ flag exists but is **unused** (dead flag) | stdout table only |
| `per-segment analyze` | ❌ no flag | stdout table only |
| `per-shot detect` | ❌ | stdout table |
| `quality measure -o` | ✅ | `vmaf_data.json` |

So the bridge supports **both paths**:

1. Default: parse VEO's **stdout table** (`veo_stdout.txt` is saved to
   the workdir).
2. `--veo-json`: a JSON file matching VEO's `Result` schema (e.g. one
   produced by adding `SaveJSON` to VEO). Note: Go `time.Duration` is
   serialized as **nanoseconds** — the module detects that automatically.

`examples/` contains samples matching the real formats exactly.

### Assumptions / TODO

- **TODO(veo-schema):** if VEO later adds real `-o` JSON support to
  `per-segment`/`per-shot`, the `--veo-json` path is ready; update the
  field mapping in `parse_veo_json` if names change.
- **TODO(rav1e):** rav1e quantizer (0-255) is not a linear CRF;
  unsupported for now.
- A CRF range is reduced to a single value via the `crf_pick` strategy
  (median|midpoint|min|max).
- Head/tail parts not covered by zones are encoded with Av1an's global
  parameters (a warning is logged).

## Zones format (Av1an)

Each line: `start_frame end_frame encoder video_params` — start
inclusive, end exclusive, `-1` = end of video. Example:

```
0 48 svt-av1 --crf 38
48 96 svt-av1 --crf 24
96 -1 svt-av1 --crf 30
```

Conversion rules:

- seconds → frames: `round(t * fps)` (end exclusive)
- overlapping segments: the later segment's start wins (the earlier
  one is clipped)
- adjacent segments with the same CRF are merged
- zones shorter than `min_scene_len` are merged into the
  closest-CRF neighbor
- CRF is clamped to the encoder range (svt-av1 0-63, x264/x265 0-51,
  aom 0-63)

## Error scenarios

| Case | Behavior | Exit code |
|---|---|---|
| `veo`/`av1an`/`ffprobe` not on PATH | Tool list logged, exits before starting | 6 |
| `ffprobe` can't determine fps/frame count | Clear error message | 7 |
| Disk space < ~3x input size | Exits before starting (`disk_space_factor`) | 5 |
| VEO exits non-zero | Shows stderr log path, stops | 2 |
| VEO output unparseable / no zones | Tries `default_crf`; else stops | 3 |
| Av1an rejects zones | Retries without zones if `--fallback-no-zones` | 4 |
| Av1an crashes / produces no output | stderr log + exit | 4 |
| VMAF target missed | Measured with `--verify-vmaf`, WARNING logged | 0 (notice) |

## Test plan

```bash
# Unit tests (no dependencies):
python -m unittest discover -s tests -v

# Mini end-to-end test (small synthetic video):
ffmpeg -f lavfi -i "testsrc=duration=6:size=320x240:rate=24" \
    -c:v libx264 -preset ultrafast -y /tmp/test_input.mkv
python bridge.py --input /tmp/test_input.mkv --output /tmp/out.mkv \
    --veo-json examples/veo_persegment.json --encoder svt-av1 --workers 8
```

Expected: `zones.txt` matching the `examples/zones_example.txt`
pattern, and Av1an produces a single merged file. With
`--verify-vmaf` the resulting VMAF is logged.

## License

MIT — see `LICENSE`. (VEO is Apache-2.0, Av1an is GPL-3.0; this bridge
is an independent orchestrator and contains none of their code.)
