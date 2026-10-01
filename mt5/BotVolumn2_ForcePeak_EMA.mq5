//+------------------------------------------------------------------+
//|                                  BotVolumn2_ForcePeak_EMA.mq5    |
//|            Bot Volumn 2 — Force Peak + EMA 9/21 (MetaTrader 5)   |
//|                                                                  |
//|  © 2026 Hồ Ngọc Khánh (LiinIT). All rights reserved.             |
//|  https://github.com/LiinIT/Bot-EA-Trading-XAUUSD-Volumn           |
//|  Donate coffee: 1907.5049.8560.17 (Techcombank)                   |
//|                 68814062001 (Techcombank)                         |
//|                                                                  |
//|  Logic: Volume Explosion → Force Peak → EMA 9/21 trend filter    |
//|         → vào lệnh / đảo chiều trên nến ĐÃ ĐÓNG.                  |
//+------------------------------------------------------------------+
#property copyright "© 2026 Hồ Ngọc Khánh (LiinIT)"
#property link      "https://github.com/LiinIT/Bot-EA-Trading-XAUUSD-Volumn"
#property version   "2.10"
#property description "Bot Volumn 2 - Force Peak Reversal EA with EMA 9/21 short-term trend filter"
#property description "Donate coffee: 1907.5049.8560.17 / 68814062001 (Techcombank)"

#include <Trade/Trade.mqh>

//==================================================================
// INPUTS
//==================================================================

input group "=== Trading ==="
input double InpLotSize         = 0.01;     // Lot Size
input ulong  InpMagicNumber     = 9212026;  // Magic Number
input int    InpDeviationPoints = 20;       // Max Slippage (points)
input bool   InpAllowBuy        = true;     // Allow Buy
input bool   InpAllowSell       = true;     // Allow Sell

input group "=== Force ==="
input int    InpForceLength     = 20;       // Force MA Length
input int    InpVolumeLength    = 20;       // Volume MA Length
input double InpVolumeExplosion = 1.5;      // Volume Explosion x
input double InpForceExplosion  = 1.5;      // Force Explosion x

input group "=== Short Trend EMA ==="
input int    InpFastEMA         = 9;        // Fast EMA
input int    InpSlowEMA         = 21;       // Slow EMA
input int    InpSlopeBars       = 1;        // EMA Slope Bars

input group "=== Risk Management ==="
input bool   InpUseSL            = false;   // Use Stop Loss
input double InpStopLossPoints   = 0.0;     // Stop Loss (points)
input bool   InpUseTP            = false;   // Use Take Profit
input double InpTakeProfitPoints = 0.0;     // Take Profit (points)

input group "=== Filter ==="
input double InpMaxSpreadPoints = 0.0;      // Max Spread (points, 0 = tắt)

input group "=== Debug ==="
input bool   InpDebug           = true;     // Print debug log

//==================================================================
// TYPES / GLOBALS
//==================================================================

enum PositionDirection
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = -1
};

struct PeakState
{
   bool   tracking;
   double peak;
};

CTrade    g_trade;
int       g_fastEMAHandle = INVALID_HANDLE;
int       g_slowEMAHandle = INVALID_HANDLE;
datetime  g_lastBarTime   = 0;
PeakState g_buyPeak;
PeakState g_sellPeak;

//==================================================================
// LIFECYCLE
//==================================================================

int OnInit()
{
   if(InpLotSize <= 0 || InpForceLength < 1 || InpVolumeLength < 1 ||
      InpFastEMA < 1 || InpSlowEMA < 1 || InpSlopeBars < 1)
   {
      Print("[BotVolumn2] Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_fastEMAHandle = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_slowEMAHandle = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_fastEMAHandle == INVALID_HANDLE || g_slowEMAHandle == INVALID_HANDLE)
   {
      Print("[BotVolumn2] ERROR: Cannot create EMA handles.");
      return INIT_FAILED;
   }

   ResetPeak(g_buyPeak);
   ResetPeak(g_sellPeak);
   g_lastBarTime = iTime(_Symbol, _Period, 0);

   DebugPrint(StringFormat("EA initialized. EMA %d/%d Lot=%.2f", InpFastEMA, InpSlowEMA, InpLotSize));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastEMAHandle != INVALID_HANDLE) IndicatorRelease(g_fastEMAHandle);
   if(g_slowEMAHandle != INVALID_HANDLE) IndicatorRelease(g_slowEMAHandle);
   DebugPrint("EA stopped.");
}

void OnTick()
{
   if(!IsNewBar())
      return;

   ProcessClosedBar();
}

//==================================================================
// CORE: xử lý nến vừa đóng (shift 1)
//==================================================================

void ProcessClosedBar()
{
   const int shift = 1;
   int requiredBars = MathMax(InpForceLength, InpVolumeLength) + shift + 2;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 0, requiredBars, rates) < requiredBars)
   {
      DebugPrint("Not enough bars.");
      return;
   }

   double buyForce  = BuyForce(rates[shift]);
   double sellForce = SellForce(rates[shift]);
   double volume    = (double)rates[shift].tick_volume;

   bool isVolumeExplosion = volume > VolumeMA(rates, shift) * InpVolumeExplosion;
   bool isBuyExplosion    = isVolumeExplosion && buyForce  > ForceMA(rates, shift, true)  * InpForceExplosion;
   bool isSellExplosion   = isVolumeExplosion && sellForce > ForceMA(rates, shift, false) * InpForceExplosion;

   bool isBuyPeak  = UpdatePeak(g_buyPeak,  buyForce,  isBuyExplosion,  "BUY");
   bool isSellPeak = UpdatePeak(g_sellPeak, sellForce, isSellExplosion, "SELL");

   bool isBullTrend = false;
   bool isBearTrend = false;
   if(!ReadTrend(rates[shift].close, shift, isBullTrend, isBearTrend))
      return;

   int direction = CurrentDirection();

   if(isBuyPeak && isBullTrend && direction != DIR_BUY)
   {
      DebugPrint(direction == DIR_SELL ? "SELL -> BUY reversal confirmed." : "BUY signal: Force Peak + EMA bullish.");
      Reverse(DIR_BUY, direction);
      return;
   }

   if(isSellPeak && isBearTrend && direction != DIR_SELL)
   {
      DebugPrint(direction == DIR_BUY ? "BUY -> SELL reversal confirmed." : "SELL signal: Force Peak + EMA bearish.");
      Reverse(DIR_SELL, direction);
   }
}

// Explosion mở theo dõi → Force còn tăng thì nâng đỉnh → nến đầu tiên không vượt đỉnh = Peak xác nhận
bool UpdatePeak(PeakState &state, const double force, const bool isExplosion, const string side)
{
   if(state.tracking)
   {
      if(force > state.peak)
      {
         state.peak = force;
         DebugPrint(StringFormat("%s force new peak=%.2f", side, force));
         return false;
      }

      DebugPrint(StringFormat("%s FORCE PEAK CONFIRMED. Peak=%.2f Current=%.2f", side, state.peak, force));
      ResetPeak(state);
      return true;
   }

   if(isExplosion)
   {
      state.tracking = true;
      state.peak     = force;
      DebugPrint(StringFormat("Start %s force tracking. Force=%.2f", side, force));
   }
   return false;
}

void ResetPeak(PeakState &state)
{
   state.tracking = false;
   state.peak     = 0.0;
}

//==================================================================
// FORCE / VOLUME
//==================================================================

double BuyForce(const MqlRates &bar)
{
   double range = MathMax(bar.high - bar.low, _Point);
   return (double)bar.tick_volume * (bar.close - bar.low) / range;
}

double SellForce(const MqlRates &bar)
{
   double range = MathMax(bar.high - bar.low, _Point);
   return (double)bar.tick_volume * (bar.high - bar.close) / range;
}

double ForceMA(const MqlRates &rates[], const int shift, const bool isBuy)
{
   double sum = 0.0;
   for(int i = shift; i < shift + InpForceLength; i++)
      sum += isBuy ? BuyForce(rates[i]) : SellForce(rates[i]);
   return sum / InpForceLength;
}

double VolumeMA(const MqlRates &rates[], const int shift)
{
   double sum = 0.0;
   for(int i = shift; i < shift + InpVolumeLength; i++)
      sum += (double)rates[i].tick_volume;
   return sum / InpVolumeLength;
}

//==================================================================
// TREND EMA 9/21
//==================================================================

bool ReadTrend(const double closePrice, const int shift, bool &isBullTrend, bool &isBearTrend)
{
   double fastNow = 0.0, fastOld = 0.0, slowNow = 0.0;
   if(!ReadBuffer(g_fastEMAHandle, shift, fastNow) ||
      !ReadBuffer(g_fastEMAHandle, shift + InpSlopeBars, fastOld) ||
      !ReadBuffer(g_slowEMAHandle, shift, slowNow))
   {
      DebugPrint("Cannot read EMA buffers.");
      return false;
   }

   isBullTrend = fastNow > slowNow && fastNow > fastOld && closePrice > fastNow;
   isBearTrend = fastNow < slowNow && fastNow < fastOld && closePrice < fastNow;

   DebugPrint(StringFormat("Close=%s EMA%d=%s EMA%d=%s Bull=%s Bear=%s",
              DoubleToString(closePrice, _Digits), InpFastEMA, DoubleToString(fastNow, _Digits),
              InpSlowEMA, DoubleToString(slowNow, _Digits),
              isBullTrend ? "TRUE" : "FALSE", isBearTrend ? "TRUE" : "FALSE"));
   return true;
}

bool ReadBuffer(const int handle, const int shift, double &value)
{
   double buffer[1];
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;
   value = buffer[0];
   return true;
}

//==================================================================
// POSITION / TRADE
//==================================================================

bool IsOwnPosition(const ulong ticket)
{
   return PositionSelectByTicket(ticket) &&
          PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber;
}

int CurrentDirection()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOwnPosition(ticket))
         continue;
      return PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? DIR_BUY : DIR_SELL;
   }
   return DIR_NONE;
}

bool CloseOwnPositions()
{
   bool isAllClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOwnPosition(ticket))
         continue;

      if(!g_trade.PositionClose(ticket) || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
      {
         isAllClosed = false;
         DebugPrint(StringFormat("Close failed ticket=%I64u retcode=%u %s", ticket,
                    g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
   }
   return isAllClosed;
}

// Đóng lệnh ngược chiều (nếu có) rồi mở lệnh mới theo hướng tín hiệu
void Reverse(const int targetDirection, const int currentDirection)
{
   if(currentDirection != DIR_NONE && !CloseOwnPositions())
      return;

   bool isAllowed = targetDirection == DIR_BUY ? InpAllowBuy : InpAllowSell;
   if(!isAllowed)
   {
      DebugPrint("Signal direction disabled, staying flat.");
      return;
   }

   if(!IsSpreadOK())
   {
      DebugPrint("Entry blocked: spread too high.");
      return;
   }

   OpenPosition(targetDirection);
}

void OpenPosition(const int direction)
{
   bool   isBuy = direction == DIR_BUY;
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      return;

   double sl = 0.0;
   double tp = 0.0;
   if(InpUseSL && InpStopLossPoints > 0.0)
      sl = NormalizeDouble(isBuy ? price - InpStopLossPoints * _Point : price + InpStopLossPoints * _Point, _Digits);
   if(InpUseTP && InpTakeProfitPoints > 0.0)
      tp = NormalizeDouble(isBuy ? price + InpTakeProfitPoints * _Point : price - InpTakeProfitPoints * _Point, _Digits);

   double lot = NormalizeLot(InpLotSize);
   bool isSent = isBuy ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, "BotVolumn2 BUY")
                       : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, "BotVolumn2 SELL");

   if(isSent && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      DebugPrint(StringFormat("%s opened. Lot=%.2f Price=%s", isBuy ? "BUY" : "SELL", lot,
                 DoubleToString(g_trade.ResultPrice(), _Digits)));
   else
      DebugPrint(StringFormat("%s failed. Retcode=%u %s", isBuy ? "BUY" : "SELL",
                 g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
}

//==================================================================
// HELPERS
//==================================================================

bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == 0 || currentBarTime == g_lastBarTime)
      return false;

   g_lastBarTime = currentBarTime;
   return true;
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0.0)
      return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;
   return (ask - bid) / _Point <= InpMaxSpreadPoints;
}

double NormalizeLot(const double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0)
      stepLot = minLot;

   double normalized = MathFloor(MathMin(MathMax(lot, minLot), maxLot) / stepLot) * stepLot;
   int    digits     = (int)MathMax(0, MathCeil(-MathLog10(stepLot)));
   return NormalizeDouble(normalized, digits);
}

void DebugPrint(const string message)
{
   if(InpDebug)
      Print("[BotVolumn2] ", message);
}
//+------------------------------------------------------------------+
