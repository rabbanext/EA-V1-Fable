//+------------------------------------------------------------------+
//| Types.mqh — enum, struct, konstanta bersama                      |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Semua konstanta desain (bukan parameter optimasi) tinggal di     |
//| sini supaya tidak ada "angka telanjang" tersebar di modul.       |
//+------------------------------------------------------------------+
#ifndef XTC_TYPES_MQH
#define XTC_TYPES_MQH

//--- Konstanta desain — TERKUNCI oleh blueprint, bukan input/optimasi
#define XTC_EMA_SLOW_H4       200   // filter arah: close H4 vs EMA200
#define XTC_EMA_FAST_H4        50   // slope: EMA50 H4
#define XTC_SPREAD_MEDIAN_WIN  24   // jendela median spread (konstanta tetap, blueprint)
#define XTC_MAX_OPEN_RETRY      3   // percobaan kirim order per bar sinyal
#define XTC_SLIPPAGE_ANOMALY  1.0   // fill meleset > $1 dari harga diminta = anomali (live)

//--- Status filter arah H4 (tiga keadaan; flicker jatuh ke NEUTRAL)
enum EBias
  {
   BIAS_LONG    = 1,
   BIAS_SHORT   = -1,
   BIAS_NEUTRAL = 0
  };

//--- Lengan eksperimen time-stop. Nilai enum = jumlah bar (TS_NONE=0 berarti mati).
enum ETimeStopMode
  {
   TS_NONE = 0,   // tanpa time-stop
   TS_48   = 48,  // default blueprint
   TS_96   = 96
  };

//--- Alasan penolakan entry / sinyal terblokir. Urutan = urutan gerbang evaluasi.
//    RJ_POSITION_OPEN adalah metrik kunci uji 3-lengan time-stop (slot terisi).
enum ERejectReason
  {
   RJ_NONE = 0,
   RJ_KILL_SWITCH,      // -15% dari HWM, EA inert permanen
   RJ_WEEKLY_LIMIT,     // -5% mingguan, flat sampai Senin
   RJ_DAILY_LIMIT,      // -2% harian, stop entry sampai esok
   RJ_POSITION_OPEN,    // sinyal valid tapi slot terisi  <-- metrik eksperimen
   RJ_SESSION,          // di luar 07:00-20:00 GMT
   RJ_NEWS,             // dalam +/-15 menit event makro
   RJ_SPREAD,           // spread > 2x median 24 bar
   RJ_SPREAD_WARMUP,    // buffer median belum penuh (24 bar pertama) — tolak konservatif
   RJ_NEUTRAL_BIAS,     // filter H4 netral
   RJ_NO_BREAKOUT,      // close tidak menembus channel Donchian
   RJ_DISPLACEMENT,     // menembus tapi < 0,25 x ATR di luar level
   RJ_DUPLICATE_BAR,    // sudah ada percobaan entry di bar sinyal ini
   RJ_LOT_BELOW_MIN,    // hasil sizing < lot minimum broker (lihat docs/00)
   RJ_COUNT             // sentinel: ukuran array counter
  };

//--- Konversi alasan -> teks log (dipakai DecisionLogger)
string RejectReasonToString(const ERejectReason r)
  {
   switch(r)
     {
      case RJ_NONE:          return "NONE";
      case RJ_KILL_SWITCH:   return "KILL_SWITCH";
      case RJ_WEEKLY_LIMIT:  return "WEEKLY_LIMIT";
      case RJ_DAILY_LIMIT:   return "DAILY_LIMIT";
      case RJ_POSITION_OPEN: return "POSITION_OPEN";
      case RJ_SESSION:       return "SESSION";
      case RJ_NEWS:          return "NEWS";
      case RJ_SPREAD:        return "SPREAD";
      case RJ_SPREAD_WARMUP: return "SPREAD_WARMUP";
      case RJ_NEUTRAL_BIAS:  return "NEUTRAL_BIAS";
      case RJ_NO_BREAKOUT:   return "NO_BREAKOUT";
      case RJ_DISPLACEMENT:  return "DISPLACEMENT";
      case RJ_DUPLICATE_BAR: return "DUPLICATE_BAR";
      case RJ_LOT_BELOW_MIN: return "LOT_BELOW_MIN";
      default:               return "UNKNOWN";
     }
  }

//--- Alasan exit (untuk log & trade list)
enum EExitReason
  {
   EX_NONE = 0,
   EX_SL,            // SL awal kena (belum pernah di-trail)
   EX_TRAIL,         // SL hasil trailing kena
   EX_TIMESTOP,      // 48/96 bar tanpa +1R
   EX_WEEKLY_FLAT,   // weekly -5% memaksa flat
   EX_KILL,          // kill switch memaksa flat
   EX_MANUAL_OTHER   // ditutup di luar EA (manual/stop-out) — anomali, dilog
  };

string ExitReasonToString(const EExitReason r)
  {
   switch(r)
     {
      case EX_SL:           return "SL";
      case EX_TRAIL:        return "TRAIL";
      case EX_TIMESTOP:     return "TIMESTOP";
      case EX_WEEKLY_FLAT:  return "WEEKLY_FLAT";
      case EX_KILL:         return "KILL";
      case EX_MANUAL_OTHER: return "MANUAL_OTHER";
      default:              return "NONE";
     }
  }

//--- Snapshot pasar: SATU-SATUNYA jalur data terminal -> modul.
//    Diisi adapter di file EA utama, sekali per bar H1 baru.
//    Modul tidak boleh memanggil iClose/SymbolInfo sendiri (testabilitas).
struct SMarketSnapshot
  {
   datetime          barTimeH1;     // open time bar sinyal (shift 1)
   double            h1Close1;      // close bar H1 tertutup terakhir
   double            donchianHi;    // Highest(High) shift 2..(2+N-1) — bar sinyal TIDAK ikut
   double            donchianLo;    // Lowest(Low) shift 2..(2+N-1)
   double            atrH1;         // ATR(period, H1) pada shift 1
   double            spreadNow;     // spread saat evaluasi, dalam $ (harga)
   double            spreadMedian;  // median ring buffer 24 sampel
   bool              spreadReady;   // buffer median sudah penuh?
   EBias             h4Bias;        // hasil filter H4 (cache per bar H4)
   // konteks H4 untuk logging/audit (bukan untuk keputusan ulang):
   double            ema200H4;
   double            ema50H4_1;     // EMA50[1]
   double            ema50H4_lb;    // EMA50[1+lookback]
  };

//--- Hasil evaluasi sinyal entry
struct SEntrySignal
  {
   bool              valid;
   EBias             dir;
   ERejectReason     reject;   // terisi jika !valid
  };

//--- Spesifikasi volume & nilai simbol (disuntik ke RiskModule agar bisa diuji)
struct SSymbolVol
  {
   double            tickValue;   // P/L per tick per 1 lot, dalam mata uang akun
   double            tickSize;    // ukuran tick harga
   double            volMin;
   double            volMax;
   double            volStep;
  };

#endif // XTC_TYPES_MQH
