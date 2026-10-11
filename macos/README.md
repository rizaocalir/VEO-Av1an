![VEO-Av1an Bridge](../docs/banner.png)

# VEO Av1an Bridge — macOS app

**[Türkçe](README.tr.md)** | English

A native macOS app written in SwiftUI. It ports the Python bridge's
(`../bridge.py`, `../veo_to_av1an.py`) logic to Swift and invokes
`veo`/`av1an`/`ffprobe`/`ffmpeg` directly via `Process`.

## Features

- Drag-and-drop input video, output picker
- Per-segment / per-shot analysis mode, encoder choice
  (svt-av1/x264/x265/aom)
- Target VMAF slider, worker count, advanced parameters
- Live log window, phase indicator, progress bar, cancel
- Zones generated in-app (ZoneConverter.swift — a port of the Python
  module)
- Tool lookup: bundle `tools/` first, then PATH + Homebrew/cargo dirs

## System requirements (user)

The distributed `.app` runs with zero installation — `veo`, `av1an`,
the encoder binaries and `mkvmerge` are embedded
(`Contents/Resources/tools/`).

- **macOS 13.0+**, Apple Silicon M-series (M1…M5; embedded tools are
  arm64 — on Intel Macs the tools must be on PATH instead)
- **ffprobe + ffmpeg** — on PATH for input probing and remux
  (`/opt/homebrew/bin`, `/usr/local/bin` etc. are searched):
  `brew install ffmpeg`
- **Disk:** a few times the source video's size free (Av1an temp
  chunks)
- The app is unsigned: on first launch right-click → **Open**, or
  `xattr -dr com.apple.quarantine "VEO Av1an Bridge.app"`

Recommended input: yuv420p pixel format, even width/height. Output can
be `.mp4` or `.mkv` (`.mp4` is produced by a lossless
`ffmpeg -c copy` remux after encoding). Analysis time grows with video
length (VEO re-encodes each segment a few times as a probe).

## Build requirements (developer)

- Xcode 15+, XcodeGen (`brew install xcodegen`)
- Place `veo` and `av1an` binaries under `macos/tools/`
  (arm64 builds from terranvigil/veo and rust-av/Av1an with the
  `../patches/` applied)

## Build

```bash
brew install xcodegen        # once
cd macos
xcodegen                   # generates VEOAv1an.xcodeproj
open VEOAv1an.xcodeproj    # open in Xcode, ⌘R to run
```

Or from the command line:

```bash
xcodebuild -project VEOAv1an.xcodeproj -scheme VEOAv1an \
    -configuration Debug build
xcodebuild -project VEOAv1an.xcodeproj -scheme VEOAv1an test
```

Signing is set to "Run Locally" (`CODE_SIGN_IDENTITY=-`) — no
developer account needed.

## Unit tests

`VEOAv1anTests/ZoneConverterTests.swift` — the exact same scenarios as
`tests/test_veo_to_av1an.py` on the Python side.

## Layout

```
macos/
├── project.yml              # XcodeGen spec
├── VEOAv1an/
│   ├── VEOAv1anApp.swift    # @main
│   ├── ContentView.swift    # UI (files, settings, controls, log)
│   ├── Pipeline.swift       # Process orchestration + phase handling
│   ├── ZoneConverter.swift  # VEO -> zones converter (Swift port)
│   └── ToolLocator.swift    # bundle/PATH/Homebrew tool lookup
└── VEOAv1anTests/
    └── ZoneConverterTests.swift
```
