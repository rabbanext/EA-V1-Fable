//+------------------------------------------------------------------+
//| RiskModule.mqh — sizing flat 0,5% + backstop gap                 |
//| XAU Trend Capture v1                                             |
//|                                                                  |
//| Seluruh logika = fungsi statis murni atas angka yang disuntik;   |
//| spesifikasi simbol (tick value/size, batas volume) diambil oleh  |
//| adapter di EA utama dan dioper sebagai SSymbolVol.               |
//|                                                                  |
//| PERINGATAN MODAL KECIL (docs/00): pada akun Standard dengan      |
//| ekuitas < ~$2.500, gap cap menghasilkan lot < minimum broker ->  |
//| fungsi ini mengembalikan 0 untuk SEMUA sinyal. Itu BUKAN bug —   |
//| itu backstop yang menolak risiko gap > 2% ekuitas. Solusi: akun  |
//| cent atau modal lebih besar, bukan melonggarkan cap.             |
//+------------------------------------------------------------------+
#ifndef XTC_RISKMODULE_MQH
#define XTC_RISKMODULE_MQH

#include "Types.mqh"

class CRiskModule
  {
private:
   double            m_riskPct;      // % ekuitas per trade (default 0,5)
   double            m_gapDollar;    // skenario gap harga, $ (konstanta 50)
   double            m_gapLossPct;   // kerugian gap maksimum, % ekuitas (konstanta 2)

public:
   void              Init(const double riskPct, const double gapDollar, const double gapLossPct)
     {
      m_riskPct    = riskPct;
      m_gapDollar  = gapDollar;
      m_gapLossPct = gapLossPct;
     }

   //--- Inti murni. stopDistance dalam satuan HARGA ($/oz untuk XAUUSD).
   //    Return 0 bila hasil akhir < lot minimum (caller log RJ_LOT_BELOW_MIN).
   static double     ComputeLots(const double equity, const double stopDistance,
                                 const double riskPct, const double gapDollar,
                                 const double gapLossPct, const SSymbolVol &v)
     {
      if(equity <= 0.0 || stopDistance <= 0.0) return 0.0;
      if(v.tickSize <= 0.0 || v.tickValue <= 0.0 || v.volStep <= 0.0) return 0.0;

      // $ P/L per 1.0 pergerakan harga per 1 lot.
      // XAUUSD standard: tickValue $1 / tickSize 0.01 = $100/lot. Pada akun cent
      // satuannya sen, konsisten dengan equity dalam sen — rasio tetap benar.
      double dollarPerLotPerUnit = v.tickValue / v.tickSize;

      // Sizing flat: risiko tetap riskPct% ekuitas pada jarak stop saat entry.
      double riskMoney   = (riskPct / 100.0) * equity;
      double lotsByRisk  = riskMoney / (stopDistance * dollarPerLotPerUnit);

      // Backstop gap: gap sebesar gapDollar tidak boleh merugikan > gapLossPct% ekuitas.
      // $100K: (2% x 100000)/(50 x 100) = 0,4 lot. Mengikat saat ATR rendah — disengaja.
      double lotsByGap   = ((gapLossPct / 100.0) * equity) / (gapDollar * dollarPerLotPerUnit);

      double lots = MathMin(lotsByRisk, lotsByGap);

      // Pembulatan SELALU ke bawah ke kelipatan volStep — tidak pernah membulatkan
      // risiko ke atas.
      lots = MathFloor(lots / v.volStep) * v.volStep;

      if(lots < v.volMin) return 0.0;
      return MathMin(lots, v.volMax);
     }

   //--- Wrapper instance dengan parameter ter-Init
   double            Lots(const double equity, const double stopDistance, const SSymbolVol &v) const
     {
      return ComputeLots(equity, stopDistance, m_riskPct, m_gapDollar, m_gapLossPct, v);
     }
  };

#endif // XTC_RISKMODULE_MQH
