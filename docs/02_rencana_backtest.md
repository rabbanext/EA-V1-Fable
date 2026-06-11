# Langkah 3 — Rencana Backtest

**XAU Trend Capture v1** · Dokumen ini = deliverable Langkah 3.

---

## 0. Profil akun yang dipakai

| Fase | Akun | Simbol | Equity | Satuan lot |
|---|---|---|---|---|
| Backtest & demo | Exness Standard Demo | XAUUSDm | $10.000 | 100 oz/lot |
| Live nyata nanti | Exness Standard Cent | XAUUSDc | $100 real (= 10.000 cents) | 1 oz/lot |

EA tidak berubah; ia membaca spek simbol secara dinamis. Rasio risiko/sizing identik antara
demo dan cent — hanya skala dollarnya berbeda 100×.

---

## 1. Konfigurasi Strategy Tester

```
Symbol       : XAUUSDm
Period       : H1  (EA berjalan di H1; multi-TF H4 diambil lewat handle iMA)
Model        : Every tick based on real ticks  ← WAJIB; mode lain = distribusi R palsu
Deposit      : 10 000 USD
Leverage     : 1:2000 (default demo Exness; tidak mempengaruhi risk — kami pakai SL %)
Date range   : 2015.01.01 – 2025.06.01
Forward test : OFF di pass pertama (lihat §5 walk-forward)
Optimization : OFF kecuali untuk uji sensitivitas plateau ±30%
```

**Spread:** biarkan di "Current spread" (Exness set otomatis ke historical spread dari feed
broker). Jika mode setiap-tick menggunakan spread tetap, ubah ke angka realistis ~$0.25 (=
25 pts × $0.001 × 100 oz / lot).

---

## 2. Model biaya — wajib tercermin di setiap pass

| Biaya | Nilai | Cara setting |
|---|---|---|
| Komisi | **$0/lot** (akun standard) | Default: tester tidak menambahkan komisi untuk Standard |
| Spread | floating, rerata ~$0.25–0.40/oz | Historical feed dari broker (mode every tick) |
| Slippage | max 100 poin = $0.10/lot | `InpDeviationPoints=100` (default EA) |
| Swap long | **-495.7 pts = -$49.57/lot/hari** | Otomatis dari simbol; triple Rabu = ×3 |
| Swap short | 0 | Otomatis; short gratis overnight |

**Aritmetika swap yang harus muncul di laporan Python:**
- Posisi tipikal @ ATR $15, stop $30, ekuitas $10K: **0.01–0.02 lot** (lihat §3)
- 0.02 lot × $49.57/hari = **$0.99/hari** untuk posisi long
- Trade kena time-stop 48 bar ≈ 2.5 hari kalender: **$2.47 ≈ 0.06R** (1R≈$40)
- Trade tren 14 hari kalender: **$13.86 ≈ 0.35R** — tidak membunuh tren panjang
  (ekor kanan +5–10R, biaya swap 0.35R masih positif), tapi wajib TERLIHAT

---

## 3. Sizing tipikal di akun demo

Catatan: ATR H1 emas bergantung volatilitas periode. Tabel untuk orientasi:

| ATR H1 ($) | Stop 2×ATR ($) | lotsByRisk | lotsByGap | Hasil (floor) | Risk aktual ($) |
|---|---|---|---|---|---|
| 10 | 20 | 0.025 | 0.040 | **0.02** | $40 |
| 15 | 30 | 0.017 | 0.027 | **0.01** | $30 |
| 20 | 40 | 0.013 | 0.020 | **0.01** | $40 |
| 25 | 50 | 0.010 | 0.016 | **0.01** | $50 |

Gap cap (0.040 lot pada ATR $10) tidak pernah mengikat di sini — beda dari $1K standard.
Kesalahan pembulatan paling besar saat ATR ~10–15 (0.01 lot dari target 0.013–0.025).
Ini acceptable; backtest Langkah 4 akan menghitung distribusi lot aktual.

---

## 4. Sumber data tick

### Opsi A — Data broker (mudah, terbatas historis)

Di MT5: `Tools → History Center → XAUUSDm` → klik Download. Exness biasanya menyimpan
2–5 tahun ke belakang. Periksa hasilnya lewat `File → Open Data Folder →
history/<server>/XAUUSDm*.hcc` — ukuran file wajar ≈ 100–500 MB per tahun tick data.

**QC minimum setelah download:**
1. Di Strategy Tester jalankan satu pass default → buka tab "Journal" → tidak ada pesan
   "Not enough bars" atau "History not enough".
2. Total trade count output ~ 50–100/tahun × 10 tahun = 500–1000. Jika jauh di bawah 100
   total → data tidak cukup, lanjut ke Opsi B.

### Opsi B — Dukascopy (10 tahun, gratis)

1. Unduh **Tickstory Lite** (gratis, `tickstory.com`).
2. Pilih simbol **XAUUSD** (harga identik dengan XAUUSDm — hanya contract size beda, dan
   EA membaca itu dari broker, bukan dari data file).
3. Ekspor format **MT5 / MetaQuotes** dengan opsi "Every Tick" → folder output `.hst`.
4. Di MT5: `File → Open Data Folder → MQL5/Files` → buat folder `History` → salin file.
   Atau gunakan `Tools → History Center → Import`.
5. Verifikasi: Strategy Tester → "Modelling quality" harus muncul ≥ 99% untuk periode yang
   datanya lengkap.

**Catatan penting:** data Dukascopy adalah feed ECN; spread-nya berbeda dari feed Exness
Standard. Untuk model biaya yang jujur: setelah import, pertimbangkan menambahkan fixed
spread markup 0.20–0.30 di settings tester (di field "Spread" Strategy Tester) untuk
mensimulasikan spread standard account Exness.

---

## 5. Kalender news — WAJIB ada

File `XTC_news_calendar.csv` di `MQL5/Files/` atau folder Common MT5.

Dibuat dengan `analysis/generate_news_calendar.py` (lihat Langkah 3 Python). Jalankan:

```bash
cd analysis
pip install -r requirements.txt
python generate_news_calendar.py --start 2015 --end 2025 --output XTC_news_calendar.csv
```

Salin hasilnya ke `MQL5/Files/` **dan** ke `Terminal/Common/Files/` (agen tester lokal
membaca dari Common). Verifikasi via log EA saat OnInit: `XTC: kalender news dimuat, N event.`

---

## 6. Urutan 6 pass eksperimen (RUANG PENCARIAN DIBEKUKAN)

Jalankan dalam urutan ini; setiap pass menghasilkan `XTC_trades_*.csv` dan
`XTC_counters_*.csv` di folder Common.

| # | `InpUseSlopeFilter` | `InpTimeStopMode` | Nama file output |
|---|---|---|---|
| 1 | `true` (default) | `TS_48` (default) | `..._slope1_ts48.*` |
| 2 | `true` | `TS_NONE` | `..._slope1_ts0.*` |
| 3 | `true` | `TS_96` | `..._slope1_ts96.*` |
| 4 | `false` | `TS_48` | `..._slope0_ts48.*` |
| 5 | `false` | `TS_NONE` | `..._slope0_ts0.*` |
| 6 | `false` | `TS_96` | `..._slope0_ts96.*` |

**Semua parameter lain DIBEKUKAN di default spesifikasi.**
Jangan mengubah Donchian, ATR, SL, trail, risk, sesi, atau spread cap antar pass.

Setelah 6 pass, jalankan `analysis/analyze_backtest.py` (Langkah 4) untuk membandingkan.

---

## 7. Walk-forward (parameter DIBEKUKAN, hanya kurva OOS yang dinilai)

Rolling window 3 tahun → forward 1 tahun, **parameter tidak diubah**:

| Train window | OOS window |
|---|---|
| 2015–2017 | 2018 |
| 2016–2018 | 2019 |
| 2017–2019 | 2020 |
| 2018–2020 | 2021 |
| 2019–2021 | 2022 |
| 2020–2022 | 2023 |
| 2021–2023 | 2024 |

Di MT5: gunakan fitur "Forward" di Strategy Tester — set `Forward=Custom`, isi tanggal.
Kumpulkan kurva ekuitas masing-masing OOS window dan gabungkan → inilah kurva yang dinilai.
Uji sensitivitas ±30% parameter hanya dilakukan pada IS (train window) — bukan untuk memilih
nilai live, tapi untuk mengkonfirmasi plateau.

---

## 8. Checklist kualitas sebelum lanjut ke Python

Setelah 6 pass selesai, periksa hal berikut SEBELUM menjalankan skrip analisis:

- [ ] Modelling quality ≥ 99% (di tab "Results" tester)
- [ ] Total trade ≥ 300 (target ~50/tahun × 10 tahun = 500; di bawah 100 = lapor)
- [ ] `RJ_LOT_BELOW_MIN` di counter ≈ 0 (jika > 5%: ada masalah sizing atau simbol)
- [ ] `RJ_SPREAD_WARMUP` ≤ 30 (24 bar pertama saja; lebih banyak = restart tester mid-run)
- [ ] `RJ_NEWS` > 0 (kalender terbaca; jika 0: file kalender tidak ditemukan)
- [ ] Kurva ekuitas punya drawdown > 0 (flat total = tidak ada trade, sesuatu salah)
- [ ] File `XTC_trades_slope1_ts48.csv` di folder Common, kolom `swap` terisi (bukan semua 0)
- [ ] Tiga benchmark ada datanya: buy-hold emas, Donchian polos, random entry (dibuat Python)

---

## 9. Tiga benchmark (evaluasi di Langkah 4 Python)

| Benchmark | Tujuan | Cara |
|---|---|---|
| Buy-and-hold emas | Apakah kita mengalahkan hold? | Equity curve emas dari data harga raw |
| Donchian polos (tanpa filter H4) | Apakah filter membayar sewanya? | Pass ke-7: `InpUseSlopeFilter=false`, `InpTimeStopMode=TS_NONE`, **hapus syarat H4 bias** — perlu saklar sementara di kode untuk run benchmark saja |
| Random entry | Apakah logika entry punya edge vs kebetulan? | Simulasi di Python: random long/short entry dengan exit/risk engine sama (ATR SL, chandelier, time-stop 48 bar) |

Catatan benchmark Donchian polos: untuk akurasi benchmark, perlu run ke-7 dengan
`InpH4FilterOff=true` (input tambahan sementara). Ini akan ditambahkan di fase analisis;
tidak mengubah 6 ruang eksperimen yang sudah dibekukan.
