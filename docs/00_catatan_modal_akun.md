# Catatan Modal & Akun — Exness Standard, modal < $1.000

**Status: KEPUTUSAN DIPERLUKAN sebelum demo/live. Tidak memblokir implementasi kode
(EA membaca spesifikasi simbol dari server, bukan hardcode).**

## Masalah: aritmetika blueprint rusak di modal $1.000 akun Standard

Spesifikasi kontrak Exness Standard XAUUSD: 1 lot = 100 oz, **lot minimum 0,01** (= 1 oz,
pergerakan $1 = $1 P/L).

**1) Sizing 0,5% tidak terjangkau.** Risiko 0,5% × $1.000 = $5/trade. ATR tipikal H1 emas
saat ini $8–20 → stop 2×ATR = $16–40. Lot yang dibutuhkan = 5 / (20 × 100) = **0,0025 lot
— di bawah minimum 0,01**. Sizing sesuai spek baru mungkin jika ATR ≤ $2,5 — praktis tidak
pernah terjadi di emas era $3.000+. Hampir semua sinyal akan ditolak `RJ_LOT_BELOW_MIN`.

**2) Gap cap MELARANG semua trade.** lotsByGap = (2% × $1.000) / ($50 × $100/lot) =
**0,004 lot < 0,01 minimum**. Artinya RiskModule mengembalikan 0 untuk SETIAP sinyal.
Sistem sesuai blueprint = tidak pernah entry. Ini bukan bug — ini matematika backstop
yang bekerja benar: di modal ini, satu posisi 0,01 lot yang kena gap $50 rugi $50 = 5%
ekuitas, 2,5× batas yang diizinkan.

**3) Memaksa lot minimum 0,01 = membongkar protection stack.** Risiko riil 0,01 lot
dengan stop $20 = $20 = **2%/trade, 4× spek**. Konsekuensi berantai:
- Daily −2% = **satu** loss (spek: 4 loss).
- Weekly −5% = 2,5 loss.
- Kill switch −15% HWM = 7,5R. Sistem tren normal mengalami streak loss 8–12 dan
  drawdown belasan R — kill switch hampir pasti terpicu **meski edge nyata**.
- Menaikkan limit proteksi agar muat = mendesain ulang sistem dari risikonya. DITOLAK
  (Prinsip Desain #7; limit adalah bagian dari hipotesis yang diuji, bukan baju yang
  dilonggarkan).

## Solusi

### Opsi A — Exness Standard Cent (XAUUSDc) ← REKOMENDASI

1 cent lot = 1/100 lot standard; saldo dihitung dalam sen USD. Aritmetikanya identik
dengan blueprint $100.000 pada skala 1:100:

| Besaran | Blueprint $100K Standard | $1.000 di Standard Cent |
|---|---|---|
| Ekuitas | $100.000 | 100.000 ¢ |
| Risiko/trade 0,5% | $500 | 500 ¢ ($5) |
| Lot @ ATR $10 (stop $20) | 0,25 lot | 0,25 cent-lot (0,25 oz) |
| Gap cap | 0,4 lot | 0,4 cent-lot |
| Lot minimum | 0,01 (mengikat!) | 0,01 cent-lot = 0,01 oz (longgar) |
| Tangga live 0,1% risiko | OK | $1/trade → ~0,05 cent-lot, OK |

Seluruh persentase (0,5% risk, −2/−5/−15%, gap cap) berlaku tanpa modifikasi. EA tidak
perlu diubah — ia membaca `SYMBOL_VOLUME_MIN/STEP` dan tick value dari server, sehingga
otomatis benar di simbol `XAUUSDc`.

**Tindakan verifikasi pemilik akun (5 menit, di terminal MT5):** klik kanan XAUUSDc →
Specification → catat *Contract size, Minimum/Step volume, Tick value, Swap long/short,
jam server vs UTC*. Tempelkan ke percakapan — angka ini masuk model biaya backtest.
Sumber publik: [Standard Cent account – Exness](https://get.exness.help/hc/en-us/articles/17537782786588-Standard-Cent-account),
[Commodities – Exness](https://get.exness.help/hc/en-us/articles/17854173039388-Commodities),
[Standard accounts – Exness](https://www.exness.com/standard-accounts/).

### Opsi B — tetap di Standard, tambah modal

Syarat minimum agar spek jalan: lotsByRisk ≥ 0,01 ⇔ 0,005×E ≥ 0,01×stop×100 ⇔
**E ≥ 200 × stop$**. Pada ATR $10 → E ≥ $4.000; ATR $20 → E ≥ $8.000. Plus gap cap ≥ 0,01
⇔ E ≥ $2.500. Realistis: **≥ $8.000** supaya sizing tidak rusak justru saat volatilitas
tinggi. Granularitas tetap kasar (step 0,01 lot = 4–8% error pembulatan ke bawah).

### Opsi C — naikkan risiko per trade — DITOLAK

Lihat poin (3) di atas. Tidak akan diimplementasikan walau diminta.

## Ekspektasi yang jujur di modal $1.000

Jika edge nyata: 6–15%/tahun = **$60–150/tahun**, dengan drawdown wajar 10–15% (= $100–150)
dan periode datar berbulan-bulan. Pada skala ini nilai proyek BUKAN pendapatannya, melainkan:
(1) memvalidasi edge dengan uang sungguhan semurah mungkin — persis filosofi tangga live
blueprint; (2) membangun infrastruktur + disiplin proses yang portabel ke modal lebih besar.
Itu konsisten dengan blueprint; yang berubah hanya satuan dolarnya.

## Dampak ke backtest (Langkah 3)

- Deposit awal tester dibuat **mencerminkan akun riil**: 100.000 (sen) dengan spesifikasi
  volume ala cent, atau backtest di simbol XAUUSDc langsung jika data tersedia.
- Komisi = 0 (standard/cent), biaya = spread markup feed Exness + swap + slippage.
- `RJ_LOT_BELOW_MIN` di laporan backtest harus ~0; jika tidak, konfigurasi akun salah.
