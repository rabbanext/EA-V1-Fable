//+------------------------------------------------------------------+
//| Util_TickInfo.mq5 — verifikasi tick value & sizing di akun aktif |
//| Jalankan di chart XAUUSDm/XAUUSDc sebelum backtest.             |
//+------------------------------------------------------------------+
#property script_show_inputs false
#property strict

#include <XAUTrendCapture/Types.mqh>
#include <XAUTrendCapture/RiskModule.mqh>

input double InpEquity   = 10000.0;
input double InpATR      = 15.0;    // ATR H1 tipikal saat ini ($)
input double InpRiskPct  = 0.5;
input double InpGapCap   = 50.0;
input double InpGapPct   = 2.0;

void OnStart()
  {
   string sym = _Symbol;
   double cs  = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   double ts  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tv  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double vm  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vs  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double sll = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);

   PrintFormat("=== Tick Info: %s ===", sym);
   PrintFormat("Contract size : %.0f oz/lot", cs);
   PrintFormat("Tick size     : %.4f", ts);
   PrintFormat("Tick value    : %.4f USD/tick/lot", tv);
   PrintFormat("$/lot/$1 move : %.2f  (= tv/ts)", tv / ts);
   PrintFormat("Vol min/step  : %.2f / %.2f", vm, vs);
   PrintFormat("Stops level   : %.0f pts", sll);

   // ---- Sizing pada equity & ATR saat ini ----
   SSymbolVol v;
   v.tickValue = tv; v.tickSize = ts;
   v.volMin = vm; v.volMax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX); v.volStep = vs;

   double stop = 2.0 * InpATR;
   double lots = CRiskModule::ComputeLots(InpEquity, stop, InpRiskPct, InpGapCap, InpGapPct, v);
   double riskActual = lots * stop * (tv / ts);
   double riskIntended = (InpRiskPct / 100.0) * InpEquity;

   PrintFormat("--- Sizing @ eq=%.0f ATR=%.1f ---", InpEquity, InpATR);
   PrintFormat("Stop         : %.1f (2xATR)", stop);
   PrintFormat("Intended risk: %.2f (%.1f%%)", riskIntended, InpRiskPct);
   PrintFormat("Lots result  : %.2f", lots);
   PrintFormat("Actual risk  : %.2f (%.1f%% err dari target)",
               riskActual, (lots > 0 ? (riskActual / riskIntended - 1.0) * 100.0 : -100.0));
   if(lots <= 0)
      Print("WARNING: lots=0 -> RJ_LOT_BELOW_MIN akan terpicu. Lihat docs/00.");

   // ---- Swap estimate ----
   double swapLongPts = SymbolInfoDouble(sym, SYMBOL_SWAP_LONG);
   double swapShortPts = SymbolInfoDouble(sym, SYMBOL_SWAP_SHORT);
   double swapPerLot = swapLongPts * tv / ts;   // $/lot/hari untuk long
   double swapPos    = lots * MathAbs(swapPerLot);
   double swapR1R    = (riskActual > 0) ? swapPos / riskActual : 0.0;

   PrintFormat("--- Swap (long) ---");
   PrintFormat("Swap pts/lot/hari : %.1f pts", swapLongPts);
   PrintFormat("Swap $/lot/hari   : %.4f  (short: %.4f)", swapPerLot, swapShortPts * tv / ts);
   PrintFormat("Swap posisi %.2f lot: %.4f $/hari", lots, swapPos);
   PrintFormat("Swap per 1R per hari : %.4fR", swapR1R);
   PrintFormat("Swap per 10-hari     : %.4fR  (time-stop ~2.5 hari: %.4fR)",
               swapR1R * 10.0, swapR1R * 2.5);
  }
