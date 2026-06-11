# Langkah 1 — Arsitektur Modular & Pseudocode

**XAU Trend Capture v1** · Blueprint terkunci · Dokumen ini = deliverable Langkah 1.

Konvensi dokumen: pseudocode memakai sintaks mirip-MQL5; `[k]` berarti shift bar ke-k
(bar 0 = bar berjalan, bar 1 = bar tertutup terakhir). Semua keputusan dievaluasi pada
**bar tertutup** — bar 0 tidak pernah dibaca untuk sinyal.

---

## 0. Penyesuaian akibat jawaban klarifikasi

### 0.1 Akun STANDARD — model biaya berubah, hitungannya begini

Spesifikasi awal menulis "komisi ~$6–7/lot round trip akun raw". Dengan akun standard:

- **Raw:** spread XAUUSD tipikal $0,10–0,15/oz + komisi $7/lot RT = $0,07/oz → total **~$0,17–0,22/oz**.
- **Standard:** komisi 0, spread tipikal **~$0,25–0,40/oz** (markup tergantung broker).

Dampak per trade (ATR $10 → stop $20 → 1R = $20/oz):
- Standard: 0,25–0,40 / 20 = **0,013–0,020R per trade**.
- Raw: 0,17–0,22 / 20 = **0,009–0,011R per trade**.
- Selisih ~0,005–0,01R/trade × ~75 trade/tahun ≈ **0,4–0,75R/tahun** lebih mahal.

Bukan pembunuh sistem, tapi WAJIB dimodelkan jujur:
1. Di Strategy Tester: **komisi = 0**, dan spread harus mencerminkan feed akun standard
   (data tick broker sendiri, atau data eksternal + markup manual di custom symbol).
2. Laporan biaya Python tetap memisahkan baris: spread, slippage, swap — agar kalau
   nanti pindah ke raw, perbandingannya apples-to-apples.
3. Spread filter (2× median 24 bar) otomatis terkalibrasi ke feed standard — tidak
   perlu diubah.

### 0.2 Data tick — belum ada

Prosedur akuisisi + QC data masuk Langkah 3 (rencana backtest). Ringkas: kandidat utama
data Dukascopy (gratis, 2015–2025 tersedia) diimpor ke MT5; pembanding kualitas = data
real-tick broker sendiri (biasanya hanya 2–5 tahun ke belakang). Detail menyusul di
Langkah 3 — di sini cukup dicatat bahwa arsitektur EA tidak bergantung pada sumber data.

### 0.3 Lingkungan

- MQL5: edit di VS Code, compile di MetaEditor (atau `metaeditor64.exe /compile` dari CLI).
- Python: virtualenv lokal + pandas/numpy/matplotlib, skrip `.py` biasa (bukan notebook)
  supaya hasilnya reproducible dan bisa di-commit. Komentar kode akan rapat.

---

## 1. Tata letak repositori

```
EA-V1-Fable/
├── MQL5/
│   ├── Experts/XAUTrendCapture/
│   │   └── XAUTrendCapture_v1.mq5        # entry point tipis: wiring + event handler
│   ├── Include/XAUTrendCapture/
│   │   ├── Types.mqh                     # enum, struct, konstanta bersama
│   │   ├── SignalModule.mqh              # filter H4 + entry Donchian H1
│   │   ├── RiskModule.mqh                # sizing flat + gap cap
│   │   ├── ExecutionModule.mqh           # order, SL, chandelier, time-stop
│   │   ├── ProtectionModule.mqh          # spread, news, sesi, daily/weekly/kill
│   │   ├── NewsCalendar.mqh              # loader CSV kalender historis
│   │   ├── DecisionLogger.mqh            # log keputusan + penghitung sinyal-terblokir
│   │   └── StateStore.mqh                # HWM, anchor ekuitas, flag kill (persisten)
│   └── Scripts/XAUTrendCapture/Tests/
│       ├── Test_SignalModule.mq5         # unit test: array sintetis → assert
│       ├── Test_RiskModule.mq5
│       └── Test_ProtectionModule.mq5
├── analysis/                             # Python (Langkah 4)
├── data/news/                            # CSV kalender ekonomi historis (Langkah 3)
└── docs/
    └── 01_arsitektur_pseudocode.md       # dokumen ini
```

**Prinsip testabilitas:** setiap modul adalah class yang logikanya berupa **fungsi murni
atas data yang disuntikkan** (array harga, struct kondisi pasar) — bukan pemanggil
langsung `iClose()`/`SymbolInfo*()`. Adaptor tipis di file `.mq5` utama yang mengambil
data dari terminal. Akibatnya unit test bisa memberi array sintetis dan meng-assert
output tanpa Strategy Tester.

---

## 2. Tipe & input parameter

### 2.1 Enum dan struct inti (`Types.mqh`)

```
enum EBias        { BIAS_LONG, BIAS_SHORT, BIAS_NEUTRAL };
enum ETimeStop    { TS_NONE, TS_48, TS_96 };                 // lengan eksperimen
enum ERejectReason{ RJ_NEUTRAL_BIAS, RJ_NO_BREAKOUT, RJ_DISPLACEMENT,
                    RJ_SPREAD, RJ_NEWS, RJ_SESSION, RJ_DAILY_LIMIT,
                    RJ_WEEKLY_LIMIT, RJ_KILL_SWITCH, RJ_POSITION_OPEN,
                    RJ_DUPLICATE_BAR, RJ_LOT_BELOW_MIN };

struct SMarketSnapshot {       // semua yang dibutuhkan modul, diambil sekali per bar H1 baru
   double  h1Close1;           // close bar H1 tertutup terakhir
   double  donchianHi, donchianLo;   // dihitung atas shift 2..25 (lihat §3.2)
   double  atrH1;              // ATR(14,H1) pada shift 1
   double  spreadNow;          // spread saat ini (poin → $)
   double  spreadMedian24;     // median ring buffer 24 sampel per-bar
   EBias   h4Bias;             // hasil SignalModule::GetH4Bias (cache per bar H4)
   datetime barTimeH1;         // open time bar sinyal
};
```

### 2.2 Input parameter — pemetaan 1:1 ke anggaran (±12)

| # | Input | Default | Catatan |
|---|-------|---------|---------|
| 1 | `InpDonchianPeriod` | 24 | uji plateau ±30% |
| 2 | `InpDisplacementATR` | 0.25 | filter anti-false-break (b) |
| 3 | `InpATRPeriod` | 14 | dipakai H1 untuk semuanya |
| 4 | `InpSLMultATR` | 2.0 | SL awal |
| 5 | `InpTrailMultATR` | 3.0 | chandelier |
| 6 | `InpTimeStopMode` | TS_48 | **saklar eksperimen** {NONE, 48, 96} |
| 7 | `InpUseSlopeFilter` | true | **saklar eksperimen** lengan A/B |
| 8 | `InpSlopeLookback` | 5 | EMA50[1] − EMA50[1+5] |
| 9 | `InpRiskPct` | 0.5 | sizing flat |
| 10 | `InpSessionStartGMT` / `InpSessionEndGMT` | 7 / 20 | jendela entry |
| 11 | `InpSpreadCapMult` | 2.0 | jendela median 24 = **konstanta** di kode, BUKAN input |
| 12 | `InpNewsWindowMin` | 15 | ±menit |

Input non-anggaran (operasional, bukan parameter strategi — tidak ikut optimasi):
`InpServerGMTOffsetWinter/Summer` (lihat §6.4 — risiko timezone), `InpNewsCSVName`,
`InpMagicNumber`, `InpGapCapDollar` = 50 dan `InpGapCapLossPct` = 2.0 (konstanta backstop,
dipajang sebagai input read-only-by-convention agar terlihat di laporan tester).

EMA200 H4 dan EMA50 H4 adalah **konstanta tertanam** (bagian definisi filter), bukan input
— mengurangi permukaan optimasi sesuai prinsip #2.

**6 kombinasi eksperimen yang dibekukan** = `InpUseSlopeFilter` {true,false} ×
`InpTimeStopMode` {NONE, 48, 96}. Tidak ada saklar lain.

---

## 3. SignalModule

### 3.1 Filter arah H4 — tiga keadaan, bar tertutup saja

```
// Dipanggil hanya saat bar H4 BARU terdeteksi; hasil di-cache.
// LOOK-AHEAD GUARD: semua handle indikator dibaca pada shift >= 1.
EBias GetH4Bias():
   close1  = Close(H4)[1]
   ema200  = EMA(200, H4, PRICE_CLOSE)[1]
   ema50_1 = EMA(50,  H4, PRICE_CLOSE)[1]
   ema50_6 = EMA(50,  H4, PRICE_CLOSE)[1 + InpSlopeLookback]   // = [6]
   slope   = ema50_1 - ema50_6

   slopeOKLong  = (!InpUseSlopeFilter) || (slope > 0)
   slopeOKShort = (!InpUseSlopeFilter) || (slope < 0)

   if (close1 > ema200 && slopeOKLong)  return BIAS_LONG
   if (close1 < ema200 && slopeOKShort) return BIAS_SHORT
   return BIAS_NEUTRAL          // flicker jatuh ke Netral, tidak pernah membalik
```

Catatan implementasi: `slope == 0` persis → Netral (jatuh ke return terakhir) — konsisten
dengan aturan "flicker menjatuhkan ke Netral". Cache di-invalidate hanya ketika
`iTime(sym, H4, 0)` berubah.

### 3.2 Entry Donchian H1 — definisi indeks yang tidak ambigu

Bar sinyal = bar H1 yang **baru saja tertutup** (shift 1). Channel dihitung atas 24 bar
tertutup **sebelum** bar sinyal, yaitu shift 2..25 — bar sinyal tidak boleh ikut membentuk
channel yang ia tembus sendiri.

```
SEntrySignal CheckEntry(snapshot):
   if (snapshot.h4Bias == BIAS_NEUTRAL)             return Reject(RJ_NEUTRAL_BIAS)

   if (snapshot.h4Bias == BIAS_LONG):
      level = snapshot.donchianHi                   // = Highest(High, H1, shift 2..25)
      if (snapshot.h1Close1 <= level)               return Reject(RJ_NO_BREAKOUT)
      if (snapshot.h1Close1 <  level + InpDisplacementATR * snapshot.atrH1)
                                                    return Reject(RJ_DISPLACEMENT)
      return Signal(LONG)

   // mirror untuk SHORT terhadap donchianLo, close di bawah level - 0.25*ATR
```

Eksekusi entry: market order di awal bar berjalan (bar 0) segera setelah sinyal
terkonfirmasi pada close bar 1. Anti-duplicate: simpan `lastSignalBarTime`; satu bar
sinyal hanya boleh menghasilkan satu percobaan entry (`RJ_DUPLICATE_BAR`).

---

## 4. RiskModule

```
double ComputeLots(equity, stopDistancePrice):       // stopDistancePrice = 2*ATR, dalam $
   // XAUUSD: 1 lot = 100 oz -> pergerakan $1 = $100/lot.
   // Ambil dari simbol, jangan hardcode: tickValue per $1 move.
   dollarPerLotPerUnit = SymbolTickValue/SymbolTickSize     // = ~100 untuk XAUUSD

   riskDollar = InpRiskPct/100 * equity                     // 0.005 * equity
   lotsByRisk = riskDollar / (stopDistancePrice * dollarPerLotPerUnit)

   // Backstop gap: gap $50 tidak boleh merugikan > 2% ekuitas.
   //   lotsByGap = (0.02 * equity) / (50 * 100)  -> $100K => 2000/5000 = 0.4 lot
   lotsByGap  = (InpGapCapLossPct/100 * equity) / (InpGapCapDollar * dollarPerLotPerUnit)

   lots = min(lotsByRisk, lotsByGap)
   lots = floor ke SYMBOL_VOLUME_STEP                       // SELALU bulat ke bawah
   if (lots < SYMBOL_VOLUME_MIN) return 0                   // caller men-log RJ_LOT_BELOW_MIN
   return min(lots, SYMBOL_VOLUME_MAX)
```

Sanity check spesifikasi: ekuitas $100.000, ATR $10 → stop $20 → 500/(20×100) = **0,25
lot** ✓. Cap gap mengikat saat ATR < $6,25 (karena 500/(2×ATR×100) > 0,4 ⇔ ATR < 6,25) —
sesuai desain, ATR rendah ≠ risiko gap rendah.

---

## 5. ExecutionModule

### 5.1 Entry + SL awal

```
OpenPosition(dir, lots, atr):
   sl = (dir==LONG) ? Ask - InpSLMultATR*atr : Bid + InpSLMultATR*atr
   kirim market order DENGAN SL terpasang dalam request yang sama   // hard stop di server
   if (broker menolak SL dalam satu request):                       // beberapa server begitu
      open dulu -> langsung modify SL; jika modify gagal 3x -> CLOSE paksa + log anomali
      // posisi tanpa hard SL tidak boleh hidup > beberapa detik — prinsip #5
   simpan: entryPrice, stopDistance (=2*atr saat entry), entryBarTime, reached1R=false
```

### 5.2 Chandelier — monotonic, SL awal sebagai lantai

Risiko implementasi #3 dari verifikasi konteks, ditangani eksplisit:

```
// Dipanggil sekali per bar H1 BARU (bukan per tick — chandelier berbasis close).
UpdateTrailing(pos):
   extremeClose = max(Close[1..barsSinceEntry]) untuk LONG    // close ekstrem SEJAK entry
   candidate    = extremeClose - InpTrailMultATR * ATR(14,H1)[1]   // ATR saat ini, bukan saat entry
   // ATURAN MONOTONIC: SL hanya boleh naik (LONG) / turun (SHORT). SL awal 2xATR
   // adalah lantai; candidate yang lebih buruk dari SL berjalan DIABAIKAN.
   if (candidate > pos.currentSL + minStopStep):  ModifySL(candidate)
```

Konsekuensi aritmetis yang disadari: di awal trade, chandelier dari entry = entry − 3×ATR,
lebih buruk dari SL awal entry − 2×ATR → kandidat diabaikan; chandelier baru efektif
setelah close ekstrem bergerak ≥ 1×ATR searah posisi. Ini perilaku yang diinginkan.

### 5.3 Time-stop — bar tertutup, disarm permanen di +1R

```
// "+1R tercapai" = harga PERNAH menyentuh entry ± stopDistance (pakai High/Low bar,
//  bukan hanya close) — sekali tercapai, time-stop mati permanen untuk trade ini.
OnNewH1Bar:
   if (!pos.reached1R):
      if (LONG  && High[1] >= pos.entryPrice + pos.stopDistance) pos.reached1R = true
      if (SHORT && Low[1]  <= pos.entryPrice - pos.stopDistance) pos.reached1R = true

   limit = (InpTimeStopMode==TS_48 ? 48 : InpTimeStopMode==TS_96 ? 96 : INF)
   if (!pos.reached1R && barsClosedSinceEntry >= limit):
      CloseAtMarket(reason=EXIT_TIMESTOP)
```

Dihitung dalam **bar H1 tertutup** → otomatis berhenti menghitung saat pasar tutup
(kebal akhir pekan), sesuai spesifikasi. `barsClosedSinceEntry` dihitung via
`Bars(sym, H1, entryBarTime, now) - 1`, bukan via jam dinding.

### 5.4 Exit boleh kapan saja

SL/trailing/time-stop tidak difilter sesi/news/spread — semua filter di ProtectionModule
hanya memblokir **entry baru**.

---

## 6. ProtectionModule

Urutan evaluasi gerbang entry (cek termurah dulu; setiap penolakan menaikkan counter
per-alasan — metrik "sinyal terblokir" untuk uji 3-lengan):

```
CanEnter(snapshot) -> (bool, ERejectReason):
   1. killSwitchActive?           -> RJ_KILL_SWITCH      // permanen sampai reset manual
   2. weeklyLockActive?           -> RJ_WEEKLY_LIMIT
   3. dailyLockActive?            -> RJ_DAILY_LIMIT
   4. posisi masih terbuka?       -> RJ_POSITION_OPEN
   5. di luar 07:00-20:00 GMT?    -> RJ_SESSION
   6. dalam ±15 menit news?       -> RJ_NEWS
   7. spreadNow > 2*median24?     -> RJ_SPREAD
   8. lolos semua                 -> true
```

### 6.1 Spread filter

Sampel spread diambil **sekali per bar H1, pada deteksi bar baru** (= beberapa detik
setelah open bar), disimpan di ring buffer 24 slot. Median dihitung atas buffer penuh;
selama warm-up (< 24 sampel) entry **ditolak dengan RJ_SPREAD** dan di-log — konservatif,
hanya terjadi 24 jam pertama setelah attach/restart. Jendela 24 dan titik sampling adalah
konstanta kode. EA juga menulis sampel spread per bar ke log live (kebutuhan spesifikasi).

### 6.2 Daily / weekly / kill switch — basis EKUITAS (termasuk floating), waktu GMT

```
OnTick (murah, hanya perbandingan):
   eq = AccountEquity()                          // sudah termasuk floating P/L
   hwm = max(hwm, eq); persist(hwm)              // StateStore -> file, tahan restart

   if (eq <= hwm * 0.85):                        // kill switch -15% dari HWM
      CloseAllPositions(); killSwitchActive = true; persist; alert  // EA mati, post-mortem

   if (eq <= weekAnchor * 0.95 && !weeklyLockActive):    // weekly -5%
      CloseAllPositions(); weeklyLockActive = true       // flat semua, tunggu Senin

   if (eq <= dayAnchor * 0.98): dailyLockActive = true   // daily -2%: stop ENTRY saja,
                                                          // posisi berjalan TIDAK ditutup

OnNewDayGMT:  dayAnchor  = eq;  dailyLockActive  = false
OnNewWeekGMT: weekAnchor = eq;  weeklyLockActive = false  // Senin 00:00 GMT
```

Anchor = ekuitas pada **awal periode** (sesuai spesifikasi "relatif terhadap ekuitas awal
periode"), bukan high intraperiode. `dayAnchor`/`weekAnchor`/`hwm`/flag kill disimpan di
file lewat StateStore agar restart terminal tidak mereset proteksi.

### 6.3 News filter (CSV — Strategy Tester tidak punya kalender)

```
NewsCalendar::Load(csv):    // format: "2015-01-09 13:30;NFP" — datetime dalam GMT
   parse -> array datetime terurut (binary-search-able)
IsBlocked(nowGMT): return ada event e dengan |nowGMT - e| <= InpNewsWindowMin menit
```

File yang sama dipakai backtest dan live → satu logika, dua mode (risiko implementasi #1
dari verifikasi konteks tertutup di desain: tidak ada cabang "kalau live pakai kalender
MQL5"). Pembuatan CSV 10 tahun = Langkah 3.

### 6.4 Konversi waktu server ↔ GMT (risiko yang harus dipajang, bukan disembunyikan)

Semua aturan memakai GMT; `TimeCurrent()` memakai waktu server (umumnya UTC+2, UTC+3 saat
DST New York). Solusi v1: input `InpServerGMTOffsetWinter/Summer` + tabel transisi DST AS
(Maret/November, Minggu ke-2/ke-1) tertanam di kode. Kasar tapi eksplisit dan bisa diuji;
salah offset 1 jam menggeser jendela sesi, batas harian, dan news window sekaligus — maka
unit test wajib mencakup tanggal transisi DST.

---

## 7. DecisionLogger

Satu baris CSV per keputusan, dua keluaran: file log (live & tester) + counter agregat.

```
schema: time;event;bias;close;donchHi;donchLo;atr;spread;median;lots;equity;detail
event ∈ {ENTRY_TAKEN, REJECT_<reason>, EXIT_SL, EXIT_TRAIL,   // EXIT_TRAIL = kena SL hasil trailing
         EXIT_TIMESTOP, EXIT_WEEKLY_FLAT, EXIT_KILL, SL_TRAILED, INFO_SPREAD_SAMPLE}
```

Pada `OnTester()`: tulis **trade list CSV** (waktu entry/exit, harga, lots, P/L gross,
swap, komisi, R-multiple, alasan exit, jumlah bar dipegang) + **dump counter
sinyal-terblokir per alasan**. Ini kontrak data untuk skrip Python Langkah 4 — distribusi
R net-of-swap dengan swap sebagai kolom terpisah dihitung dari sini, bukan dari laporan
HTML tester yang menyembunyikan swap di dalam P/L.

---

## 8. Alur event utama (`XAUTrendCapture_v1.mq5`)

```
OnInit:
   validasi simbol & InpRiskPct; NewsCalendar.Load(); StateStore.Load()
   buat handle indikator: ATR(14,H1), EMA200(H4), EMA50(H4)

OnTick:
   Protection.UpdateEquityGuards()                  // §6.2 — tiap tick, murah
   if (killSwitchActive) return

   if (bar H1 baru):
      Protection.SampleSpread()
      if (bar H4 baru): Signal.RefreshH4Bias()
      snapshot = BuildSnapshot()                    // satu-satunya titik baca data terminal

      if (ada posisi):
         Execution.UpdateReached1R(); Execution.CheckTimeStop(); Execution.UpdateTrailing()
      else:
         sig = Signal.CheckEntry(snapshot)
         if (sig.valid && Protection.CanEnter(snapshot)):
            lots = Risk.ComputeLots(equity, 2*snapshot.atrH1)
            if (lots > 0) Execution.OpenPosition(...)
         Logger.Log(...)                            // SETIAP keputusan, diambil atau tidak

OnTradeTransaction: deteksi SL kena / posisi tertutup -> log alasan exit + reset state trade
OnTester: tulis trade list CSV + counter -> kontrak data Python
```

Urutan dalam satu bar saat ada posisi: cek 1R dulu → time-stop → trailing. Alasannya:
time-stop menilai "pernah +1R?" berdasarkan data sampai bar tertutup terakhir; trailing
dijalankan terakhir karena hanya memodifikasi SL untuk bar-bar berikutnya.

---

## 9. Rencana unit test per modul (Scripts/Tests)

| Modul | Kasus uji kunci |
|---|---|
| Signal/H4 | close>EMA200 & slope>0 → LONG; slope=0 → NEUTRAL; flicker slope → NEUTRAL (bukan SHORT); slope dihitung [1]−[6] persis |
| Signal/Donchian | channel atas shift 2..25 (bar sinyal tak termasuk); close tepat di level → reject; close = level+0,249×ATR → reject; +0,25×ATR → lolos |
| Risk | $100K/ATR $10 → 0,25 lot; ATR $5 → cap 0,4 lot (bukan 0,5); pembulatan SELALU ke bawah; < min lot → 0 |
| Execution | chandelier tidak pernah memperburuk SL; reached1R via High intrabar men-disarm permanen; hitungan bar lintas akhir pekan tidak bertambah |
| Protection | daily −2% blokir entry tapi tidak menutup posisi; weekly −5% flat semua; kill −15% HWM persisten lintas restart; news ±15 menit batas inklusif; DST AS Maret/Nov |
| NewsCalendar | parse CSV, urutan acak di file → tetap terurut; event tepat di batas window |

---

## 10. Yang TIDAK ada di v1 (penegasan, sesuai Keputusan Tertutup)

Tidak ada: BE-1R, partial close, consecutive-loss rule, tick volume, confidence sizing,
regime classifier, ML, grid/martingale, optimasi jendela median spread. Saklar eksperimen
hanya dua (slope, time-stop) — total ruang pencarian 6 kombinasi, dibekukan.

---

**Berikutnya (Langkah 2):** implementasi MQL5 penuh mengikuti dokumen ini, modul per modul,
dengan komentar rapat. Deviasi apa pun dari pseudocode ini akan dicatat eksplisit di
commit message dan di header file.
