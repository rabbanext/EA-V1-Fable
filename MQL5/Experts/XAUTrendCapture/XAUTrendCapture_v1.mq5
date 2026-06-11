//+------------------------------------------------------------------+
//| XAUTrendCapture_v1.mq5                                           |
//| XAU Trend Capture v1 — trend following XAUUSD                    |
//|                                                                  |
//| Entry : breakout Donchian 24 H1 (close + displacement 0,25xATR)  |
//|         searah filter H4 (close vs EMA200 + slope EMA50, 3-state)|
//| Exit  : hard SL 2xATR di server, chandelier 3xATR, time-stop 48  |
//| Risk  : flat 0,5% ekuitas, gap-cap, 1 posisi, protection stack   |
//|                                                                  |
//| File ini TIPIS: hanya wiring + event handler. Seluruh logika di  |
//| Include/XAUTrendCapture/*.mqh (unit-testable). Pseudocode acuan: |
//| docs/01_arsitektur_pseudocode.md — deviasi dicatat di header.    |
//|                                                                  |
//| RUANG EKSPERIMEN TERKUNCI (blueprint): InpUseSlopeFilter {0,1} x |
//| InpTimeStopMode {NONE,48,96} = 6 kombinasi. Tidak ada saklar lain.|
//+------------------------------------------------------------------+
#property copyright "XAU Trend Capture v1"
#property version   "1.00"
#property strict

#include <XAUTrendCapture/Types.mqh>
#include <XAUTrendCapture/TimeUtils.mqh>
#include <XAUTrendCapture/SignalModule.mqh>
#include <XAUTrendCapture/RiskModule.mqh>
#include <XAUTrendCapture/ExecutionModule.mqh>
#include <XAUTrendCapture/ProtectionModule.mqh>
#include <XAUTrendCapture/NewsCalendar.mqh>
#include <XAUTrendCapture/DecisionLogger.mqh>
#include <XAUTrendCapture/StateStore.mqh>

//=================== INPUT — ANGGARAN PARAMETER (±12, blueprint) ===================
input group "Strategi (anggaran parameter)"
input int           InpDonchianPeriod   = 24;     // 1. Periode Donchian (H1)
input double        InpDisplacementATR  = 0.25;   // 2. Displacement minimal, x ATR
input int           InpATRPeriod        = 14;     // 3. Periode ATR (H1)
input double        InpSLMultATR        = 2.0;    // 4. SL awal, x ATR
input double        InpTrailMultATR     = 3.0;    // 5. Chandelier, x ATR
input ETimeStopMode InpTimeStopMode     = TS_48;  // 6. Time-stop [SAKLAR EKSPERIMEN]
input bool          InpUseSlopeFilter   = true;   // 7. Syarat slope EMA50 H4 [SAKLAR EKSPERIMEN]
input int           InpSlopeLookback    = 5;      // 8. Lookback slope (EMA50[1]-EMA50[1+N])
input double        InpRiskPct          = 0.5;    // 9. Risiko per trade, % ekuitas
input int           InpSessionStartGMT  = 7;      // 10a. Jam GMT mulai entry
input int           InpSessionEndGMT    = 20;     // 10b. Jam GMT akhir entry (eksklusif)
input double        InpSpreadCapMult    = 2.0;    // 11. Spread cap, x median 24 bar
input int           InpNewsWindowMin    = 15;     // 12. Jendela news, +/- menit

input group "Operasional (BUKAN parameter strategi — tidak ikut optimasi)"
input long          InpMagicNumber      = 240101; // Magic number
input int           InpServerGMTOffWinter = 0;    // Offset server-GMT musim dingin (Exness=0; VERIFIKASI!)
input int           InpServerGMTOffSummer = 0;    // Offset server-GMT saat DST AS (Exness=0)
input string        InpNewsCSVName      = "XTC_news_calendar.csv"; // CSV kalender (GMT)
input bool          InpAllowNoNews      = false;  // true = boleh jalan tanpa kalender (HANYA debug)
input int           InpDeviationPoints  = 100;    // Toleransi deviasi order (poin)
// Konstanta backstop gap — dipajang agar terlihat di laporan tester, jangan diutak-atik
input double        InpGapCapDollar     = 50.0;   // Skenario gap, $
input double        InpGapCapLossPct    = 2.0;    // Kerugian gap maksimum, % ekuitas

//=================== KONSTANTA DESAIN (bukan input) ===================
// Limit ekuitas adalah bagian hipotesis yang diuji — bukan baju yang dilonggarkan.
#define XTC_DAILY_LOSS_PCT   2.0
#define XTC_WEEKLY_LOSS_PCT  5.0
#define XTC_KILL_PCT        15.0

//=================== OBJEK GLOBAL ===================
CGmtClock         g_clock;
CSignalModule     g_signal;
CRiskModule       g_risk;
CExecutionModule  g_exec;
CProtectionModule g_protect;
CDecisionLogger   g_log;
CStateStore       g_store;
SPersistState     g_st;             // status persisten (guard + trade berjalan)
datetime          g_lastProcessedH1 = 0;   // bar H1 terakhir yang SUKSES diproses
datetime          g_lastSignalBar   = 0;   // anti-duplicate: 1 percobaan entry per bar sinyal
bool              g_killAlerted     = false;

//=================== HELPER ===================

//--- Spread saat ini dalam satuan harga ($/oz)
double CurrentSpreadPrice()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return ask - bid;
  }

//--- Spesifikasi volume simbol untuk RiskModule
void FillSymbolVol(SSymbolVol &v)
  {
   v.tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   v.tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   v.volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   v.volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   v.volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  }

//--- Salin status guard dari ProtectionModule ke struct persisten lalu simpan
void PersistGuards()
  {
   g_st.hwm        = g_protect.Hwm();
   g_st.dayAnchor  = g_protect.DayAnchor();
   g_st.weekAnchor = g_protect.WeekAnchor();
   g_st.dayId      = g_protect.DayIdCur();
   g_st.weekId     = g_protect.WeekIdCur();
   g_st.dailyLock  = g_protect.DailyLock();
   g_st.weeklyLock = g_protect.WeeklyLock();
   g_st.killLock   = g_protect.KillLock();
   g_store.Save(g_st);
  }

//--- Hapus state trade setelah posisi tertutup
void ClearTradeState()
  {
   g_st.positionId = 0;
   g_st.entryPrice = 0.0;
   g_st.stopDistance = 0.0;
   g_st.riskMoney = 0.0;
   g_st.entryBarTime = 0;
   g_st.reached1R = false;
   g_st.slWasTrailed = false;
   g_st.direction = 0;
   g_store.Save(g_st);
  }

//=================== EVENT HANDLER ===================

int OnInit()
  {
   //--- validasi input dasar
   if(InpRiskPct <= 0.0 || InpRiskPct > 1.0)
     {
      // 0,5% default; tangga live 0,1/0,25/0,5; >1% tidak pernah bagian desain.
      Print("XTC: InpRiskPct di luar rentang (0, 1.0] — ditolak. Lihat blueprint.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpDonchianPeriod < 2 || InpATRPeriod < 2 || InpSlopeLookback < 1)
      return INIT_PARAMETERS_INCORRECT;
   if(StringFind(_Symbol, "XAU") < 0)
      Print("XTC PERINGATAN: simbol '", _Symbol, "' bukan XAU* — sistem didesain untuk XAUUSD.");

   g_clock.Init(InpServerGMTOffWinter, InpServerGMTOffSummer);
   g_store.Init(_Symbol, InpMagicNumber);
   g_risk.Init(InpRiskPct, InpGapCapDollar, InpGapCapLossPct);
   g_exec.Init(_Symbol, InpMagicNumber, InpSLMultATR, InpTrailMultATR, InpDeviationPoints);
   g_protect.Init(InpSessionStartGMT, InpSessionEndGMT, InpSpreadCapMult, InpNewsWindowMin,
                  XTC_DAILY_LOSS_PCT, XTC_WEEKLY_LOSS_PCT, XTC_KILL_PCT);
   g_log.Init(_Symbol, InpUseSlopeFilter, (int)InpTimeStopMode);

   if(!g_signal.Init(_Symbol, InpUseSlopeFilter, InpSlopeLookback,
                     InpDonchianPeriod, InpDisplacementATR, InpATRPeriod))
     {
      Print("XTC: gagal membuat handle indikator.");
      return INIT_FAILED;
     }

   //--- kalender news: WAJIB ada. Backtest tanpa news filter = backtest sistem lain.
   if(!g_protect.news.Load(InpNewsCSVName))
     {
      if(!InpAllowNoNews)
        {
         Print("XTC: kalender '", InpNewsCSVName, "' tidak ditemukan/kosong. ",
               "Letakkan di MQL5/Files atau folder Common. ",
               "(InpAllowNoNews=true hanya untuk debug — backtest validasi TIDAK sah tanpa kalender.)");
         return INIT_FAILED;
        }
      Print("XTC PERINGATAN KERAS: jalan TANPA news filter (InpAllowNoNews=true). ",
            "Hasil tidak sah untuk validasi.");
     }
   else
      Print("XTC: kalender news dimuat, ", g_protect.news.Count(), " event.");

   //--- pulihkan status persisten (live); tester selalu mulai bersih
   if(g_store.Load(g_st))
     {
      g_protect.RestoreState(g_st.hwm, g_st.dayAnchor, g_st.weekAnchor,
                             g_st.dayId, g_st.weekId,
                             g_st.dailyLock, g_st.weeklyLock, g_st.killLock);
      if(g_st.killLock)
         Print("XTC: KILL SWITCH AKTIF dari sesi sebelumnya. EA inert. ",
               "Reset hanya manual (hapus state file) setelah post-mortem.");
     }

   //--- adopsi posisi yatim (restart saat posisi terbuka, state file hilang/beda)
   ulong tk = g_exec.FindPosition();
   if(tk != 0 && g_st.positionId != (long)PositionGetInteger(POSITION_IDENTIFIER))
     {
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double lots  = PositionGetDouble(POSITION_VOLUME);
      SSymbolVol v; FillSymbolVol(v);
      g_st.positionId   = (long)PositionGetInteger(POSITION_IDENTIFIER);
      g_st.entryPrice   = entry;
      g_st.stopDistance = MathAbs(entry - sl);   // rekonstruksi dari SL terpasang
      g_st.riskMoney    = g_st.stopDistance * lots * (v.tickValue / v.tickSize);
      g_st.entryBarTime = iTime(_Symbol, PERIOD_H1,
                                iBarShift(_Symbol, PERIOD_H1,
                                          (datetime)PositionGetInteger(POSITION_TIME)));
      g_st.reached1R    = false;   // konservatif: time-stop tetap berlaku
      g_st.slWasTrailed = false;
      g_st.direction    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_store.Save(g_st);
      g_log.LogEvent(TimeCurrent(), "ANOMALY_ADOPTED_POSITION",
                     StringFormat("pid=%I64d stopDist=%.2f", g_st.positionId, g_st.stopDistance));
     }

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_store.Save(g_st);
   g_log.Deinit();
   g_signal.Deinit();
  }

void OnTick()
  {
   datetime srv = TimeCurrent();
   datetime gmt = g_clock.ToGMT(srv);
   double   eq  = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- guard ekuitas SETIAP tick (basis: equity termasuk floating, anchor awal periode)
   SGuardEvents ev = g_protect.UpdateEquityGuards(eq, gmt);

   if(ev.killTriggeredNow)
     {
      g_exec.CloseAll(EX_KILL);
      PersistGuards();
      g_log.LogEvent(srv, "KILL_SWITCH",
                     StringFormat("equity=%.2f hwm=%.2f", eq, g_protect.Hwm()));
      if(!g_killAlerted) { Alert("XTC: KILL SWITCH -15% HWM. EA berhenti. Post-mortem!"); g_killAlerted = true; }
      return;
     }
   if(g_protect.KillLock())
     {
      if(!g_killAlerted) { Alert("XTC: kill switch aktif — EA inert."); g_killAlerted = true; }
      return;   // inert permanen; data & posisi (sudah flat) dibiarkan untuk post-mortem
     }
   if(ev.weeklyTriggeredNow)
     {
      g_exec.CloseAll(EX_WEEKLY_FLAT);
      PersistGuards();
      g_log.LogEvent(srv, "WEEKLY_LIMIT",
                     StringFormat("equity=%.2f anchor=%.2f", eq, g_protect.WeekAnchor()));
     }
   if(ev.dailyTriggeredNow)
     {
      PersistGuards();
      g_log.LogEvent(srv, "DAILY_LIMIT",
                     StringFormat("equity=%.2f anchor=%.2f", eq, g_protect.DayAnchor()));
     }
   if(ev.newDay || ev.newWeek)
      PersistGuards();

   //--- sisanya hanya pada bar H1 baru
   datetime h1now = iTime(_Symbol, PERIOD_H1, 0);
   if(h1now == 0 || h1now == g_lastProcessedH1) return;

   //--- refresh bias H4 (internal: hanya hitung ulang saat bar H4 baru).
   //    Gagal (data belum siap) -> JANGAN tandai bar diproses, coba lagi tick berikut.
   if(!g_signal.RefreshH4Bias()) return;

   //--- sampel spread per bar (konstanta desain: 1 sampel saat bar baru)
   double spr = CurrentSpreadPrice();
   g_protect.SampleSpread(spr);
   if(!MQLInfoInteger(MQL_TESTER))
      g_log.LogSpreadSample(srv, spr);   // spesifikasi: catat spread per bar di live

   //--- snapshot pasar: satu-satunya titik baca data untuk keputusan bar ini
   SMarketSnapshot s;
   if(!g_signal.FillSnapshot(s)) return;   // retry tick berikutnya
   s.spreadNow    = spr;
   s.spreadMedian = g_protect.SpreadMedian();
   s.spreadReady  = g_protect.SpreadReady();

   g_lastProcessedH1 = h1now;   // bar resmi diproses mulai titik ini

   //--- evaluasi sinyal SELALU (juga saat posisi terbuka: metrik slot terisi
   //    untuk uji 3-lengan time-stop — sinyal valid yang terblokir HARUS terhitung)
   SEntrySignal sig = g_signal.CheckEntry(s);

   if(g_exec.HasPosition())
     {
      if(sig.valid)
         g_log.LogReject(RJ_POSITION_OPEN, s);   // metrik kunci eksperimen time-stop

      //--- urutan manajemen: 1R -> time-stop -> trailing (lihat docs/01 §8)
      g_exec.UpdateReached1R(g_st);
      if(g_exec.CheckTimeStop(g_st, (int)InpTimeStopMode))
        {
         g_log.LogEvent(srv, "EXIT_TIMESTOP_SENT",
                        StringFormat("bars=%d", g_exec.BarsClosedSinceEntry(g_st)));
         g_store.Save(g_st);
         return;
        }
      double newSL = 0.0;
      if(g_exec.UpdateTrailing(g_st, s.atrH1, newSL))
         g_log.LogEvent(srv, "SL_TRAILED", StringFormat("sl=%.2f atr=%.2f", newSL, s.atrH1));
      g_store.Save(g_st);
      return;
     }

   //--- tidak ada posisi: jalur entry
   if(!sig.valid)
     {
      g_log.LogReject(sig.reject, s);
      return;
     }

   ERejectReason rj;
   if(!g_protect.CanEnter(s, gmt, rj))
     {
      g_log.LogReject(rj, s);
      return;
     }
   if(s.barTimeH1 == g_lastSignalBar)
     {
      g_log.LogReject(RJ_DUPLICATE_BAR, s);
      return;
     }

   SSymbolVol v;
   FillSymbolVol(v);
   double stopDist = InpSLMultATR * s.atrH1;
   double lots = g_risk.Lots(eq, stopDist, v);
   if(lots <= 0.0)
     {
      // Di modal kecil akun Standard ini akan SERING terpicu — lihat docs/00.
      g_log.LogReject(RJ_LOT_BELOW_MIN, s,
                      StringFormat("eq=%.2f stop=%.2f", eq, stopDist));
      return;
     }

   //--- 1 percobaan entry per bar sinyal, sukses ataupun gagal
   g_lastSignalBar = s.barTimeH1;

   double fill = 0.0, req = 0.0;
   if(!g_exec.Open(sig.dir, lots, s.atrH1, g_st, fill, req))
     {
      g_log.LogEvent(srv, "ANOMALY_OPEN_FAILED",
                     StringFormat("dir=%d lots=%.4f err=%d", (int)sig.dir, lots, GetLastError()));
      return;
     }

   double riskActual = g_st.stopDistance * lots * (v.tickValue / v.tickSize);
   g_st.riskMoney = riskActual;
   g_log.LogEntry(s, lots, riskActual, fill);
   g_log.RegisterEntry(g_st.positionId, riskActual, g_st.stopDistance, g_st.entryBarTime);
   g_store.Save(g_st);

   //--- spesifikasi: fill meleset > $1 dari harga diminta = anomali
   if(MathAbs(fill - req) > XTC_SLIPPAGE_ANOMALY)
      g_log.LogEvent(srv, "ANOMALY_SLIPPAGE",
                     StringFormat("req=%.2f fill=%.2f", req, fill));
  }

//--- Deteksi penutupan posisi (SL kena, close kita sendiri, atau manual/stop-out)
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
     {
      // deal masuk (DEAL_ENTRY_IN) membawa magic kita; deal keluar oleh server
      // (SL) juga. Deal tanpa magic kita yang menutup posisi kita = manual.
      if((long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID) != g_st.positionId) return;
     }
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   long pid = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(pid != g_st.positionId) return;

   //--- tentukan alasan exit
   EExitReason reason = g_exec.PendingCloseReason();
   if(reason == EX_NONE)
     {
      long dealReason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      if(dealReason == DEAL_REASON_SL)
         reason = g_st.slWasTrailed ? EX_TRAIL : EX_SL;   // bedakan SL awal vs trailing
      else
         reason = EX_MANUAL_OTHER;   // manual/stop-out — anomali, harus diinvestigasi
     }
   g_exec.ClearPendingClose();

   g_log.RegisterExitReason(pid, reason);
   g_log.LogEvent((datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME),
                  "EXIT_" + ExitReasonToString(reason),
                  StringFormat("pid=%I64d price=%.2f", pid,
                               HistoryDealGetDouble(trans.deal, DEAL_PRICE)));
   if(reason == EX_MANUAL_OTHER)
      g_log.LogEvent(TimeCurrent(), "ANOMALY_EXTERNAL_CLOSE", StringFormat("pid=%I64d", pid));

   ClearTradeState();
  }

//--- Nilai pass tester = total net R (metrik primer protokol validasi).
//    Juga menulis XTC_trades_*.csv + XTC_counters_*.csv (kontrak data Python).
double OnTester()
  {
   return g_log.ExportTesterReport(_Symbol, InpMagicNumber);
  }
