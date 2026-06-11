//+------------------------------------------------------------------+
//| StateStore.mqh — persistensi status lintas restart (live)        |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Yang disimpan: HWM, anchor harian/mingguan + id periode, flag    |
//| lock (daily/weekly/KILL), dan state trade berjalan (stopDistance,|
//| reached1R, dst). Tanpa ini, restart terminal MERESET proteksi —  |
//| kill switch yang bisa di-reset dengan restart bukan kill switch. |
//|                                                                  |
//| Di Strategy Tester: persistensi DIMATIKAN (tiap pass mulai       |
//| bersih). Format file: key=value per baris, folder Files lokal.   |
//+------------------------------------------------------------------+
#ifndef XTC_STATESTORE_MQH
#define XTC_STATESTORE_MQH

//--- Seluruh status persisten dalam satu struct (mudah di-save/load utuh)
struct SPersistState
  {
   // guard ekuitas
   double            hwm;
   double            dayAnchor;
   double            weekAnchor;
   long              dayId;
   long              weekId;
   bool              dailyLock;
   bool              weeklyLock;
   bool              killLock;
   // trade berjalan (positionId=0 berarti tidak ada)
   long              positionId;
   double            entryPrice;
   double            stopDistance;   // jarak SL awal dalam harga (basis R)
   double            riskMoney;      // $ dirisikokan saat entry (basis R-multiple laporan)
   datetime          entryBarTime;   // open time bar saat entry
   bool              reached1R;      // pernah menyentuh +1R (disarm time-stop permanen)
   bool              slWasTrailed;   // SL pernah digeser trailing (bedakan EX_SL vs EX_TRAIL)
   int               direction;      // +1 long, -1 short
  };

class CStateStore
  {
private:
   string            m_fileName;
   bool              m_enabled;   // false di tester

public:
   void              Init(const string symbol, const long magic)
     {
      // satu file per simbol+magic+akun -> dua EA tidak saling menimpa
      m_fileName = StringFormat("XTC_state_%s_%I64d_%I64d.txt",
                                symbol, magic, AccountInfoInteger(ACCOUNT_LOGIN));
      m_enabled = !MQLInfoInteger(MQL_TESTER);   // tester: tiap pass mulai bersih
     }

   static void       Reset(SPersistState &s)
     {
      s.hwm = 0.0; s.dayAnchor = 0.0; s.weekAnchor = 0.0;
      s.dayId = -1; s.weekId = -1;
      s.dailyLock = false; s.weeklyLock = false; s.killLock = false;
      s.positionId = 0; s.entryPrice = 0.0; s.stopDistance = 0.0; s.riskMoney = 0.0;
      s.entryBarTime = 0; s.reached1R = false; s.slWasTrailed = false; s.direction = 0;
     }

   bool              Save(const SPersistState &s)
     {
      if(!m_enabled) return true;
      int h = FileOpen(m_fileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE) return false;
      FileWriteString(h, StringFormat("hwm=%.2f\n",          s.hwm));
      FileWriteString(h, StringFormat("dayAnchor=%.2f\n",    s.dayAnchor));
      FileWriteString(h, StringFormat("weekAnchor=%.2f\n",   s.weekAnchor));
      FileWriteString(h, StringFormat("dayId=%I64d\n",       s.dayId));
      FileWriteString(h, StringFormat("weekId=%I64d\n",      s.weekId));
      FileWriteString(h, StringFormat("dailyLock=%d\n",      s.dailyLock ? 1 : 0));
      FileWriteString(h, StringFormat("weeklyLock=%d\n",     s.weeklyLock ? 1 : 0));
      FileWriteString(h, StringFormat("killLock=%d\n",       s.killLock ? 1 : 0));
      FileWriteString(h, StringFormat("positionId=%I64d\n",  s.positionId));
      FileWriteString(h, StringFormat("entryPrice=%.5f\n",   s.entryPrice));
      FileWriteString(h, StringFormat("stopDistance=%.5f\n", s.stopDistance));
      FileWriteString(h, StringFormat("riskMoney=%.2f\n",    s.riskMoney));
      FileWriteString(h, StringFormat("entryBarTime=%I64d\n",(long)s.entryBarTime));
      FileWriteString(h, StringFormat("reached1R=%d\n",      s.reached1R ? 1 : 0));
      FileWriteString(h, StringFormat("slWasTrailed=%d\n",   s.slWasTrailed ? 1 : 0));
      FileWriteString(h, StringFormat("direction=%d\n",      s.direction));
      FileClose(h);
      return true;
     }

   //--- Return false bila file tidak ada (run pertama) — caller pakai Reset()
   bool              Load(SPersistState &s)
     {
      Reset(s);
      if(!m_enabled) return false;
      int h = FileOpen(m_fileName, FILE_READ | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE) return false;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         string kv[];
         if(StringSplit(line, '=', kv) != 2) continue;
         string k = kv[0], v = kv[1];
         if(k == "hwm")          s.hwm          = StringToDouble(v);
         else if(k == "dayAnchor")    s.dayAnchor    = StringToDouble(v);
         else if(k == "weekAnchor")   s.weekAnchor   = StringToDouble(v);
         else if(k == "dayId")        s.dayId        = StringToInteger(v);
         else if(k == "weekId")       s.weekId       = StringToInteger(v);
         else if(k == "dailyLock")    s.dailyLock    = (StringToInteger(v) != 0);
         else if(k == "weeklyLock")   s.weeklyLock   = (StringToInteger(v) != 0);
         else if(k == "killLock")     s.killLock     = (StringToInteger(v) != 0);
         else if(k == "positionId")   s.positionId   = StringToInteger(v);
         else if(k == "entryPrice")   s.entryPrice   = StringToDouble(v);
         else if(k == "stopDistance") s.stopDistance = StringToDouble(v);
         else if(k == "riskMoney")    s.riskMoney    = StringToDouble(v);
         else if(k == "entryBarTime") s.entryBarTime = (datetime)StringToInteger(v);
         else if(k == "reached1R")    s.reached1R    = (StringToInteger(v) != 0);
         else if(k == "slWasTrailed") s.slWasTrailed = (StringToInteger(v) != 0);
         else if(k == "direction")    s.direction    = (int)StringToInteger(v);
        }
      FileClose(h);
      return true;
     }
  };

#endif // XTC_STATESTORE_MQH
