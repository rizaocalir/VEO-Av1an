# VEO-Av1an Bridge

Tek komutla: **VEO** ([terranvigil/veo](https://github.com/terranvigil/veo))
ile sahne/segment bazlı CRF analizi yapar, sonucu **Av1an**'ın `--zones`
formatına çevirir ve paralel encode eder.

```
input.mkv ──► VEO analizi ──► (başlangıç, bitiş, CRF) ──► zones.txt ──► Av1an ──► out.mkv
```

## Neden Python (Rust değil)?

- Köprü tamamen *orkestrasyon*: subprocess çağrısı + tablo/JSON ayrıştırma +
  metin üretme. Derlenmiş dile ihtiyaç yok.
- VEO Go, Av1an Rust — ikisi de kütüphane olarak kullanılmıyor, ikisi de
  CLI. Yani Rust'a geçmek hiçbir entegrasyon avantajı sağlamaz.
- Python 3.10+ standart kütüphane neredeyse yeterli (tek bağımlılık: PyYAML,
  yalnızca `--config` için). Birim testleri `unittest` ile sıfır bağımlılıkla
  çalışır.
- macOS/Linux/Windows uyumlu, taşıması ve okuması kolay.

## Proje yapısı

```
VEO-Av1an/
├── bridge.py            # CLI + orkestrasyon (subprocess, hata yönetimi)
├── veo_to_av1an.py      # saf dönüştürücü modül (IO'suz, birim testli)
├── config.yaml          # tüm varsayılanlar
├── requirements.txt     # PyYAML (tek bağımlılık, opsiyonel kullanım)
├── examples/            # gerçek VEO çıktı örnekleri + beklenen zones.txt
├── tests/               # birim testleri (python -m unittest)
└── README.md
```

## Kurulum

```bash
# Gereksinimler: Python 3.10+, FFmpeg (ffprobe dahil), VEO, Av1an
pip install -r requirements.txt   # yalnızca --config kullanacaksanız
```

VEO ve Av1an'ın PATH'te olması gerekir:

```bash
# VEO (Go):
git clone https://github.com/terranvigil/veo && cd veo && make build
# Av1an (Rust): https://github.com/rust-av/Av1an — cargo install av1an
```

## Kullanım

```bash
python bridge.py --input video.mkv --output out.mkv \
    --target-vmaf 95 --encoder svt-av1 --workers 8
```

Per-shot (Trellis) modu:

```bash
python bridge.py --input video.mkv --output out.mkv \
    --veo-mode per-shot --target-bitrate 2000 --encoder svt-av1
```

Önceden kaydedilmiş VEO JSON'u ile (VEO'yu tekrar çalıştırmaz):

```bash
python bridge.py --input video.mkv --output out.mkv --veo-json result.json
```

Komutları çalıştırmadan görmek için `--dry-run`, tüm seçenekler için
`python bridge.py --help` ya da `config.yaml`.

## Mimari akış

```
┌────────────┐   ┌─────────────────┐   ┌──────────────────┐   ┌─────────┐
│  ffprobe   │──►│  VEO (subproc.) │──►│ veo_to_av1an.py  │──►│ Av1an   │
│ fps+frames │   │ per-segment/    │   │ parse→normalize→ │   │ --zones │
│            │   │ per-shot        │   │ zones.txt        │   │         │
└────────────┘   └─────────────────┘   └──────────────────┘   └─────────┘
                                            │
                              isteğe bağlı: --verify-vmaf
                              (ffmpeg libvmaf, hedef kontrolü)
```

## ÖNEMLİ: VEO'nun gerçek çıktı durumu (kaynak koddan doğrulandı)

VEO'nun şu anki `main` sürümünde (terranvigil/veo):

| Komut | `-o` JSON? | Gerçek çıktı |
|---|---|---|
| `per-title analyze` | ✅ çalışıyor | `results.json` |
| `per-shot analyze` | ⚠️ bayrak var ama **kullanılmıyor** (dead flag) | yalnızca stdout tablosu |
| `per-segment analyze` | ❌ bayrak yok | yalnızca stdout tablosu |
| `per-shot detect` | ❌ | stdout tablosu |
| `quality measure -o` | ✅ | `vmaf_data.json` |

Bu yüzden köprü **iki yolu da** destekler:

1. Varsayılan: VEO'nun **stdout tablosunu ayrıştırır** (`veo_stdout.txt`
   workdir'e kaydedilir).
2. `--veo-json`: VEO'nun `Result` şemasına uygun bir JSON dosyası (örn.
   VEO'ya `SaveJSON` ekleyerek ürettiğiniz). Dikkat: Go `time.Duration`
   JSON'a **nanosaniye** olarak yazılır — modül bunu otomatik algılar.

`examples/` altında gerçek formatlara birebir uyan örnekler var.

### Varsayımlar / TODO

- **TODO(veo-schema):** VEO ileride `per-segment`/`per-shot` için gerçek
  `-o` JSON desteği eklerse `--veo-json` yolu zaten hazır; alan adları
  değişirse `parse_veo_json` içindeki eşlemeyi güncelleyin.
- **TODO(rav1e):** rav1e quantizer (0-255) doğrusal CRF değil; şimdilik
  desteklenmiyor.
- CRF aralığı verilirse `crf_pick` stratejisi (median|midpoint|min|max)
  tek değere indirgenir.
- Zones'ların kapsamadığı baş/son bölümler Av1an'ın genel parametreleriyle
  encode edilir (uyarı loglanır).

## Zones formatı (Av1an)

Her satır: `start_frame end_frame encoder video_params` — start dahil,
end hariç, `-1` = video sonu. Örnek:

```
0 48 svt-av1 --crf 38
48 96 svt-av1 --crf 24
96 -1 svt-av1 --crf 30
```

Dönüşüm kuralları:

- saniye → frame: `round(t * fps)` (end exclusive)
- çakışan segmentler: sonraki segmentin başlangıcı kazanır (önceki kırpılır)
- aynı CRF'li bitişik segmentler birleştirilir
- `min_scene_len`'den kısa zone'lar CRF'si en yakın komşuya birleştirilir
- CRF, encoder aralığına kenetlenir (svt-av1 0-63, x264/x265 0-51, aom 0-63)

## Hata senaryoları

| Durum | Davranış | Çıkış kodu |
|---|---|---|
| `veo`/`av1an`/`ffprobe` PATH'te yok | Araç listesi loglanır, başlamadan çıkar | 6 |
| `ffprobe` fps/frame sayısı bulamaz | Net hata mesajı | 7 |
| Disk alanı < ~3x girdi boyutu | Başlamadan çıkar (`disk_space_factor`) | 5 |
| VEO sıfır-dışı çıkış | stderr log yolunu gösterir, durur | 2 |
| VEO çıktısı ayrıştırılamaz / zone yok | `default_crf` denenir; yine yoksa durur | 3 |
| Av1an zones'u reddeder | `--fallback-no-zones` ile zones'suz tekrar dener | 4 |
| Av1an çöker / çıktı üretmez | stderr log + çıkış | 4 |
| VMAF hedefi tutmaz | `--verify-vmaf` ile ölçülür, WARNING loglanır | 0 (bildirim) |

## Test planı

```bash
# Birim testleri (bağımlılık yok):
python -m unittest discover -s tests -v

# Uçtan uca mini test (küçük sentetik video):
ffmpeg -f lavfi -i "testsrc=duration=6:size=320x240:rate=24" \
    -c:v libx264 -preset ultrafast -y /tmp/test_input.mkv
python bridge.py --input /tmp/test_input.mkv --output /tmp/out.mkv \
    --veo-json examples/veo_persegment.json --encoder svt-av1 --workers 8
```

Beklenen: `zones.txt` `examples/zones_example.txt` deseninde üretilir,
Av1an tek birleşik dosya çıkarır. `--verify-vmaf` eklenirse sonuç VMAF
loglanır.

## Lisans

MIT — ayrıca `LICENSE` dosyasına bakın. (VEO Apache-2.0, Av1an GPL-3.0;
bu köprü bağımsız bir orkestratördür, kod içermez.)
