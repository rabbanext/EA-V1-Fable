//+------------------------------------------------------------------+
//| TimeUtils.mqh — konversi waktu server <-> GMT, kalender harian   |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Semua aturan blueprint (sesi, daily/weekly, news) memakai GMT.   |
//| Exness MT5 memakai server UTC+0 sepanjang tahun -> offset default |
//| 0/0; input tetap disediakan untuk broker lain. WAJIB diverifikasi |
//| pemilik akun: bandingkan jam Market Watch dengan UTC.            |
//|                                                                  |
//| Catatan presisi DST: transisi DST AS dihitung pada granularitas  |
//| HARI (bukan jam 02:00 lokal). Galat maksimum 1-2 jam hanya pada  |
//| dua hari transisi per tahun — keduanya hari MINGGU (pasar tutup/ |
//| baru buka), jadi dampak praktis nol. Didokumentasikan, bukan     |
//| disembunyikan.                                                   |
//+------------------------------------------------------------------+
#ifndef XTC_TIMEUTILS_MQH
#define XTC_TIMEUTILS_MQH

class CGmtClock
  {
private:
   int               m_offsetWinterH;  // jam: server = GMT + offset (mis. EET musim dingin = +2)
   int               m_offsetSummerH;  // jam: server saat DST AS aktif (mis. +3)

public:
   void              Init(const int offsetWinterHours, const int offsetSummerHours)
     {
      m_offsetWinterH = offsetWinterHours;
      m_offsetSummerH = offsetSummerHours;
     }

   //--- Hari-dalam-pekan tanggal 1 bulan m tahun y (0=Minggu..6=Sabtu)
   static int        DayOfWeekFirst(const int year, const int month)
     {
      MqlDateTime dt;
      datetime t = StringToTime(StringFormat("%04d.%02d.01 00:00", year, month));
      TimeToStruct(t, dt);
      return dt.day_of_week;
     }

   //--- Apakah tanggal (waktu server, granularitas hari) berada dalam DST AS?
   //    DST AS: Minggu ke-2 Maret s/d Minggu ke-1 November.
   static bool       IsUSDst(const datetime t)
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      if(dt.mon < 3 || dt.mon > 11) return false;
      if(dt.mon > 3 && dt.mon < 11) return true;
      if(dt.mon == 3)
        {
         int dow1     = DayOfWeekFirst(dt.year, 3);
         int firstSun = 1 + ((7 - dow1) % 7);
         int secondSun= firstSun + 7;
         return (dt.day >= secondSun);
        }
      // November
      int dow1n     = DayOfWeekFirst(dt.year, 11);
      int firstSunN = 1 + ((7 - dow1n) % 7);
      return (dt.day < firstSunN);
     }

   //--- Konversi waktu server -> GMT
   datetime          ToGMT(const datetime serverTime) const
     {
      int off = IsUSDst(serverTime) ? m_offsetSummerH : m_offsetWinterH;
      return serverTime - (datetime)(off * 3600);
     }

   //--- Identitas hari GMT (integer naik 1 per hari) — untuk deteksi rollover daily
   static long       DayId(const datetime gmt) { return (long)gmt / 86400; }

   //--- Identitas pekan GMT berbasis SENIN 00:00 — untuk rollover weekly.
   //    Epoch 1970-01-01 = Kamis: dow = (dayId+4) % 7 (0=Minggu).
   static long       WeekId(const datetime gmt)
     {
      long d   = DayId(gmt);
      int  dow = (int)((d + 4) % 7);          // 0=Min,1=Sen,...,6=Sab
      int  sinceMonday = (dow + 6) % 7;       // Sen->0, Sel->1, ..., Min->6
      return d - sinceMonday;
     }

   //--- Jam GMT 0..23 (untuk jendela sesi)
   static int        HourOf(const datetime gmt)
     {
      MqlDateTime dt;
      TimeToStruct(gmt, dt);
      return dt.hour;
     }
  };

#endif // XTC_TIMEUTILS_MQH
