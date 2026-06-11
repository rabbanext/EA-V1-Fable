//+------------------------------------------------------------------+
//| Test_SignalModule.mq5 — unit test inti murni SignalModule        |
//| Jalankan sebagai Script di chart mana pun; hasil di tab Experts. |
//+------------------------------------------------------------------+
#property script_show_inputs false
#property strict

#include <XAUTrendCapture/Types.mqh>
#include <XAUTrendCapture/SignalModule.mqh>

int g_pass = 0, g_fail = 0;

void AssertTrue(const string name, const bool cond)
  {
   if(cond) { g_pass++; }
   else     { g_fail++; Print("FAIL: ", name); }
  }

void AssertEqI(const string name, const long a, const long b)
  {
   if(a == b) { g_pass++; }
   else       { g_fail++; Print("FAIL: ", name, " (", a, " != ", b, ")"); }
  }

void OnStart()
  {
   //=========== ComputeBias: tiga keadaan, flicker -> NEUTRAL ===========
   // close>EMA200 & slope>0 -> LONG
   AssertEqI("bias long",            CSignalModule::ComputeBias(2010, 2000,  1.5, true), BIAS_LONG);
   // close<EMA200 & slope<0 -> SHORT
   AssertEqI("bias short",           CSignalModule::ComputeBias(1990, 2000, -1.5, true), BIAS_SHORT);
   // close>EMA200 tapi slope<0 (flicker) -> NEUTRAL, BUKAN membalik arah
   AssertEqI("flicker -> neutral",   CSignalModule::ComputeBias(2010, 2000, -0.1, true), BIAS_NEUTRAL);
   // slope == 0 persis -> NEUTRAL
   AssertEqI("slope 0 -> neutral",   CSignalModule::ComputeBias(2010, 2000,  0.0, true), BIAS_NEUTRAL);
   // close == EMA200 persis -> NEUTRAL (tidak ada sisi)
   AssertEqI("close==ema -> neutral",CSignalModule::ComputeBias(2000, 2000,  1.0, true), BIAS_NEUTRAL);
   // lengan B (useSlope=false): slope diabaikan total
   AssertEqI("armB long ignores slope",  CSignalModule::ComputeBias(2010, 2000, -9.9, false), BIAS_LONG);
   AssertEqI("armB short ignores slope", CSignalModule::ComputeBias(1990, 2000,  9.9, false), BIAS_SHORT);

   //=========== CheckBreakout: close di luar level + displacement ===========
   double hi = 2000.0, lo = 1950.0, atr = 10.0, disp = 0.25;  // ambang = level +/- 2.5

   // bias netral -> reject
   SEntrySignal s = CSignalModule::CheckBreakout(BIAS_NEUTRAL, 2010, hi, lo, atr, disp);
   AssertTrue("neutral reject", !s.valid && s.reject == RJ_NEUTRAL_BIAS);

   // LONG: close == level -> belum breakout (harus DI LUAR, bukan menyentuh)
   s = CSignalModule::CheckBreakout(BIAS_LONG, 2000.0, hi, lo, atr, disp);
   AssertTrue("close==hi -> no breakout", !s.valid && s.reject == RJ_NO_BREAKOUT);

   // LONG: menembus tapi displacement kurang (2002.49 < 2002.50)
   s = CSignalModule::CheckBreakout(BIAS_LONG, 2002.49, hi, lo, atr, disp);
   AssertTrue("displacement short of 0.25xATR", !s.valid && s.reject == RJ_DISPLACEMENT);

   // LONG: tepat di ambang displacement -> VALID (syarat 'minimal')
   s = CSignalModule::CheckBreakout(BIAS_LONG, 2002.50, hi, lo, atr, disp);
   AssertTrue("exact displacement valid", s.valid && s.dir == BIAS_LONG);

   // LONG: jauh di atas -> valid
   s = CSignalModule::CheckBreakout(BIAS_LONG, 2005.0, hi, lo, atr, disp);
   AssertTrue("clear breakout long", s.valid);

   // LONG dengan close di bawah channel: tetap NO_BREAKOUT (arah salah)
   s = CSignalModule::CheckBreakout(BIAS_LONG, 1940.0, hi, lo, atr, disp);
   AssertTrue("long bias, downside move -> no breakout", !s.valid && s.reject == RJ_NO_BREAKOUT);

   // SHORT cermin: close == lo -> no breakout; 1947.51 -> displacement; 1947.50 -> valid
   s = CSignalModule::CheckBreakout(BIAS_SHORT, 1950.0, hi, lo, atr, disp);
   AssertTrue("close==lo -> no breakout", !s.valid && s.reject == RJ_NO_BREAKOUT);
   s = CSignalModule::CheckBreakout(BIAS_SHORT, 1947.51, hi, lo, atr, disp);
   AssertTrue("short displacement short", !s.valid && s.reject == RJ_DISPLACEMENT);
   s = CSignalModule::CheckBreakout(BIAS_SHORT, 1947.50, hi, lo, atr, disp);
   AssertTrue("short exact displacement valid", s.valid && s.dir == BIAS_SHORT);

   PrintFormat("Test_SignalModule: %d PASS, %d FAIL %s",
               g_pass, g_fail, g_fail == 0 ? "— OK" : "— PERIKSA!");
  }
