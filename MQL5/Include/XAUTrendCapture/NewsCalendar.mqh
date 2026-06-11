//+------------------------------------------------------------------+
//| NewsCalendar.mqh — kalender ekonomi historis via CSV             |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Fungsi kalender bawaan MQL5 TIDAK berjalan di Strategy Tester.   |
//| Maka backtest DAN live memakai jalur kode yang sama: CSV berisi  |
//| timestamp GMT event makro (NFP/CPI/FOMC/rate decision). Satu     |
//| logika, dua mode — tidak ada cabang \"kalau live pakai kalender\". |
//|                                                                  |
//| Format file (MQL5/Files atau folder Common):                     |
//|   YYYY.MM.DD HH:MM;TAG                                           |
//|   contoh: 2015.01.09 13:30;NFP                                   |
//| Baris kosong / diawali '#' diabaikan. Waktu = GMT.               |
//+------------------------------------------------------------------+
#ifndef XTC_NEWSCALENDAR_MQH
#define XTC_NEWSCALENDAR_MQH

class CNewsCalendar
  {
private:
   datetime          m_events[];   // terurut menaik
   string            m_tags[];
   int               m_count;

   //--- insertion sort bersama tag (file bisa saja tidak terurut)
   void              SortEvents()
     {
      for(int i = 1; i < m_count; i++)
        {
         datetime ev = m_events[i];
         string   tg = m_tags[i];
         int j = i - 1;
         while(j >= 0 && m_events[j] > ev)
           {
            m_events[j + 1] = m_events[j];
            m_tags[j + 1]   = m_tags[j];
            j--;
           }
         m_events[j + 1] = ev;
         m_tags[j + 1]   = tg;
        }
     }

public:
   int               Count() const { return m_count; }

   //--- Muat CSV. Coba folder Files lokal dulu, lalu folder Common
   //    (agen tester lokal bisa membaca Common). Return false bila gagal.
   bool              Load(const string fileName)
     {
      m_count = 0;
      ArrayResize(m_events, 0);
      ArrayResize(m_tags, 0);

      int h = FileOpen(fileName, FILE_READ | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE)
         h = FileOpen(fileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;

      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         StringTrimLeft(line);
         StringTrimRight(line);
         if(StringLen(line) == 0)            continue;
         if(StringGetCharacter(line, 0) == '#') continue;

         string parts[];
         int n = StringSplit(line, ';', parts);
         if(n < 1) continue;

         datetime t = StringToTime(parts[0]);   // "YYYY.MM.DD HH:MM" -> datetime (tanpa TZ; kita definisikan = GMT)
         if(t <= 0) continue;

         int idx = m_count;
         ArrayResize(m_events, idx + 1);
         ArrayResize(m_tags,   idx + 1);
         m_events[idx] = t;
         m_tags[idx]   = (n >= 2 ? parts[1] : "EVENT");
         m_count++;
        }
      FileClose(h);

      SortEvents();
      return (m_count > 0);
     }

   //--- Injeksi langsung (untuk unit test, tanpa file)
   void              AddEvent(const datetime gmt, const string tag)
     {
      int idx = m_count;
      ArrayResize(m_events, idx + 1);
      ArrayResize(m_tags,   idx + 1);
      m_events[idx] = gmt;
      m_tags[idx]   = tag;
      m_count++;
      SortEvents();
     }

   //--- Apakah nowGMT berada dalam +/- windowMin menit dari event mana pun?
   //    Batas INKLUSIF: |now - event| <= window. Binary search event terdekat.
   bool              IsBlocked(const datetime nowGMT, const int windowMin, string &tagOut) const
     {
      tagOut = "";
      if(m_count == 0) return false;

      long w = (long)windowMin * 60;
      int lo = 0, hi = m_count - 1;
      while(lo < hi)                       // cari event pertama >= nowGMT
        {
         int mid = (lo + hi) / 2;
         if(m_events[mid] < nowGMT) lo = mid + 1;
         else                       hi = mid;
        }
      // kandidat: lo dan lo-1 (event sesudah & sebelum nowGMT)
      for(int k = lo; k >= lo - 1; k--)
        {
         if(k < 0 || k >= m_count) continue;
         long diff = (long)nowGMT - (long)m_events[k];
         if(diff < 0) diff = -diff;
         if(diff <= w)
           {
            tagOut = m_tags[k];
            return true;
           }
        }
      return false;
     }
  };

#endif // XTC_NEWSCALENDAR_MQH
