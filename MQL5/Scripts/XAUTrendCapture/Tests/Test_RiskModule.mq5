//+------------------------------------------------------------------+
//| Test_RiskModule.mq5 — unit test sizing & gap cap                 |
//| Termasuk kasus modal kecil dari docs/00_catatan_modal_akun.md.   |
//+------------------------------------------------------------------+
#property script_show_inputs false
#property strict

#include <XAUTrendCapture/Types.mqh>
#include <XAUTrendCapture/RiskModule.mqh>

int g_pass = 0, g_fail = 0;

void AssertEq(const string name, const double a, const double b, const double eps = 1e-9)
  {
   if(MathAbs(a - b) <= eps) { g_pass++; }
   else { g_fail++; PrintFormat("FAIL: %s (%.6f != %.6f)", name, a, b); }
  }

void OnStart()
  {
   //--- spesifikasi XAUUSD akun Standard: tick $1/0.01 -> $100 per $1 per lot
   SSymbolVol std;
   std.tickValue = 1.0;  std.tickSize = 0.01;
   std.volMin = 0.01;    std.volMax = 100.0;   std.volStep = 0.01;

   // Kasus acuan blueprint: $100K, ATR $10 -> stop $20 -> 0,25 lot
   AssertEq("blueprint $100K ATR10 -> 0.25",
            CRiskModule::ComputeLots(100000, 20.0, 0.5, 50.0, 2.0, std), 0.25);

   // ATR rendah: $100K, ATR $5 -> stop $10 -> sizing 0,5 TAPI gap cap 0,4 mengikat
   AssertEq("gap cap binds at low ATR -> 0.4",
            CRiskModule::ComputeLots(100000, 10.0, 0.5, 50.0, 2.0, std), 0.40);

   // Ambang gap cap: cap mengikat saat ATR < $6.25 (stop < $12.5)
   AssertEq("at ATR 6.25 sizing == cap == 0.4",
            CRiskModule::ComputeLots(100000, 12.5, 0.5, 50.0, 2.0, std), 0.40);

   // Pembulatan SELALU ke bawah: $100K, stop $19 -> 500/1900 = 0.26315 -> 0.26
   AssertEq("floor to step", CRiskModule::ComputeLots(100000, 19.0, 0.5, 50.0, 2.0, std), 0.26);

   //=========== TEMUAN docs/00: $1.000 di akun Standard ===========
   // lotsByRisk = 5/(20x100) = 0.0025; lotsByGap = 20/5000 = 0.004 -> floor 0.00 < min
   // -> WAJIB 0 (RJ_LOT_BELOW_MIN). Spek as-written tidak bisa trade di sini.
   AssertEq("$1000 Standard -> 0 (below min lot)",
            CRiskModule::ComputeLots(1000, 20.0, 0.5, 50.0, 2.0, std), 0.0);

   // Bahkan ATR sangat rendah: stop $5 -> risk 0.01 lot pas, TAPI gap cap 0.004 -> 0
   AssertEq("$1000 Standard gap cap still forbids",
            CRiskModule::ComputeLots(1000, 5.0, 0.5, 50.0, 2.0, std), 0.0);

   // Modal minimum Opsi B: E >= 200 x stop. $4.000 @stop $20 -> 0.01 (gap cap 0.016)
   AssertEq("$4000 Standard ATR10 -> 0.01",
            CRiskModule::ComputeLots(4000, 20.0, 0.5, 50.0, 2.0, std), 0.01);

   //=========== Opsi A: Standard Cent — numerik identik $100K skala 1:100 ===========
   // Saldo dalam sen: $1.000 = 100.000c. 1 cent-lot = 1 oz -> $1 move = 100c.
   // tickValue 1c per tick per cent-lot, tickSize 0.01 -> 100c per 1.0 per cent-lot.
   SSymbolVol cent;
   cent.tickValue = 1.0;  cent.tickSize = 0.01;
   cent.volMin = 0.01;    cent.volMax = 200.0;  cent.volStep = 0.01;

   AssertEq("cent: $1000 ATR10 -> 0.25 cent-lot",
            CRiskModule::ComputeLots(100000, 20.0, 0.5, 50.0, 2.0, cent), 0.25);
   AssertEq("cent: gap cap -> 0.4 cent-lot",
            CRiskModule::ComputeLots(100000, 10.0, 0.5, 50.0, 2.0, cent), 0.40);
   // Tangga live 0,1% risiko: 100c / (20x100) = 0.05 cent-lot — masih >= min
   AssertEq("cent: live ladder 0.1% -> 0.05",
            CRiskModule::ComputeLots(100000, 20.0, 0.1, 50.0, 2.0, cent), 0.05);

   //--- input rusak -> 0, jangan crash
   AssertEq("zero stop -> 0",   CRiskModule::ComputeLots(100000, 0.0, 0.5, 50.0, 2.0, std), 0.0);
   AssertEq("zero equity -> 0", CRiskModule::ComputeLots(0, 20.0, 0.5, 50.0, 2.0, std), 0.0);

   PrintFormat("Test_RiskModule: %d PASS, %d FAIL %s",
               g_pass, g_fail, g_fail == 0 ? "— OK" : "— PERIKSA!");
  }
