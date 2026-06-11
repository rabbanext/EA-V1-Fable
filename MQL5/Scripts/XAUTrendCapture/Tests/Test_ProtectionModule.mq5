//+------------------------------------------------------------------+
//| Test_ProtectionModule.mq5 — unit test proteksi, waktu, news,     |
//| chandelier monotonic                                             |
//+------------------------------------------------------------------+
#property script_show_inputs false
#property strict

#include <XAUTrendCapture/Types.mqh>
#include <XAUTrendCapture/TimeUtils.mqh>
#include <XAUTrendCapture/ProtectionModule.mqh>
#include <XAUTrendCapture/ExecutionModule.mqh>

int g_pass = 0, g_fail = 0;

void AssertTrue(const string name, const bool cond)
  {
   if(cond) { g_pass++; }
   else     { g_fail++; Print("FAIL: ", name); }
  }

void AssertEq(const string name, const double a, const double b, const double eps = 1e-9)
  {
   if(MathAbs(a - b) <= eps) { g_pass++; }
   else { g_fail++; PrintFormat("FAIL: %s (%.6f != %.6f)", name, a, b); }
  }

void OnStart()
  {
   //=========== Jendela sesi [7, 20) GMT ===========
   AssertTrue("06:59 ditolak",  !CProtectionModule::InSession(6, 7, 20));
   AssertTrue("07:00 boleh",     CProtectionModule::InSession(7, 7, 20));
   AssertTrue("19:xx boleh",     CProtectionModule::InSession(19, 7, 20));
   AssertTrue("20:00 ditolak",  !CProtectionModule::InSession(20, 7, 20));

   //=========== DST AS (granularitas hari) ===========
   // 2024: mulai Minggu 10 Mar, berakhir Minggu 3 Nov
   AssertTrue("2024.03.09 bukan DST", !CGmtClock::IsUSDst(StringToTime("2024.03.09 12:00")));
   AssertTrue("2024.03.10 DST",        CGmtClock::IsUSDst(StringToTime("2024.03.10 12:00")));
   AssertTrue("2024.11.02 DST",        CGmtClock::IsUSDst(StringToTime("2024.11.02 12:00")));
   AssertTrue("2024.11.03 bukan DST", !CGmtClock::IsUSDst(StringToTime("2024.11.03 12:00")));
   AssertTrue("Juli DST",              CGmtClock::IsUSDst(StringToTime("2024.07.15 12:00")));
   AssertTrue("Januari bukan DST",    !CGmtClock::IsUSDst(StringToTime("2024.01.15 12:00")));

   //=========== DayId / WeekId (Senin 00:00 GMT) ===========
   // 2024.06.10 = Senin; 2024.06.09 (Minggu) harus pekan SEBELUMNYA
   long wMon = CGmtClock::WeekId(StringToTime("2024.06.10 00:00"));
   long wSun = CGmtClock::WeekId(StringToTime("2024.06.09 23:59"));
   long wFri = CGmtClock::WeekId(StringToTime("2024.06.14 23:59"));
   AssertTrue("Minggu < Senin (pekan beda)", wSun < wMon);
   AssertTrue("Jumat pekan yang sama dengan Senin", wFri == wMon);
   AssertTrue("DayId naik 1 per hari",
              CGmtClock::DayId(StringToTime("2024.06.11 00:00")) ==
              CGmtClock::DayId(StringToTime("2024.06.10 12:00")) + 1);

   //=========== Guard ekuitas: anchor awal periode, lock, kill HWM ===========
   CProtectionModule p;
   p.Init(7, 20, 2.0, 15, 2.0, 5.0, 15.0);
   datetime t0 = StringToTime("2024.06.10 08:00");   // Senin pagi

   SGuardEvents ev = p.UpdateEquityGuards(100000, t0);
   AssertTrue("hari baru terdeteksi", ev.newDay && ev.newWeek);
   AssertEq("day anchor = ekuitas awal", p.DayAnchor(), 100000);

   // turun 1,9% -> belum lock
   ev = p.UpdateEquityGuards(98100, t0 + 3600);
   AssertTrue("-1.9% belum daily lock", !p.DailyLock());
   // turun ke -2% persis -> daily lock; weekly belum
   ev = p.UpdateEquityGuards(98000, t0 + 7200);
   AssertTrue("-2.0% daily lock", p.DailyLock() && ev.dailyTriggeredNow);
   AssertTrue("weekly belum", !p.WeeklyLock());
   // hari berikutnya: lock reset, anchor baru = ekuitas saat itu
   ev = p.UpdateEquityGuards(98000, t0 + 86400);
   AssertTrue("daily lock reset esok", !p.DailyLock() && ev.newDay);
   AssertEq("anchor harian baru", p.DayAnchor(), 98000);

   // weekly: -5% dari anchor pekan (100000) -> 95000
   ev = p.UpdateEquityGuards(95000, t0 + 86400 + 3600);
   AssertTrue("weekly -5% terpicu", p.WeeklyLock() && ev.weeklyTriggeredNow);
   // Senin depan: weekly reset
   ev = p.UpdateEquityGuards(95000, StringToTime("2024.06.17 00:30"));
   AssertTrue("weekly reset Senin", !p.WeeklyLock() && ev.newWeek);

   // kill switch: HWM 100000 -> -15% = 85000
   ev = p.UpdateEquityGuards(85001, StringToTime("2024.06.17 01:00"));
   AssertTrue("-14.999% belum kill", !p.KillLock());
   ev = p.UpdateEquityGuards(85000, StringToTime("2024.06.17 02:00"));
   AssertTrue("-15% dari HWM -> kill", p.KillLock() && ev.killTriggeredNow);

   //=========== Median spread & warm-up ===========
   CProtectionModule q;
   q.Init(7, 20, 2.0, 15, 2.0, 5.0, 15.0);
   for(int i = 0; i < 23; i++) q.SampleSpread(0.20);
   AssertTrue("23 sampel: belum ready", !q.SpreadReady());
   q.SampleSpread(0.30);
   AssertTrue("24 sampel: ready", q.SpreadReady());
   // 23x 0.20 + 1x 0.30 -> dua tengah 0.20, 0.20 -> median 0.20
   AssertEq("median homogen", q.SpreadMedian(), 0.20, 1e-12);
   // dorong 12 sampel 0.40: buffer = 11x0.20 + 0.30 + 12x0.40 -> tengah (0.30+0.40)/2=0.35
   for(int i = 0; i < 12; i++) q.SampleSpread(0.40);
   AssertEq("median campuran", q.SpreadMedian(), 0.35, 1e-12);

   //=========== News window: batas inklusif ===========
   CNewsCalendar cal;
   cal.AddEvent(StringToTime("2024.06.12 13:30"), "CPI");
   cal.AddEvent(StringToTime("2024.06.12 18:00"), "FOMC");
   string tag;
   AssertTrue("13:15 terblokir (batas)",  cal.IsBlocked(StringToTime("2024.06.12 13:15"), 15, tag));
   AssertTrue("13:14:59 bebas",          !cal.IsBlocked(StringToTime("2024.06.12 13:14:59"), 15, tag));
   AssertTrue("13:45 terblokir (batas)",  cal.IsBlocked(StringToTime("2024.06.12 13:45"), 15, tag));
   AssertTrue("13:45:01 bebas",          !cal.IsBlocked(StringToTime("2024.06.12 13:45:01"), 15, tag));
   AssertTrue("17:50 terblokir FOMC",     cal.IsBlocked(StringToTime("2024.06.12 17:50"), 15, tag) && tag == "FOMC");
   AssertTrue("12:00 bebas",             !cal.IsBlocked(StringToTime("2024.06.12 12:00"), 15, tag));

   //=========== Chandelier monotonic (inti murni ExecutionModule) ===========
   // LONG entry 2000, ATR 10: SL awal 1980. Chandelier awal = 2000-30=1970 < 1980 -> DIABAIKAN
   AssertTrue("chandelier awal tidak memperburuk SL",
              !CExecutionModule::ShouldMoveSL(1, 1980.0, CExecutionModule::ComputeChandelier(1, 2000.0, 10.0, 3.0), 0.01));
   // close ekstrem 2015 -> kandidat 1985 > 1980 -> geser
   AssertTrue("chandelier menggeser setelah ekstrem +1.5xATR",
              CExecutionModule::ShouldMoveSL(1, 1980.0, CExecutionModule::ComputeChandelier(1, 2015.0, 10.0, 3.0), 0.01));
   // SHORT cermin: entry 2000, SL 2020; ekstrem 1985 -> kandidat 2015 < 2020 -> geser
   AssertTrue("short chandelier",
              CExecutionModule::ShouldMoveSL(-1, 2020.0, CExecutionModule::ComputeChandelier(-1, 1985.0, 10.0, 3.0), 0.01));
   // SHORT: kandidat lebih buruk (2025) -> abaikan
   AssertTrue("short tidak memperburuk",
              !CExecutionModule::ShouldMoveSL(-1, 2020.0, 2025.0, 0.01));

   PrintFormat("Test_ProtectionModule: %d PASS, %d FAIL %s",
               g_pass, g_fail, g_fail == 0 ? "— OK" : "— PERIKSA!");
  }
