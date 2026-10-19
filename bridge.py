#!/usr/bin/env python3
"""VEO -> Av1an bridge.

Pipeline:
    1. Probe input (fps, frame count) via ffprobe.
    2. Run VEO analysis (per-segment or per-shot) as a subprocess.
    3. Parse VEO's output into (start, end, CRF) segments.
    4. Convert segments into an Av1an zones file.
    5. Run Av1an with --zones to produce the final encoded file.
    6. Optionally verify the result's VMAF against the source.

Usage:
    python bridge.py --input video.mkv --output out.mkv \
        --target-vmaf 95 --encoder svt-av1 --workers 8
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import veo_to_av1an as conv

log = logging.getLogger("bridge")

# Exit codes (documented; lets wrappers react to failure classes)
EXIT_OK = 0
EXIT_VEO_FAILED = 2
EXIT_NO_SEGMENTS = 3
EXIT_AV1AN_FAILED = 4
EXIT_DISK_SPACE = 5
EXIT_MISSING_TOOL = 6
EXIT_PROBE_FAILED = 7
EXIT_BAD_CONFIG = 8

DEFAULTS = {
    "veo_binary": "veo",
    "av1an_binary": "av1an",
    "ffprobe_binary": "ffprobe",
    "ffmpeg_binary": "ffmpeg",
    "veo_mode": "per-segment",          # per-segment | per-shot
    "veo_json": None,                   # pre-saved VEO JSON (skip VEO run)
    "encoder": "svt-av1",
    "veo_codec": None,                  # codec VEO analyzes with (default: follows --encoder)
    "veo_preset": "medium",
    "target_vmaf": 93.0,
    "target_bitrate": 2000,             # kbps, per-shot Trellis budget
    "shot_threshold": 10.0,
    "workers": 0,                       # 0 = Av1an decides
    "encoder_params": None,             # Av1an --video-params (default: per-encoder map)
    "extra_zone_params": "",            # appended to every zone's params
    "default_crf": 30,                  # fallback for segments without CRF
    "crf_pick": "median",               # how to pick CRF from ranges/lists
    "min_scene_len": 24,                # frames; zones shorter get merged
    "audio_params": "-c:a copy",
    "tmp_dir": "",                      # empty = system temp
    "keep_workdir": False,
    "disk_space_factor": 3.0,           # need ~factor x input size free
    "verify_vmaf": False,
    "log_level": "INFO",
    "fallback_no_zones": False,         # retry without zones if Av1an rejects
    "dry_run": False,
}


@dataclass
class Config:
    vals: dict = field(default_factory=lambda: dict(DEFAULTS))

    def __getattr__(self, name):
        try:
            return self.vals[name]
        except KeyError:
            raise AttributeError(name) from None

    def set(self, name, value):
        if value is not None:
            self.vals[name] = value


# Av1an -v defaults per encoder (mirrors the macOS app's Encoders
# .defaultParams): flag syntax differs — x264/x265 named presets,
# svt-av1 numeric, aom --cpu-used (av1an rejects --crf for aom).
DEFAULT_ENCODER_PARAMS = {
    "svt-av1": "--preset 6",
    "x264": "--preset medium",
    "x265": "--preset medium",
    "aom": "--cpu-used=6 --end-usage=q",
}

# FFmpeg codec VEO analyzes with, per Av1an encoder.
VEO_CODEC_FOR = {
    "svt-av1": "libsvtav1",
    "x264": "libx264",
    "x265": "libx265",
    "aom": "libaom-av1",
}


# veo forwards --preset verbatim to ffmpeg's -preset. libsvtav1 only
# accepts a numeric preset, so x264-style names must be translated.
# libaom-av1 has no -preset at all — return "" to omit the flag.
def veo_preset_arg(codec: str, preset: str) -> str:
    if codec == "libsvtav1":
        m = {"placebo": "3", "veryslow": "4", "slower": "5", "slow": "6",
             "medium": "8", "fast": "10", "faster": "11", "veryfast": "11",
             "superfast": "12", "ultrafast": "13"}
        p = preset.lower()
        return m.get(p, p if p.isdigit() else "8")
    if codec == "libaom-av1":
        return ""
    return preset


# ---------------------------------------------------------------------------
# Config / CLI
# ---------------------------------------------------------------------------

def load_config(path: str | None) -> Config:
    cfg = Config()
    if path:
        p = Path(path)
        if not p.exists():
            raise SystemExit(f"config file not found: {p}")
        try:
            import yaml  # PyYAML
        except ImportError:
            raise SystemExit(
                "PyYAML is required for --config (pip install pyyaml); "
                "all options are also available as CLI flags."
            )
        data = yaml.safe_load(p.read_text()) or {}
        unknown = set(data) - set(DEFAULTS)
        if unknown:
            log.warning("unknown config keys ignored: %s", sorted(unknown))
        for k, v in data.items():
            if k in DEFAULTS:
                cfg.vals[k] = v
    return cfg


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Bridge VEO analysis into Av1an scene-based encoding."
    )
    p.add_argument("--input", required=True, help="input video file")
    p.add_argument("--output", required=True, help="output video file")
    p.add_argument("--config", help="YAML config file (see config.yaml)")
    p.add_argument("--veo-mode", choices=["per-segment", "per-shot"],
                   help="VEO analysis mode")
    p.add_argument("--veo-json", help="pre-saved VEO JSON result "
                   "(skips running VEO)")
    p.add_argument("--target-vmaf", type=float, help="target VMAF score")
    p.add_argument("--target-bitrate", type=float,
                   help="avg bitrate budget kbps (per-shot Trellis)")
    p.add_argument("--encoder",
                   choices=sorted({v[0] for v in conv.ENCODER_MAP.values()}),
                   help="Av1an encoder")
    p.add_argument("--veo-codec", help="codec VEO analyzes with (libx264 ...)")
    p.add_argument("--workers", type=int, help="Av1an worker count")
    p.add_argument("--encoder-params", help="Av1an --video-params")
    p.add_argument("--extra-zone-params",
                   help="extra params appended to every zone line")
    p.add_argument("--default-crf", type=int, help="CRF for segments w/o one")
    p.add_argument("--crf-pick",
                   choices=["median", "midpoint", "min", "max"],
                   help="how to pick CRF from a range/list")
    p.add_argument("--min-scene-len", type=int,
                   help="min zone length in frames")
    p.add_argument("--tmp-dir", help="working directory for zones/VEO output")
    p.add_argument("--keep-workdir", action="store_true", default=None,
                   help="keep temporary workdir after the run")
    p.add_argument("--verify-vmaf", action="store_true", default=None,
                   help="measure VMAF of the output vs input afterwards")
    p.add_argument("--fallback-no-zones", action="store_true", default=None,
                   help="retry Av1an without --zones if it rejects them")
    p.add_argument("--dry-run", action="store_true", default=None,
                   help="print the commands without running them")
    p.add_argument("--log-level",
                   choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                   help="logging verbosity")
    return p


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def require_tools(cfg: Config) -> None:
    missing = [b for b in (cfg.av1an_binary, cfg.ffprobe_binary)
               if shutil.which(b) is None]
    if cfg.veo_json is None and shutil.which(cfg.veo_binary) is None:
        missing.append(cfg.veo_binary)
    if cfg.verify_vmaf and shutil.which(cfg.ffmpeg_binary) is None:
        missing.append(cfg.ffmpeg_binary)
    if missing:
        log.error("required tools not found on PATH: %s", ", ".join(missing))
        sys.exit(EXIT_MISSING_TOOL)


def probe_video(path: str, ffprobe: str) -> tuple[float, int]:
    """Return (fps, total_frames) for the first video stream."""
    cmd = [
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=avg_frame_rate,nb_frames,duration",
        "-show_entries", "format=duration",  # MKV often lacks stream duration
        "-of", "json", path,
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True,
                             encoding="utf-8", errors="replace",
                             check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        log.error("ffprobe failed on %s: %s", path, e)
        sys.exit(EXIT_PROBE_FAILED)
    probed = json.loads(out)
    stream = (probed.get("streams") or [{}])[0]
    num, den = stream.get("avg_frame_rate", "0/1").split("/")
    fps = float(num) / float(den) if float(den) else 0.0
    if fps <= 0:
        log.error("could not determine fps of %s", path)
        sys.exit(EXIT_PROBE_FAILED)
    frames = int(stream.get("nb_frames") or 0)
    if frames <= 0:
        duration = stream.get("duration") or \
            probed.get("format", {}).get("duration") or 0
        frames = math.ceil(float(duration) * fps)
    if frames <= 0:
        log.error("could not determine frame count of %s", path)
        sys.exit(EXIT_PROBE_FAILED)
    return fps, frames


def check_disk_space(cfg: Config, input_path: str, workdir: str) -> None:
    need = int(os.path.getsize(input_path) * cfg.disk_space_factor)
    free = shutil.disk_usage(workdir).free
    if free < need:
        log.error(
            "insufficient disk space in %s: need ~%.1f GiB, have %.1f GiB",
            workdir, need / 2**30, free / 2**30,
        )
        sys.exit(EXIT_DISK_SPACE)


def run(cmd: list[str], log_file: Path | None, dry_run: bool,
        desc: str) -> subprocess.CompletedProcess:
    log.info("%s: %s", desc, " ".join(cmd))
    if dry_run:
        return subprocess.CompletedProcess(cmd, 0, "", "")
    fh = open(log_file, "w", encoding="utf-8") if log_file else subprocess.DEVNULL
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                              stderr=fh, text=True,
                              encoding="utf-8", errors="replace")
    finally:
        if hasattr(fh, "close"):
            fh.close()
    return proc


def build_veo_cmd(cfg: Config, input_path: str) -> list[str]:
    codec = cfg.veo_codec or VEO_CODEC_FOR.get(cfg.encoder, "libsvtav1")
    preset = veo_preset_arg(codec, cfg.veo_preset)
    if cfg.veo_mode == "per-shot":
        cmd = [
            cfg.veo_binary, "per-shot", "analyze", "-i", input_path,
            "--threshold", str(cfg.shot_threshold),
            "--target-bitrate", str(cfg.target_bitrate),
            "--codecs", codec,
        ]
        if preset:
            cmd += ["--preset", preset]
        return cmd
    cmd = [
        cfg.veo_binary, "per-segment", "analyze", "-i", input_path,
        "--codec", codec, "--target-vmaf", str(cfg.target_vmaf),
    ]
    if preset:
        cmd += ["--preset", preset]
    return cmd


def build_av1an_cmd(cfg: Config, input_path: str, output_path: str,
                    zones_path: Path | None) -> list[str]:
    cmd = [
        cfg.av1an_binary, "-i", input_path, "-o", output_path,
        "-e", cfg.encoder,
        "-v", cfg.encoder_params or DEFAULT_ENCODER_PARAMS.get(
            cfg.encoder, ""),
        "-a", cfg.audio_params,
        # `segment` chunks by timestamp — VFR-safe; `select` miscounts
        # frames on variable-frame-rate inputs (e.g. phone recordings).
        "--chunk-method", "segment", "--ignore-frame-mismatch",
        "-y",
    ]
    if cfg.workers:
        cmd += ["-w", str(cfg.workers)]
    if zones_path is not None:
        cmd += ["--zones", str(zones_path)]
    return cmd


def verify_vmaf(cfg: Config, source: str, encoded: str,
                workdir: Path) -> float | None:
    """Measure VMAF of `encoded` against `source`; return mean score."""
    log_path = workdir / "vmaf.json"
    cmd = [
        cfg.ffmpeg_binary, "-i", encoded, "-i", source,
        "-lavfi", f"libvmaf=log_path={log_path}:log_fmt=json",
        "-f", "null", "-",
    ]
    proc = run(cmd, workdir / "ffmpeg_vmaf.log", cfg.dry_run,
               "VMAF verification")
    if proc.returncode != 0 or not log_path.exists():
        log.warning("VMAF verification failed (see ffmpeg_vmaf.log)")
        return None
    try:
        score = json.loads(log_path.read_text())["pooled_metrics"]["vmaf"]["mean"]
    except (KeyError, json.JSONDecodeError):
        log.warning("could not parse VMAF log %s", log_path)
        return None
    return float(score)


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def main() -> int:
    args = build_parser().parse_args()
    try:
        cfg = load_config(args.config)
    except SystemExit as e:
        print(e, file=sys.stderr)
        return EXIT_BAD_CONFIG

    for key in ("veo_mode", "veo_json", "target_vmaf", "target_bitrate",
                "encoder", "veo_codec", "workers", "encoder_params",
                "extra_zone_params", "default_crf", "crf_pick",
                "min_scene_len", "tmp_dir", "keep_workdir", "verify_vmaf",
                "fallback_no_zones", "dry_run", "log_level"):
        cli_val = getattr(args, key.replace("-", "_"), None)
        cfg.set(key, cli_val)

    logging.basicConfig(
        level=getattr(logging, cfg.log_level),
        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S",
    )

    if not Path(args.input).exists():
        log.error("input file not found: %s", args.input)
        return EXIT_BAD_CONFIG

    require_tools(cfg)

    # Working directory for intermediate artifacts
    tmp_base = cfg.tmp_dir or None
    workdir = Path(tempfile.mkdtemp(prefix="veo-av1an-", dir=tmp_base))
    log.info("workdir: %s", workdir)
    if not cfg.keep_workdir:
        pass  # cleaned at the end

    try:
        check_disk_space(cfg, args.input, str(workdir))
        fps, total_frames = probe_video(args.input, cfg.ffprobe_binary)
        log.info("input: %.4f fps, %d frames", fps, total_frames)

        # --- Step 1+2: VEO analysis ---
        veo_json_path = cfg.veo_json
        veo_text: str | None = None
        if veo_json_path:
            log.info("using pre-saved VEO JSON: %s", veo_json_path)
        else:
            veo_cmd = build_veo_cmd(cfg, args.input)
            proc = run(veo_cmd, workdir / "veo_stderr.log", cfg.dry_run,
                       "VEO analysis")
            (workdir / "veo_stdout.txt").write_text(proc.stdout or "",
                                                  encoding="utf-8")
            if proc.returncode != 0:
                log.error("VEO failed (exit %d); stderr: %s",
                          proc.returncode, workdir / "veo_stderr.log")
                return EXIT_VEO_FAILED
            veo_text = proc.stdout
            log.debug("VEO stdout saved to %s", workdir / "veo_stdout.txt")

        # --- Step 3+4: convert to zones ---
        try:
            zones_text, report = conv.convert(
                veo_text=veo_text,
                veo_json=veo_json_path,
                fps=fps,
                total_frames=total_frames,
                encoder=cfg.encoder,
                default_crf=cfg.default_crf,
                min_scene_frames=cfg.min_scene_len,
                extra_zone_params=cfg.extra_zone_params,
                target_vmaf=cfg.target_vmaf,
            )
        except (ValueError, KeyError, json.JSONDecodeError) as e:
            log.error("VEO output could not be converted: %s", e)
            return EXIT_NO_SEGMENTS

        log.info(
            "conversion: %d segments -> %d zones "
            "(short merged: %d, overlaps clipped: %d, crf clamped: %d)",
            report.input_segments, report.output_zones, report.dropped_short,
            report.clipped_overlaps, report.clamped_crf,
        )
        for w in report.warnings:
            log.warning("%s", w)
        if report.uncovered_lead or report.uncovered_tail:
            log.warning(
                "zones do not cover the whole video "
                "(lead: %.2fs, tail: %.2fs) - those parts use global params",
                report.uncovered_lead, report.uncovered_tail,
            )
        if not zones_text.strip():
            log.error("no zones produced; nothing to pass to Av1an")
            return EXIT_NO_SEGMENTS

        zones_path = workdir / "zones.txt"
        zones_path.write_text(zones_text, encoding="utf-8")
        log.info("zones file: %s\n%s", zones_path, zones_text.rstrip())

        # --- Step 5: Av1an ---
        av1an_cmd = build_av1an_cmd(cfg, args.input, args.output, zones_path)
        proc = run(av1an_cmd, workdir / "av1an_stderr.log", cfg.dry_run,
                   "Av1an encode")
        if proc.returncode != 0 and cfg.fallback_no_zones:
            log.warning("Av1an rejected zones; retrying without --zones")
            proc = run(
                build_av1an_cmd(cfg, args.input, args.output, None),
                workdir / "av1an_stderr2.log", cfg.dry_run,
                "Av1an encode (no zones)")
        if proc.returncode != 0:
            log.error("Av1an failed (exit %d); log: %s",
                      proc.returncode, workdir / "av1an_stderr.log")
            return EXIT_AV1AN_FAILED

        if not cfg.dry_run and not Path(args.output).exists():
            log.error("Av1an exited 0 but output is missing: %s", args.output)
            return EXIT_AV1AN_FAILED

        # --- Step 6: optional VMAF check ---
        if cfg.verify_vmaf and not cfg.dry_run:
            score = verify_vmaf(cfg, args.input, args.output, workdir)
            if score is not None:
                delta = score - cfg.target_vmaf
                msg = "output VMAF: %.2f (target %.1f, delta %+.2f)"
                (log.info if delta >= -1.0 else log.warning)(msg, score,
                                                             cfg.target_vmaf,
                                                             delta)

        # warn when the encode grew the file — the source was already
        # compressed; suggest lowering the VMAF target
        if not cfg.dry_run:
            in_size = os.path.getsize(args.input)
            out_size = os.path.getsize(args.output)
            if out_size > in_size:
                log.warning(
                    "output (%.1f MB) is larger than input (%.1f MB) - "
                    "the source is already compressed; lower target_vmaf "
                    "(e.g. 88-90)",
                    out_size / 2**20, in_size / 2**20)

        log.info("done: %s", args.output)
        return EXIT_OK
    finally:
        if cfg.keep_workdir or cfg.dry_run:
            log.info("workdir kept: %s", workdir)
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
