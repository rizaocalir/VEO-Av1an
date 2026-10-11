# VEO Av1an Bridge — macOS uygulaması

SwiftUI ile yazılmış native macOS uygulaması. Python köprüsünün
(`../bridge.py`, `../veo_to_av1an.py`) mantığını Swift'e taşır ve
`veo`/`av1an`/`ffprobe`/`ffmpeg` komutlarını doğrudan `Process` ile çağırır.

## Özellikler

- Sürükle-bırak girdi videosu, çıktı seçici
- Per-segment / per-shot analiz modu, encoder seçimi (svt-av1/x264/x265/aom)
- Hedef VMAF kaydırıcısı, işçi sayısı, gelişmiş parametreler
- Canlı log penceresi, faz göstergesi, ilerleme çubuğu, iptal
- Zones üretimi uygulama içinde (ZoneConverter.swift — Python portu)
- Araç arama: PATH + Homebrew/cargo dizinleri

## Gereksinimler

- macOS 13+, Xcode 15+
- `veo`, `av1an`, `ffprobe` (ve `--verify-vmaf` için `ffmpeg`) PATH'te
  (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin` da taranır)

## Derleme

```bash
brew install xcodegen        # bir kez
cd macos
xcodegen                   # VEOAv1an.xcodeproj üretir
open VEOAv1an.xcodeproj    # Xcode'da aç, ⌘R ile çalıştır
```

Ya da komut satırından:

```bash
xcodebuild -project VEOAv1an.xcodeproj -scheme VEOAv1an \
    -configuration Debug build
xcodebuild -project VEOAv1an.xcodeproj -scheme VEOAv1an test
```

İmzalama "Run Locally" (`CODE_SIGN_IDENTITY=-`) olarak ayarlı — geliştirici
hesabı gerekmez.

## Birim testleri

`VEOAv1anTests/ZoneConverterTests.swift` — Python taraftaki
`tests/test_veo_to_av1an.py` ile birebir aynı senaryolar.

## Yapı

```
macos/
├── project.yml              # XcodeGen spec
├── VEOAv1an/
│   ├── VEOAv1anApp.swift    # @main
│   ├── ContentView.swift    # UI (dosyalar, ayarlar, kontroller, log)
│   ├── Pipeline.swift       # Process orkestrasyonu + faz yönetimi
│   ├── ZoneConverter.swift  # VEO -> zones dönüştürücü (Swift port)
│   └── ToolLocator.swift    # PATH/Homebrew araç bulma
└── VEOAv1anTests/
    └── ZoneConverterTests.swift
```
