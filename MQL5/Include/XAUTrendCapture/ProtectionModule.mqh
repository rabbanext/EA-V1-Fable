//+------------------------------------------------------------------+
//| ProtectionModule.mqh — spread, sesi, news, daily/weekly/kill     |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Basis SEMUA limit ekuitas: AccountEquity TERMASUK floating P/L,  |
//| relatif terhadap ekuitas AWAL periode (anchor), waktu GMT.       |
//| Modul ini hanya MENGHITUNG dan MENYIMPAN status; aksi (menutup   |
//| posisi, alert) dilakukan EA utama berdasarkan event yang         |
//| dikembalikan — modul tetap bebas efek samping agar bisa diuji.   |
//+------------------------------------------------------------------+
#ifndef XTC_PROTECTIONMODULE_MQH
#define XTC_PROTECTIONMODULE_MQH

#include "Types.mqh"
#include "TimeUtils.mqh"
#include "NewsCalendar.mqh"

//--- Event yang dikembalikan UpdateEquityGuards (EA utama yang mengeksekusi aksinya)
struct SGuardEvents
  {
   bool              killTriggeredNow;     // baru saja menembus -15% HWM
   bool              weeklyTriggeredNow;   // baru saja menembus -5% mingguan
   bool              dailyTriggeredNow;    // baru saja menembus -2% harian
   bool              newDay;               // rollover hari GMT
   bool              newWeek;              // rollover pekan GMT (Senin 00:00)
  };

class CProtectionModule
  {
private:
   //--- parameter (dari input EA)
   int               m_sessionStartH;   // jam GMT mulai entry (default 7)
   int               m_sessionEndH;     // jam GMT akhir entry, EKSKLUSIF (default 20)
   double            m_spreadCapMult;   // default 2,0 x median
   int               m_newsWindowMin;   // default 15 menit
   double            m_dailyLossPct;    // konstanta desain 2,0
   double            m_weeklyLossPct;   // konstanta desain 5,0
   double            m_killPct;         // konstanta desain 15,0 (dari HWM)

   //--- ring buffer spread: 1 sampel per bar H1, jendela konstanta XTC_SPREAD_MEDIAN_WIN
   double            m_spreadBuf[XTC_SPREAD_MEDIAN_WIN];
   int               m_spreadIdx;
   int               m_spreadCnt;

   //--- status ekuitas (persistensi via StateStore di EA utama)
   double            m_hwm;
   double            m_dayAnchor;
   double            m_weekAnchor;
   long              m_dayId;
   long              m_weekId;
   bool              m_dailyLock;
   bool              m_weeklyLock;
   bool              m_killLock;

public:
   CNewsCalendar     news;   // publik: EA memuat CSV, unit test menyuntik event

   void              Init(const int sessStartH, const int sessEndH, const double spreadCapMult,
                          const int newsWindowMin, const double dailyPct, const double weeklyPct,
                          const double killPct)
     {
      m_sessionStartH = sessStartH;
      m_sessionEndH   = sessEndH;
      m_spreadCapMult = spreadCapMult;
      m_newsWindowMin = newsWindowMin;
      m_dailyLossPct  = dailyPct;
      m_weeklyLossPct = weeklyPct;
      m_killPct       = killPct;
      m_spreadIdx = 0;
      m_spreadCnt = 0;
      ArrayInitialize(m_spreadBuf, 0.0);
      m_hwm = 0.0; m_dayAnchor = 0.0; m_weekAnchor = 0.0;
      m_dayId = -1; m_weekId = -1;
      m_dailyLock = false; m_weeklyLock = false; m_killLock = false;
     }

   //================== SPREAD =====================

   //--- Satu sampel per bar H1 (dipanggil EA saat bar baru). Titik sampling =
   //    deteksi bar baru; konstanta desain, bukan parameter.
   void              SampleSpread(const double spreadPrice)
     {
      m_spreadBuf[m_spreadIdx] = spreadPrice;
      m_spreadIdx = (m_spreadIdx + 1) % XTC_SPREAD_MEDIAN_WIN;
      if(m_spreadCnt < XTC_SPREAD_MEDIAN_WIN) m_spreadCnt++;
     }

   bool              SpreadReady() const { return m_spreadCnt >= XTC_SPREAD_MEDIAN_WIN; }

   //--- Median jendela penuh (rata-rata dua elemen tengah; jumlah genap 24)
   double            SpreadMedian() const
     {
      if(m_spreadCnt == 0) return 0.0;
      double tmp[];
      ArrayResize(tmp, m_spreadCnt);
      int n = 0;
      for(int i = 0; i < m_spreadCnt; i++) tmp[n++] = m_spreadBuf[i];
      ArraySort(tmp);
      if(m_spreadCnt % 2 == 1) return tmp[m_spreadCnt / 2];
      return 0.5 * (tmp[m_spreadCnt / 2 - 1] + tmp[m_spreadCnt / 2]);
     }

   //================== SESI =====================

   //--- [startH, endH) — entry jam 07:00:00 boleh, 20:00:00 tidak.
   static bool       InSession(const int hourGMT, const int startH, const int endH)
     {
      return (hourGMT >= startH && hourGMT < endH);
     }

   //================== GUARD EKUITAS =====================

   //--- Pulihkan status dari StateStore (live, setelah restart)
   void              RestoreState(const double hwm, const double dayAnchor, const double weekAnchor,
                                  const long dayId, const long weekId,
                                  const bool dailyLock, const bool weeklyLock, const bool killLock)
     {
      m_hwm = hwm; m_dayAnchor = dayAnchor; m_weekAnchor = weekAnchor;
      m_dayId = dayId; m_weekId = weekId;
      m_dailyLock = dailyLock; m_weeklyLock = weeklyLock; m_killLock = killLock;
     }

   double            Hwm()        const { return m_hwm; }
   double            DayAnchor()  const { return m_dayAnchor; }
   double            WeekAnchor() const { return m_weekAnchor; }
   long              DayIdCur()   const { return m_dayId; }
   long              WeekIdCur()  const { return m_weekId; }
   bool              DailyLock()  const { return m_dailyLock; }
   bool              WeeklyLock() const { return m_weeklyLock; }
   bool              KillLock()   const { return m_killLock; }

   //--- Dipanggil SETIAP tick (murah: beberapa perbandingan).
   //    equity = AccountEquity (termasuk floating). gmt = waktu GMT saat ini.
   SGuardEvents      UpdateEquityGuards(const double equity, const datetime gmt)
     {
      SGuardEvents ev;
      ev.killTriggeredNow = false;
      ev.weeklyTriggeredNow = false;
      ev.dailyTriggeredNow = false;
      ev.newDay = false;
      ev.newWeek = false;

      //--- rollover periode: anchor = ekuitas AWAL periode, lock di-reset
      long d = CGmtClock::DayId(gmt);
      long w = CGmtClock::WeekId(gmt);
      if(d != m_dayId)
        {
         m_dayId = d;
         m_dayAnchor = equity;
         m_dailyLock = false;
         ev.newDay = true;
        }
      if(w != m_weekId)
        {
         m_weekId = w;
         m_weekAnchor = equity;
         m_weeklyLock = false;
         ev.newWeek = true;
        }

      //--- high-water mark (kill switch diukur dari sini)
      if(equity > m_hwm) m_hwm = equity;

      //--- kill switch: -15% dari HWM. Permanen sampai reset manual.
      if(!m_killLock && m_hwm > 0.0 && equity <= m_hwm * (1.0 - m_killPct / 100.0))
        {
         m_killLock = true;
         ev.killTriggeredNow = true;
        }

      //--- weekly -5%: flat semua + berhenti sampai Senin (EA yang menutup posisi)
      if(!m_weeklyLock && m_weekAnchor > 0.0 &&
         equity <= m_weekAnchor * (1.0 - m_weeklyLossPct / 100.0))
        {
         m_weeklyLock = true;
         ev.weeklyTriggeredNow = true;
        }

      //--- daily -2%: stop ENTRY saja; posisi berjalan TIDAK ditutup
      if(!m_dailyLock && m_dayAnchor > 0.0 &&
         equity <= m_dayAnchor * (1.0 - m_dailyLossPct / 100.0))
        {
         m_dailyLock = true;
         ev.dailyTriggeredNow = true;
        }

      return ev;
     }

   //================== GERBANG ENTRY =====================

   //--- Urutan cek = urutan blueprint (termurah/terkeras dulu). Hanya untuk ENTRY;
   //    exit tidak pernah difilter. Return false + alasan pertama yang gagal.
   bool              CanEnter(const SMarketSnapshot &s, const datetime gmt, ERejectReason &rj)
     {
      rj = RJ_NONE;
      if(m_killLock)   { rj = RJ_KILL_SWITCH;  return false; }
      if(m_weeklyLock) { rj = RJ_WEEKLY_LIMIT; return false; }
      if(m_dailyLock)  { rj = RJ_DAILY_LIMIT;  return false; }

      if(!InSession(CGmtClock::HourOf(gmt), m_sessionStartH, m_sessionEndH))
        { rj = RJ_SESSION; return false; }

      string tag;
      if(news.IsBlocked(gmt, m_newsWindowMin, tag))
        { rj = RJ_NEWS; return false; }

      if(!s.spreadReady)
        { rj = RJ_SPREAD_WARMUP; return false; }   // 24 bar pertama: tolak konservatif
      if(s.spreadNow > m_spreadCapMult * s.spreadMedian)
        { rj = RJ_SPREAD; return false; }

      return true;
     }
  };

#endif // XTC_PROTECTIONMODULE_MQH
