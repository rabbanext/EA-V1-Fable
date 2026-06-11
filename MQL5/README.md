# Instalasi & Kompilasi (Windows + MetaEditor)

## 1. Salin file ke data folder terminal

Buka MT5 → `File → Open Data Folder` → masuk ke `MQL5/`. Salin isi repo ini dengan
struktur yang sama:

```
<DataFolder>/MQL5/Experts/XAUTrendCapture/XAUTrendCapture_v1.mq5
<DataFolder>/MQL5/Include/XAUTrendCapture/*.mqh
<DataFolder>/MQL5/Scripts/XAUTrendCapture/Tests/*.mq5
```

`#include <XAUTrendCapture/...>` menunjuk ke `MQL5/Include/XAUTrendCapture/` — struktur
folder WAJIB persis seperti di atas.

## 2. Kompilasi

Di MetaEditor buka `XAUTrendCapture_v1.mq5` → F7. Kompilasi juga ketiga skrip test.

> Kode ini ditulis tanpa akses compiler. Kalau ada error/warning kompilasi, tempelkan
> output-nya apa adanya — perbaikan adalah bagian dari pekerjaan, bukan kejutan.

## 3. Jalankan unit test DULU

Seret ketiga skrip `Test_*.ex5` ke chart mana pun, baca tab **Experts**:
`... 0 FAIL — OK` semua sebelum lanjut ke Strategy Tester. Test gagal = stop, lapor.

## 4. Kalender news (WAJIB sebelum backtest/live)

EA menolak start tanpa `XTC_news_calendar.csv` (by design — backtest tanpa news filter
adalah backtest sistem lain). Letakkan di `<DataFolder>/MQL5/Files/` ATAU folder Common
(`Terminal/Common/Files/` — dibutuhkan agen Strategy Tester). Format, waktu **GMT**:

```
# YYYY.MM.DD HH:MM;TAG
2024.06.07 12:30;NFP
2024.06.12 12:30;CPI
2024.06.12 18:00;FOMC
```

Pembuatan file 10 tahun penuh = Langkah 3. Stub contoh: `data/news/contoh_format.csv`.
`InpAllowNoNews=true` hanya untuk debug kompilasi — hasil run-nya tidak sah.

## 5. Output yang dihasilkan EA

| File (Files atau Common) | Isi |
|---|---|
| `XTC_decisions_<sym>_slope<0/1>_ts<n>.csv` | setiap keputusan: entry/reject/exit/trail + konteksnya |
| `XTC_trades_<...>.csv` | trade list per posisi: gross, **swap terpisah**, net, R-multiple — kontrak data skrip Python |
| `XTC_counters_<...>.csv` | counter sinyal-terblokir per alasan (metrik slot uji time-stop) |
| `XTC_state_<...>.txt` | status persisten live (HWM, anchor, kill flag, trade state) |

## 6. Verifikasi 5 menit di akun kamu (docs/00)

Klik kanan simbol → **Specification**: catat *Contract size, Min/Step volume, Tick value,
Swap long/short*, dan bandingkan jam Market Watch vs UTC (input offset default 0 = Exness).
Tempelkan hasilnya ke percakapan.
