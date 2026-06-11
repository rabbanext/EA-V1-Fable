# XAU Trend Capture v1

EA MT5 untuk XAUUSD — trend following via breakout Donchian H1 terkonfirmasi filter arah
H4. Modal acuan $100.000, risiko flat 0,5%/trade. Blueprint final terkunci; repo ini
adalah fase **implementasi & validasi**.

## Status pekerjaan

| Langkah | Deliverable | Status |
|---|---|---|
| 1 | Arsitektur & pseudocode — [`docs/01_arsitektur_pseudocode.md`](docs/01_arsitektur_pseudocode.md) | ✅ |
| 2 | Implementasi MQL5 penuh (`MQL5/`) — lihat [`MQL5/README.md`](MQL5/README.md) | ✅ kode lengkap, ⚠️ belum dikompilasi pemilik |
| 3 | Rencana backtest — [`docs/02_rencana_backtest.md`](docs/02_rencana_backtest.md) + kalender news [`analysis/generate_news_calendar.py`](analysis/generate_news_calendar.py) | ✅ |
| 4 | Skrip analisis Python (`analysis/`) | ⬜ |
| 5 | Checklist pre-demo & pre-live | ⬜ |

> **KEPUTUSAN TERBUKA:** modal < $1.000 di akun Standard membuat spek tidak bisa trade
> (gap cap < lot minimum). Rekomendasi: **Exness Standard Cent**. Hitungan lengkap:
> [`docs/00_catatan_modal_akun.md`](docs/00_catatan_modal_akun.md).

## Aturan main (ringkas)

- Satu strategi, sizing flat, hard SL di server, tanpa BE-1R/partial close.
- Ruang eksperimen dibekukan: slope filter on/off × time-stop {none, 48, 96} = 6 kombinasi.
- Semua angka kinerja net-of-swap; swap baris biaya terpisah.
- Versi naik hanya dibayar bukti out-of-sample/live.

Spesifikasi lengkap & keputusan tertutup: lihat dokumen blueprint (sumber kebenaran) dan
`docs/01_arsitektur_pseudocode.md`.

## Konteks akun

Akun **standard** (tanpa komisi, spread markup) — model biaya backtest: komisi 0, spread
mengikuti feed standard. Detail di §0.1 dokumen arsitektur.
