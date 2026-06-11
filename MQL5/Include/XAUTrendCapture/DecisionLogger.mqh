//+------------------------------------------------------------------+
//| DecisionLogger.mqh — log keputusan, counter sinyal-terblokir,    |
//| ekspor trade list (kontrak data untuk skrip Python Langkah 4)    |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Tiga keluaran:                                                   |
//| 1. Decision log CSV: SETIAP keputusan (entry diambil/ditolak,    |
//|    exit, trail, sampel spread) — \"kenapa\" selalu terekam.        |
//| 2. Counter agregat per alasan penolakan — metrik slot untuk uji  |
//|    3-lengan time-stop (RJ_POSITION_OPEN = sinyal terblokir).     |
//| 3. OnTester: trade list CSV per posisi dengan SWAP sebagai kolom |
//|    TERPISAH — laporan net-of-swap dihitung dari sini, bukan dari |
//|    laporan HTML tester yang menyembunyikan swap dalam P/L.       |
//|                                                                  |
//| Saat OPTIMASI: file I/O per keputusan dimatikan (lambat), counter|
//| tetap jalan. File ditulis dengan FILE_COMMON agar mudah ditemukan|
//| (satu folder untuk semua agen tester lokal).                     |
//+------------------------------------------------------------------+
#ifndef XTC_DECISIONLOGGER_MQH
#define XTC_DECISIONLOGGER_MQH

#include "Types.mqh"

class CDecisionLogger
  {
private:
   int               m_h;                    // handle file decision log
   bool              m_fileOn;               // tulis file? (off saat optimasi)
   long              m_cnt[RJ_COUNT];        // counter penolakan per alasan
   long              m_cntEntry;             // entry tereksekusi
   string            m_suffix;               // penanda lengan eksperimen di nama file

   //--- registry info entry per positionId (join dengan history di OnTester)
   long              m_posIds[];
   double            m_posRisk[];            // $ dirisikokan saat entry
   double            m_posStopDist[];        // jarak SL awal (harga)
   datetime          m_posEntryBar[];
   int               m_posExitReason[];      // EExitReason
   int               m_posCount;

   void              WriteLine(const string s)
     {
      if(!m_fileOn || m_h == INVALID_HANDLE) return;
      FileWriteString(m_h, s + "\n");
     }

   int               FindPos(const long posId) const
     {
      for(int i = m_posCount - 1; i >= 0; i--)
         if(m_posIds[i] == posId) return i;
      return -1;
     }

public:
   //--- suffix membedakan file antar lengan eksperimen, mis. "slope1_ts48"
   bool              Init(const string symbol, const bool useSlope, const int timeStopBars)
     {
      ArrayInitialize(m_cnt, 0);
      m_cntEntry = 0;
      m_posCount = 0;
      m_suffix = StringFormat("%s_slope%d_ts%d", symbol, useSlope ? 1 : 0, timeStopBars);

      // optimasi: counter saja, tanpa file per keputusan
      m_fileOn = !MQLInfoInteger(MQL_OPTIMIZATION);
      m_h = INVALID_HANDLE;
      if(m_fileOn)
        {
         string name = "XTC_decisions_" + m_suffix + ".csv";
         m_h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
         if(m_h == INVALID_HANDLE)
            m_h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI);
         WriteLine("time;event;bias;close;donch_hi;donch_lo;atr;spread;median;detail");
        }
      return true;
     }

   void              Deinit()
     {
      if(m_h != INVALID_HANDLE) { FileClose(m_h); m_h = INVALID_HANDLE; }
     }

   //================== LOG KEPUTUSAN =====================

   void              LogReject(const ERejectReason rj, const SMarketSnapshot &s, const string detail = "")
     {
      if(rj >= 0 && rj < RJ_COUNT) m_cnt[rj]++;
      WriteLine(StringFormat("%s;REJECT_%s;%d;%.2f;%.2f;%.2f;%.2f;%.3f;%.3f;%s",
                TimeToString(s.barTimeH1, TIME_DATE | TIME_MINUTES), RejectReasonToString(rj),
                (int)s.h4Bias, s.h1Close1, s.donchianHi, s.donchianLo, s.atrH1,
                s.spreadNow, s.spreadMedian, detail));
     }

   void              LogEntry(const SMarketSnapshot &s, const double lots, const double riskMoney,
                              const double fillPrice)
     {
      m_cntEntry++;
      WriteLine(StringFormat("%s;ENTRY_TAKEN;%d;%.2f;%.2f;%.2f;%.2f;%.3f;%.3f;lots=%.4f risk=%.2f fill=%.2f",
                TimeToString(s.barTimeH1, TIME_DATE | TIME_MINUTES),
                (int)s.h4Bias, s.h1Close1, s.donchianHi, s.donchianLo, s.atrH1,
                s.spreadNow, s.spreadMedian, lots, riskMoney, fillPrice));
     }

   void              LogEvent(const datetime t, const string eventName, const string detail = "")
     {
      WriteLine(StringFormat("%s;%s;;;;;;;;%s",
                TimeToString(t, TIME_DATE | TIME_MINUTES | TIME_SECONDS), eventName, detail));
     }

   //--- spesifikasi: EA mencatat spread per bar (live)
   void              LogSpreadSample(const datetime t, const double spread)
     {
      WriteLine(StringFormat("%s;INFO_SPREAD_SAMPLE;;;;;;%.3f;;",
                TimeToString(t, TIME_DATE | TIME_MINUTES), spread));
     }

   //================== REGISTRY TRADE =====================

   void              RegisterEntry(const long posId, const double riskMoney,
                                   const double stopDist, const datetime entryBar)
     {
      int i = m_posCount;
      ArrayResize(m_posIds, i + 1);
      ArrayResize(m_posRisk, i + 1);
      ArrayResize(m_posStopDist, i + 1);
      ArrayResize(m_posEntryBar, i + 1);
      ArrayResize(m_posExitReason, i + 1);
      m_posIds[i] = posId;
      m_posRisk[i] = riskMoney;
      m_posStopDist[i] = stopDist;
      m_posEntryBar[i] = entryBar;
      m_posExitReason[i] = (int)EX_NONE;
      m_posCount++;
     }

   void              RegisterExitReason(const long posId, const EExitReason r)
     {
      int i = FindPos(posId);
      if(i >= 0 && m_posExitReason[i] == (int)EX_NONE) m_posExitReason[i] = (int)r;
     }

   //================== EKSPOR OnTester =====================

   //--- Tulis counter + trade list dari history deal. Return total net R
   //    (dipakai sebagai nilai OnTester untuk perbandingan antar pass).
   double            ExportTesterReport(const string symbol, const long magic)
     {
      //--- counter sinyal terblokir
        {
         string name = "XTC_counters_" + m_suffix + ".csv";
         int h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
         if(h == INVALID_HANDLE) h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI);
         if(h != INVALID_HANDLE)
           {
            FileWriteString(h, "reason;count\n");
            FileWriteString(h, StringFormat("ENTRY_TAKEN;%I64d\n", m_cntEntry));
            for(int r = 1; r < RJ_COUNT; r++)
               FileWriteString(h, StringFormat("%s;%I64d\n",
                               RejectReasonToString((ERejectReason)r), m_cnt[r]));
            FileClose(h);
           }
        }

      //--- trade list: gabungkan deal per positionId
      if(!HistorySelect(0, TimeCurrent())) return 0.0;
      int total = HistoryDealsTotal();

      string name2 = "XTC_trades_" + m_suffix + ".csv";
      int h2 = FileOpen(name2, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h2 == INVALID_HANDLE) h2 = FileOpen(name2, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h2 != INVALID_HANDLE)
         FileWriteString(h2, "pos_id;dir;time_in;price_in;lots;time_out;price_out;bars_held;"
                             "gross;commission;swap;net;risk_usd;r_net;r_swap;exit_reason\n");

      double sumNetR = 0.0;

      //--- kumpulkan positionId unik milik EA ini
      long ids[];
      int  nIds = 0;
      for(int i = 0; i < total; i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0) continue;
         if(HistoryDealGetString(dt, DEAL_SYMBOL) != symbol) continue;
         if(HistoryDealGetInteger(dt, DEAL_MAGIC) != magic)  continue;
         long pid = (long)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
         bool seen = false;
         for(int k = 0; k < nIds; k++) if(ids[k] == pid) { seen = true; break; }
         if(!seen) { ArrayResize(ids, nIds + 1); ids[nIds++] = pid; }
        }

      //--- agregasi per posisi
      for(int k = 0; k < nIds; k++)
        {
         long pid = ids[k];
         datetime tIn = 0, tOut = 0;
         double pIn = 0, pOut = 0, lots = 0;
         double gross = 0, comm = 0, swap = 0;
         int dir = 0;
         bool closed = false;

         for(int i = 0; i < total; i++)
           {
            ulong dt = HistoryDealGetTicket(i);
            if(dt == 0) continue;
            if((long)HistoryDealGetInteger(dt, DEAL_POSITION_ID) != pid) continue;
            if(HistoryDealGetString(dt, DEAL_SYMBOL) != symbol) continue;

            long entry = HistoryDealGetInteger(dt, DEAL_ENTRY);
            comm  += HistoryDealGetDouble(dt, DEAL_COMMISSION);
            swap  += HistoryDealGetDouble(dt, DEAL_SWAP);
            gross += HistoryDealGetDouble(dt, DEAL_PROFIT);

            if(entry == DEAL_ENTRY_IN)
              {
               tIn  = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
               pIn  = HistoryDealGetDouble(dt, DEAL_PRICE);
               lots = HistoryDealGetDouble(dt, DEAL_VOLUME);
               dir  = (HistoryDealGetInteger(dt, DEAL_TYPE) == DEAL_TYPE_BUY) ? 1 : -1;
              }
            else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
              {
               tOut = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
               pOut = HistoryDealGetDouble(dt, DEAL_PRICE);
               closed = true;
              }
           }
         if(!closed) continue;   // posisi masih terbuka di akhir test — tidak masuk distribusi R

         double net = gross + comm + swap;   // comm & swap bernilai negatif dari API

         int idx = FindPos(pid);
         double risk = (idx >= 0 ? m_posRisk[idx] : 0.0);
         string exitR = (idx >= 0 ? ExitReasonToString((EExitReason)m_posExitReason[idx]) : "NONE");

         double rNet  = (risk > 0 ? net / risk : 0.0);
         double rSwap = (risk > 0 ? swap / risk : 0.0);   // kolom audit: beban swap dalam R
         sumNetR += rNet;

         int barsHeld = (tIn > 0 && tOut > 0) ? Bars(symbol, PERIOD_H1, tIn, tOut) - 1 : 0;

         if(h2 != INVALID_HANDLE)
            FileWriteString(h2, StringFormat("%I64d;%d;%s;%.2f;%.4f;%s;%.2f;%d;%.2f;%.2f;%.2f;%.2f;%.2f;%.4f;%.4f;%s\n",
                            pid, dir,
                            TimeToString(tIn,  TIME_DATE | TIME_MINUTES), pIn, lots,
                            TimeToString(tOut, TIME_DATE | TIME_MINUTES), pOut, barsHeld,
                            gross, comm, swap, net, risk, rNet, rSwap, exitR));
        }

      if(h2 != INVALID_HANDLE) FileClose(h2);
      return sumNetR;   // metrik primer protokol validasi: total net R (net-of-swap)
     }
  };

#endif // XTC_DECISIONLOGGER_MQH
