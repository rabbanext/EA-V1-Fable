//+------------------------------------------------------------------+
//| ExecutionModule.mqh — order, hard SL, chandelier, time-stop      |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Prinsip #5: hard SL di server. Market order dikirim DENGAN SL    |
//| dalam request yang sama; bila server menolak, fallback modify    |
//| segera; bila modify gagal XTC_MAX_OPEN_RETRY kali, posisi        |
//| DITUTUP PAKSA — posisi tanpa hard SL tidak boleh hidup.          |
//|                                                                  |
//| Chandelier MONOTONIC: SL hanya bergerak searah trade. SL awal    |
//| 2xATR adalah lantai; kandidat trailing yang lebih buruk DIABAIKAN|
//| (di awal trade chandelier 3xATR memang lebih longgar — by design,|
//| efektif setelah close ekstrem bergerak >= 1xATR).                |
//+------------------------------------------------------------------+
#ifndef XTC_EXECUTIONMODULE_MQH
#define XTC_EXECUTIONMODULE_MQH

#include <Trade/Trade.mqh>
#include "Types.mqh"
#include "StateStore.mqh"

class CExecutionModule
  {
private:
   string            m_sym;
   long              m_magic;
   double            m_slMult;      // 2,0 x ATR
   double            m_trailMult;   // 3,0 x ATR
   CTrade            m_trade;
   EExitReason       m_pendingClose;   // alasan close yang kita inisiasi sendiri

   double            Normalize(const double price) const
     {
      int digits = (int)SymbolInfoInteger(m_sym, SYMBOL_DIGITS);
      return NormalizeDouble(price, digits);
     }

public:
   void              Init(const string sym, const long magic, const double slMult,
                          const double trailMult, const int deviationPoints)
     {
      m_sym       = sym;
      m_magic     = magic;
      m_slMult    = slMult;
      m_trailMult = trailMult;
      m_pendingClose = EX_NONE;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(deviationPoints);
      m_trade.SetTypeFillingBySymbol(m_sym);
     }

   EExitReason       PendingCloseReason() const { return m_pendingClose; }
   void              ClearPendingClose()        { m_pendingClose = EX_NONE; }

   //--- Cari posisi milik EA ini (akun hedging: filter simbol+magic). 0 = tidak ada.
   ulong             FindPosition() const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_sym) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         return tk;
        }
      return 0;
     }

   bool              HasPosition() const { return FindPosition() != 0; }

   //================== INTI MURNI (unit-testable) =====================

   //--- Level chandelier dari close ekstrem & ATR saat ini
   static double     ComputeChandelier(const int dir, const double extremeClose,
                                       const double atr, const double trailMult)
     {
      return (dir > 0) ? extremeClose - trailMult * atr
                       : extremeClose + trailMult * atr;
     }

   //--- Aturan monotonic: kandidat hanya dipakai jika MEMPERBAIKI SL berjalan
   static bool       ShouldMoveSL(const int dir, const double currentSL,
                                  const double candidate, const double minStep)
     {
      if(dir > 0) return (candidate > currentSL + minStep);
      return (candidate < currentSL - minStep);
     }

   //================== ENTRY =====================

   //--- Buka posisi market + hard SL. Mengisi state trade di SPersistState.
   //    Return false bila gagal total (caller log anomali; TIDAK retry lintas tick —
   //    1 percobaan per bar sinyal, retry hanya di dalam fungsi ini).
   bool              Open(const EBias dir, const double lots, const double atr,
                          SPersistState &st, double &fillPrice, double &requestPrice)
     {
      double stopDist = m_slMult * atr;
      bool   isLong   = (dir == BIAS_LONG);

      for(int attempt = 0; attempt < XTC_MAX_OPEN_RETRY; attempt++)
        {
         double px = isLong ? SymbolInfoDouble(m_sym, SYMBOL_ASK)
                            : SymbolInfoDouble(m_sym, SYMBOL_BID);
         double sl = Normalize(isLong ? px - stopDist : px + stopDist);
         requestPrice = px;

         bool ok = isLong ? m_trade.Buy(lots, m_sym, 0.0, sl, 0.0, "XTC_v1")
                          : m_trade.Sell(lots, m_sym, 0.0, sl, 0.0, "XTC_v1");
         if(!ok) continue;

         //--- terisi: ambil posisi & verifikasi SL benar-benar terpasang di server
         ulong tk = FindPosition();
         if(tk == 0) continue;   // race: tunggu percobaan berikut

         fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double srvSL = PositionGetDouble(POSITION_SL);

         if(srvSL == 0.0)
           {
            // server menolak SL dalam satu request -> pasang segera
            double sl2 = Normalize(isLong ? fillPrice - stopDist : fillPrice + stopDist);
            bool fixed = false;
            for(int j = 0; j < XTC_MAX_OPEN_RETRY; j++)
               if(m_trade.PositionModify(tk, sl2, 0.0)) { fixed = true; break; }
            if(!fixed)
              {
               // Prinsip #5: tanpa hard SL posisi tidak boleh hidup -> tutup paksa
               m_pendingClose = EX_MANUAL_OTHER;
               m_trade.PositionClose(tk);
               return false;
              }
           }

         //--- state trade (persisten lintas restart di live)
         st.positionId   = (long)PositionGetInteger(POSITION_IDENTIFIER);
         st.entryPrice   = fillPrice;
         st.stopDistance = stopDist;
         st.entryBarTime = iTime(m_sym, PERIOD_H1, 0);   // bar berjalan saat entry
         st.reached1R    = false;
         st.slWasTrailed = false;
         st.direction    = isLong ? 1 : -1;
         return true;
        }
      return false;
     }

   //================== MANAJEMEN PER BAR =====================

   //--- Jumlah bar H1 TERTUTUP sejak bar entry (dihitung dalam bar, kebal akhir pekan)
   int               BarsClosedSinceEntry(const SPersistState &st) const
     {
      if(st.entryBarTime == 0) return 0;
      int b = Bars(m_sym, PERIOD_H1, st.entryBarTime, TimeCurrent());
      return MathMax(0, b - 1);
     }

   //--- Update flag +1R dari ekstrem intrabar bar yang baru tertutup.
   //    \"+1R\" = harga PERNAH menyentuh entry +/- stopDistance. Sekali true,
   //    permanen (disarm time-stop).
   void              UpdateReached1R(SPersistState &st) const
     {
      if(st.reached1R || st.positionId == 0) return;
      double hi1 = iHigh(m_sym, PERIOD_H1, 1);
      double lo1 = iLow(m_sym, PERIOD_H1, 1);
      if(st.direction > 0 && hi1 >= st.entryPrice + st.stopDistance) st.reached1R = true;
      if(st.direction < 0 && lo1 <= st.entryPrice - st.stopDistance) st.reached1R = true;
     }

   //--- Time-stop: keluar market jika belum +1R dalam N bar. Return true bila close dikirim.
   bool              CheckTimeStop(SPersistState &st, const int timeStopBars)
     {
      if(timeStopBars <= 0 || st.positionId == 0) return false;   // TS_NONE
      if(st.reached1R) return false;
      if(BarsClosedSinceEntry(st) < timeStopBars) return false;

      ulong tk = FindPosition();
      if(tk == 0) return false;
      m_pendingClose = EX_TIMESTOP;
      return m_trade.PositionClose(tk);
     }

   //--- Trailing chandelier: dipanggil sekali per bar H1 baru.
   //    extremeClose = close ekstrem bar TERTUTUP sejak entry; atr = ATR(14,H1)[1] saat ini.
   //    Return true bila SL digeser (caller log SL_TRAILED).
   bool              UpdateTrailing(SPersistState &st, const double atr, double &newSLOut)
     {
      if(st.positionId == 0) return false;
      int nBars = BarsClosedSinceEntry(st);
      if(nBars < 1) return false;   // belum ada bar tertutup sejak entry

      //--- close ekstrem sejak entry (mencakup bar entry s/d bar tertutup terakhir)
      double closes[];
      ArraySetAsSeries(closes, true);
      if(CopyClose(m_sym, PERIOD_H1, 1, nBars, closes) < nBars) return false;
      double extreme = (st.direction > 0) ? closes[ArrayMaximum(closes)]
                                          : closes[ArrayMinimum(closes)];

      double candidate = ComputeChandelier(st.direction, extreme, atr, m_trailMult);

      ulong tk = FindPosition();
      if(tk == 0) return false;
      double curSL = PositionGetDouble(POSITION_SL);
      double minStep = SymbolInfoDouble(m_sym, SYMBOL_POINT);

      if(!ShouldMoveSL(st.direction, curSL, candidate, minStep)) return false;

      //--- jangan melanggar jarak stop minimum broker
      double stopsLvl = SymbolInfoInteger(m_sym, SYMBOL_TRADE_STOPS_LEVEL) *
                        SymbolInfoDouble(m_sym, SYMBOL_POINT);
      double mkt = (st.direction > 0) ? SymbolInfoDouble(m_sym, SYMBOL_BID)
                                      : SymbolInfoDouble(m_sym, SYMBOL_ASK);
      if(st.direction > 0 && candidate > mkt - stopsLvl) candidate = mkt - stopsLvl;
      if(st.direction < 0 && candidate < mkt + stopsLvl) candidate = mkt + stopsLvl;
      candidate = Normalize(candidate);
      if(!ShouldMoveSL(st.direction, curSL, candidate, minStep)) return false;

      if(!m_trade.PositionModify(tk, candidate, 0.0)) return false;
      st.slWasTrailed = true;
      newSLOut = candidate;
      return true;
     }

   //================== CLOSE PAKSA =====================

   //--- Dipakai weekly flat & kill switch. Return true bila tidak ada posisi tersisa.
   bool              CloseAll(const EExitReason reason)
     {
      m_pendingClose = reason;
      bool allClosed = true;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_sym) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(!m_trade.PositionClose(tk)) allClosed = false;
        }
      return allClosed;
     }
  };

#endif // XTC_EXECUTIONMODULE_MQH
