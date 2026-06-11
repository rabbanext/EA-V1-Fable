//+------------------------------------------------------------------+
//| SignalModule.mqh — filter arah H4 + entry Donchian H1            |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Inti keputusan = fungsi STATIS MURNI (ComputeBias, CheckBreakout) |
//| yang bisa diuji dengan angka sintetis tanpa terminal. Pembacaan  |
//| indikator dipisah di metode adapter (RefreshH4Bias, FillSnapshot).|
//|                                                                  |
//| GUARD ANTI-LOOK-AHEAD: SEMUA pembacaan indikator/harga memakai   |
//| shift >= 1 (bar tertutup). Bar 0 tidak pernah dibaca untuk       |
//| keputusan. Bias H4 di-cache dan hanya dihitung ulang saat bar H4 |
//| BARU terdeteksi (iTime H4 shift 0 berubah).                      |
//+------------------------------------------------------------------+
#ifndef XTC_SIGNALMODULE_MQH
#define XTC_SIGNALMODULE_MQH

#include "Types.mqh"

class CSignalModule
  {
private:
   string            m_sym;
   bool              m_useSlope;      // saklar eksperimen lengan A/B
   int               m_slopeLB;       // lookback slope (default 5: EMA50[1]-EMA50[6])
   int               m_donchian;      // periode channel (default 24)
   double            m_dispMult;      // displacement minimal, x ATR (default 0,25)
   int               m_atrPeriod;

   int               m_hEma200H4;     // handle indikator
   int               m_hEma50H4;
   int               m_hAtrH1;

   EBias             m_cachedBias;    // cache per bar H4
   datetime          m_cachedH4Bar;   // open time bar H4 saat cache dihitung
   double            m_ema200, m_ema50_1, m_ema50_lb;  // nilai terakhir (untuk log)

public:
   //--- Inisialisasi: buat handle. Return false bila handle gagal (EA harus berhenti).
   bool              Init(const string sym, const bool useSlope, const int slopeLB,
                          const int donchian, const double dispMult, const int atrPeriod)
     {
      m_sym       = sym;
      m_useSlope  = useSlope;
      m_slopeLB   = slopeLB;
      m_donchian  = donchian;
      m_dispMult  = dispMult;
      m_atrPeriod = atrPeriod;
      m_cachedBias  = BIAS_NEUTRAL;
      m_cachedH4Bar = 0;

      m_hEma200H4 = iMA(m_sym, PERIOD_H4, XTC_EMA_SLOW_H4, 0, MODE_EMA, PRICE_CLOSE);
      m_hEma50H4  = iMA(m_sym, PERIOD_H4, XTC_EMA_FAST_H4, 0, MODE_EMA, PRICE_CLOSE);
      m_hAtrH1    = iATR(m_sym, PERIOD_H1, m_atrPeriod);
      return (m_hEma200H4 != INVALID_HANDLE &&
              m_hEma50H4  != INVALID_HANDLE &&
              m_hAtrH1    != INVALID_HANDLE);
     }

   void              Deinit()
     {
      if(m_hEma200H4 != INVALID_HANDLE) IndicatorRelease(m_hEma200H4);
      if(m_hEma50H4  != INVALID_HANDLE) IndicatorRelease(m_hEma50H4);
      if(m_hAtrH1    != INVALID_HANDLE) IndicatorRelease(m_hAtrH1);
     }

   //================== INTI MURNI (unit-testable) =====================

   //--- Filter tiga keadaan. slope = EMA50[1] - EMA50[1+lookback].
   //    slope == 0 persis -> NEUTRAL (flicker jatuh ke netral, bukan membalik).
   static EBias      ComputeBias(const double close1, const double ema200,
                                 const double slope, const bool useSlope)
     {
      bool slopeOKLong  = (!useSlope) || (slope > 0.0);
      bool slopeOKShort = (!useSlope) || (slope < 0.0);
      if(close1 > ema200 && slopeOKLong)  return BIAS_LONG;
      if(close1 < ema200 && slopeOKShort) return BIAS_SHORT;
      return BIAS_NEUTRAL;
     }

   //--- Breakout Donchian + dua filter anti-false-break:
   //    (a) close HARUS di luar level (bukan high/low menyentuh);
   //    (b) close minimal dispMult x ATR di luar level.
   //    Mengembalikan sinyal; bila tidak valid, reject terisi alasan paling spesifik.
   static SEntrySignal CheckBreakout(const EBias bias, const double close1,
                                     const double donchHi, const double donchLo,
                                     const double atr, const double dispMult)
     {
      SEntrySignal s;
      s.valid  = false;
      s.dir    = BIAS_NEUTRAL;
      s.reject = RJ_NONE;

      if(bias == BIAS_NEUTRAL)
        {
         s.reject = RJ_NEUTRAL_BIAS;
         return s;
        }

      if(bias == BIAS_LONG)
        {
         if(close1 <= donchHi)                          { s.reject = RJ_NO_BREAKOUT;  return s; }
         if(close1 <  donchHi + dispMult * atr)         { s.reject = RJ_DISPLACEMENT; return s; }
         s.valid = true;
         s.dir   = BIAS_LONG;
         return s;
        }

      // BIAS_SHORT — cermin terhadap channel bawah
      if(close1 >= donchLo)                             { s.reject = RJ_NO_BREAKOUT;  return s; }
      if(close1 >  donchLo - dispMult * atr)            { s.reject = RJ_DISPLACEMENT; return s; }
      s.valid = true;
      s.dir   = BIAS_SHORT;
      return s;
     }

   //================== ADAPTER TERMINAL ==============================

   //--- Hitung ulang bias HANYA saat bar H4 baru. Return false bila data belum
   //    siap (CopyBuffer gagal) -> caller mencoba lagi di tick berikutnya;
   //    cache lama tetap dipakai sampai berhasil.
   bool              RefreshH4Bias()
     {
      datetime h4now = iTime(m_sym, PERIOD_H4, 0);
      if(h4now == 0) return false;
      if(h4now == m_cachedH4Bar) return true;   // belum ada bar H4 baru

      double e200[], e50[];
      ArraySetAsSeries(e200, true);
      ArraySetAsSeries(e50,  true);
      // e50 dibaca shift 1 .. 1+lookback sekaligus: e50[0]=shift1, e50[lookback]=shift 1+lb
      if(CopyBuffer(m_hEma200H4, 0, 1, 1, e200) < 1)            return false;
      if(CopyBuffer(m_hEma50H4,  0, 1, m_slopeLB + 1, e50) < m_slopeLB + 1) return false;

      double close1 = iClose(m_sym, PERIOD_H4, 1);
      if(close1 <= 0) return false;

      m_ema200   = e200[0];
      m_ema50_1  = e50[0];
      m_ema50_lb = e50[m_slopeLB];
      double slope = m_ema50_1 - m_ema50_lb;

      m_cachedBias  = ComputeBias(close1, m_ema200, slope, m_useSlope);
      m_cachedH4Bar = h4now;
      return true;
     }

   EBias             Bias() const { return m_cachedBias; }

   //--- Isi bagian sinyal dari snapshot (Donchian shift 2..2+N-1, ATR shift 1,
   //    close shift 1, konteks H4 dari cache). Return false bila data belum siap.
   bool              FillSnapshot(SMarketSnapshot &s)
     {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_hAtrH1, 0, 1, 1, atr) < 1) return false;

      double highs[], lows[];
      ArraySetAsSeries(highs, true);
      ArraySetAsSeries(lows,  true);
      // start_pos=2: channel dibentuk 24 bar SEBELUM bar sinyal —
      // bar sinyal tidak boleh ikut membentuk level yang ia tembus sendiri.
      if(CopyHigh(m_sym, PERIOD_H1, 2, m_donchian, highs) < m_donchian) return false;
      if(CopyLow(m_sym, PERIOD_H1, 2, m_donchian, lows)  < m_donchian) return false;

      double close1 = iClose(m_sym, PERIOD_H1, 1);
      if(close1 <= 0) return false;

      s.barTimeH1  = iTime(m_sym, PERIOD_H1, 1);
      s.h1Close1   = close1;
      s.atrH1      = atr[0];
      s.donchianHi = highs[ArrayMaximum(highs)];
      s.donchianLo = lows[ArrayMinimum(lows)];
      s.h4Bias     = m_cachedBias;
      s.ema200H4   = m_ema200;
      s.ema50H4_1  = m_ema50_1;
      s.ema50H4_lb = m_ema50_lb;
      return true;
     }

   //--- Evaluasi entry penuh atas snapshot (murni: hanya membaca snapshot)
   SEntrySignal      CheckEntry(const SMarketSnapshot &s) const
     {
      return CheckBreakout(s.h4Bias, s.h1Close1, s.donchianHi, s.donchianLo,
                           s.atrH1, m_dispMult);
     }
  };

#endif // XTC_SIGNALMODULE_MQH
