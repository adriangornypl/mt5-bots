//+------------------------------------------------------------------+
//|                                              MACD_RSI_Cross.mq5  |
//|  Prio 1 RSI: BUY while closed RSI < OS (not only the cross bar). |
//|  One successful open per bar. If higher prio does not open,      |
//|  lower prio may still fire (failed P1 no longer swallows EMA).   |
//|  RSI 40/60 confirm applies ONLY to MACD, never to EMA.           |
//|  NOTE: "bars" = candles on InpTimeframe (e.g. 30 on M15 = 7.5h). |
//|  MaxBarsHold: HARD close after N signal-TF candles from open.    |
//|  Counted from POSITION_TIME (survives reattach / recompile).     |
//|  SL/TP: points by default (recommended). Optional % of PRICE.    |
//|  Spread is added to SL/TP so Bid-chart distances match inputs.   |
//|  After every open, POSITION_SL/TP are verified (+ PositionModify).|
//|  ADX filter (optional): gates ALL priorities — trend strength +  |
//|  optional +DI/-DI direction match before any BUY/SELL open.      |
//|  Session hours: new entries only; SL/TP + MaxBarsHold still run. |
//|  OneTradeOnly: true = 1 position. false = add SAME direction.    |
//|  Opposite signal always flattens ALL our positions, then may open.|
//|  TRIPLE SWAP (v1.90, FX e.g. EURUSD, default ON): close 1h before|
//|  the 3-day swap rollover (usually Wed 23:00 server). Reopen next |
//|  day if MaxBarsHold still has remaining bars.                    |
//+------------------------------------------------------------------+
#property copyright "My robots"
#property version   "1.90"
#property strict

#include <Trade\Trade.mqh>

#define TRIPLE_SWAP_LEAD_SEC 3600
#define SWAP_PARK_STALE_SEC  129600
#define SWAP_PARK_CAP        20

enum ENUM_SESSION_CLOCK
  {
   SESSION_CLOCK_SERVER = 0, // Broker server time
   SESSION_CLOCK_GMT    = 1, // GMT / UTC
   SESSION_CLOCK_LOCAL  = 2  // PC local time
  };

//==================== PRIORITY SWITCHES =============================
input group "=== Priority switches ==="
input bool               InpUsePrio1        = true;         // Prio 1: RSI Min/Max
input bool               InpUsePrio2        = true;         // Prio 2: EMA9/SMA21 momentum
input bool               InpUsePrio3        = true;         // Prio 3: MACD

//==================== PRIO 1: RSI EXTREMES ==========================
input group "=== Prio 1: RSI Extremes (no confirmation) ==="
input int                InpRsiPeriod       = 10;           // RSI Period (must match the chart)
input ENUM_APPLIED_PRICE InpRsiApplied      = PRICE_CLOSE;  // RSI Applied price
input double             InpRsiOversold     = 30.0;         // BUY when closed RSI is below this
input double             InpRsiOverbought   = 70.0;         // SELL when closed RSI is above this

//==================== PRIO 2: MOMENTUM EMA/SMA ======================
input group "=== Prio 2: Short-term momentum ==="
input int                InpMomEmaPeriod    = 20;            // Fast EMA period
input int                InpMomSmaPeriod    = 96;           // Slow SMA period
input ENUM_APPLIED_PRICE InpMomApplied      = PRICE_CLOSE;  // Momentum applied price

//==================== PRIO 3: MACD ==================================
input group "=== Prio 3: MACD ==="
input int                InpMacdFast        = 12;           // MACD Fast EMA
input int                InpMacdSlow        = 26;           // MACD Slow EMA
input int                InpMacdSignal      = 9;            // MACD Signal SMA
input ENUM_APPLIED_PRICE InpMacdApplied     = PRICE_CLOSE;  // MACD Applied price
input bool               InpMacdRequireRsiConfirm = true;   // Require RSI confirmation for MACD
input double             InpRsiBuyLevel     = 40.0;         // MACD BUY: RSI must cross above
input double             InpRsiSellLevel    = 60.0;         // MACD SELL: RSI must cross below
input int                InpRsiConfirmBars  = 5;            // Max bars to wait for RSI after MACD

//==================== ADX TREND FILTER (ALL PRIORITIES) ==============
// Applies to Prio 1 + Prio 2 + Prio 3 when enabled — one gate before open.
input group "=== ADX trend filter (ALL priorities) ==="
input bool               InpUseAdxFilter      = false;       // Enable ADX filter for ALL priorities
input int                InpAdxPeriod         = 14;         // ADX period
input double             InpAdxMinLevel       = 25.0;       // Require ADX >= this (trending); block if lower
input bool               InpAdxUseDiDirection = true;       // Match DI: BUY if +DI>-DI, SELL if -DI>+DI

//==================== TRADE SETTINGS ================================
input group "=== Trade ==="
input double             InpLots            = 0.50;         // Lot size
input bool               InpUsePercentSLTP  = false;        // true=% of price | false=points (recommended)
input int                InpStopLossPoints  = 500;          // SL distance in points (e.g. 500 = 50 pips on 5-digit FX)
input int                InpTakeProfitPoints = 2000;        // TP distance in points (e.g. 1000 = 100 pips on 5-digit FX)
input double             InpStopLossPercent = 1.0;          // WARNING: % of PRICE (not account!). Only if InpUsePercentSLTP=true
input double             InpTakeProfitPercent = 1.0;        // WARNING: % of PRICE (not account!). Only if InpUsePercentSLTP=true
input int                InpMaxBarsHold     = 10;           // Close EVERY position after N TF candles (hard limit)
input bool               InpIncludeSpread   = true;         // Add current spread to SL and TP distances
input int                InpSlippage        = 30;           // Max slippage (points)
input ulong              InpMagic           = 18300621;     // Magic number
input bool               InpOneTradeOnly    = true;         // true=1 position; false=add in the SAME direction
input int                InpMaxPositions    = 10;           // Max open positions (when OneTradeOnly=false)
input int                InpTradeCooldownBars = 3;          // No new trade for N bars after one

//==================== SESSION HOURS =================================
// Hours are inclusive (8 and 16 = 08:00-16:59). End < start wraps midnight.
input group "=== Session hours ==="
input bool               InpUseSessionFilter = true;        // Limit NEW entries to session hours
input ENUM_SESSION_CLOCK InpSessionClock     = SESSION_CLOCK_SERVER; // Clock for hours below
input int                InpSession1StartHour = 8;          // Window 1 start hour 0-23 (London ~08)
input int                InpSession1EndHour   = 16;         // Window 1 end hour 0-23 inclusive
input bool               InpUseSession2      = true;        // Second window (NY overlap)
input int                InpSession2StartHour = 13;         // Window 2 start hour 0-23 (NY ~13)
input int                InpSession2EndHour   = 21;         // Window 2 end hour 0-23 inclusive

input group "=== Triple swap (FX) ==="
input bool               InpAvoidTripleSwap   = true;         // Close 1h before 3-day swap; reopen next day if still valid

//==================== GENERAL =======================================
input group "=== General ==="
input ENUM_TIMEFRAMES    InpTimeframe       = PERIOD_CURRENT; // Signal TF (bar = 1 candle here)
input bool               InpShowComments    = true;         // Show chart comment

enum ENUM_SIGNAL_SRC
  {
   SIGNAL_NONE = 0,
   SIGNAL_EXT_BUY,
   SIGNAL_EXT_SELL,
   SIGNAL_MOM_BUY,
   SIGNAL_MOM_SELL,
   SIGNAL_MACD_BUY,
   SIGNAL_MACD_SELL
  };

//--- handles / buffers
int      g_macdHandle = INVALID_HANDLE;
int      g_rsiHandle  = INVALID_HANDLE;
int      g_emaHandle  = INVALID_HANDLE;
int      g_smaHandle  = INVALID_HANDLE;
int      g_adxHandle  = INVALID_HANDLE;
double   g_macdMain[];
double   g_macdSignal[];
double   g_rsi[];
double   g_ema[];
double   g_sma[];
double   g_adxMain[];    // buffer 0
double   g_adxPlusDi[];  // buffer 1 (+DI)
double   g_adxMinusDi[]; // buffer 2 (-DI)
datetime g_lastBarTime = 0;
CTrade   g_trade;

// pending confirmation after MACD crossover: 1=buy, -1=sell, 0=none
int g_pendingDir   = 0;
int g_pendingBars  = 0;

// extreme zone latches
bool g_extBuyArmed  = true;
bool g_extSellArmed = true;

// cooldown in BARS
int    g_tradeCooldownBarsLeft = 0;
bool   g_tradedThisBar         = false;
string g_activeSource          = "none";
string g_blockReason           = "";

struct SwapPark
  {
   ENUM_POSITION_TYPE type;
   double             lots;
   int                barsHeld;
   datetime           parkTime;
   datetime           reopenAfter;
  };

SwapPark g_swapParks[];
string   g_swapStatus = "OFF";
ulong    g_swapBonusTickets[];
int      g_swapBonusBars[];

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES SignalTF()
  {
   return (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;
  }

//+------------------------------------------------------------------+
bool IsValidHour(const int hour)
  {
   return (hour >= 0 && hour <= 23);
  }

//+------------------------------------------------------------------+
string SessionClockName()
  {
   if(InpSessionClock == SESSION_CLOCK_GMT)
      return "GMT";
   if(InpSessionClock == SESSION_CLOCK_LOCAL)
      return "Local";
   return "Server";
  }

//+------------------------------------------------------------------+
datetime SessionTimeNow()
  {
   if(InpSessionClock == SESSION_CLOCK_GMT)
      return TimeGMT();
   if(InpSessionClock == SESSION_CLOCK_LOCAL)
      return TimeLocal();
   return TimeCurrent();
  }

//+------------------------------------------------------------------+
int SessionHourNow()
  {
   MqlDateTime dt;
   TimeToStruct(SessionTimeNow(), dt);
   return dt.hour;
  }

//+------------------------------------------------------------------+
string FormatHourWindow(const int startHour, const int endHour)
  {
   return IntegerToString(startHour, 2, '0') + "-" + IntegerToString(endHour, 2, '0');
  }

//+------------------------------------------------------------------+
// Inclusive hours. 8-16 = 08:00-16:59. 22-6 wraps across midnight.
bool HourInWindow(const int hour, const int startHour, const int endHour)
  {
   if(!IsValidHour(hour) || !IsValidHour(startHour) || !IsValidHour(endHour))
      return false;
   if(startHour == endHour)
      return (hour == startHour);
   if(startHour < endHour)
      return (hour >= startHour && hour <= endHour);
   return (hour >= startHour || hour <= endHour);
  }

//+------------------------------------------------------------------+
bool IsInTradingSession()
  {
   if(!InpUseSessionFilter)
      return true;

   const int hour = SessionHourNow();
   if(HourInWindow(hour, InpSession1StartHour, InpSession1EndHour))
      return true;
   if(InpUseSession2 && HourInWindow(hour, InpSession2StartHour, InpSession2EndHour))
      return true;
   return false;
  }

//+------------------------------------------------------------------+
string SessionStatusText()
  {
   string txt = SessionClockName() + " " + FormatHourWindow(InpSession1StartHour, InpSession1EndHour);
   if(InpUseSession2)
      txt += "+" + FormatHourWindow(InpSession2StartHour, InpSession2EndHour);
   txt += " now=" + IntegerToString(SessionHourNow(), 2, '0');
   return txt;
  }

bool TripleSwapFeatureOn()
  {
   return InpAvoidTripleSwap;
  }

datetime BrokerTimeNow()
  {
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   return t;
  }

datetime DayStartOf(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
  }

int TripleSwapRolloverDow()
  {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SWAP_ROLLOVER3DAY);
  }

string TripleSwapDowName(const int dow)
  {
   switch(dow)
     {
      case 0: return "Sun";
      case 1: return "Mon";
      case 2: return "Tue";
      case 3: return "Wed";
      case 4: return "Thu";
      case 5: return "Fri";
      case 6: return "Sat";
     }
   return IntegerToString(dow);
  }

datetime TripleSwapChargeTime(const datetime now)
  {
   const int rolloverDow = TripleSwapRolloverDow();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   const int delta = dt.day_of_week - rolloverDow;
   const datetime rolloverDayStart = DayStartOf(now) - (datetime)delta * 86400;
   return (rolloverDayStart + 86400);
  }

bool IsTripleSwapCloseWindow()
  {
   if(!TripleSwapFeatureOn())
      return false;
   const datetime now    = BrokerTimeNow();
   const datetime charge = TripleSwapChargeTime(now);
   return (now >= (charge - TRIPLE_SWAP_LEAD_SEC) && now < charge);
  }

int CountSwapParks()
  {
   return ArraySize(g_swapParks);
  }

bool HasSwapParkExposure()
  {
   return (CountSwapParks() > 0);
  }

string SwapGvPrefix()
  {
   return ("MRSW" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_");
  }

void ClearSwapParkGlobals()
  {
   const string p = SwapGvPrefix();
   const int n = (int)GlobalVariableGet(p + "N");
   GlobalVariableDel(p + "N");
   const int cap = MathMax(n, SWAP_PARK_CAP);
   for(int i = 0; i < cap; i++)
     {
      const string k = p + "i" + IntegerToString(i);
      GlobalVariableDel(k + "t");
      GlobalVariableDel(k + "l");
      GlobalVariableDel(k + "b");
      GlobalVariableDel(k + "p");
      GlobalVariableDel(k + "r");
     }
  }

void PersistSwapParks()
  {
   ClearSwapParkGlobals();
   const int n = CountSwapParks();
   if(n <= 0)
      return;
   const string p = SwapGvPrefix();
   GlobalVariableSet(p + "N", (double)n);
   for(int i = 0; i < n; i++)
     {
      const string k = p + "i" + IntegerToString(i);
      GlobalVariableSet(k + "t", (double)g_swapParks[i].type);
      GlobalVariableSet(k + "l", g_swapParks[i].lots);
      GlobalVariableSet(k + "b", (double)g_swapParks[i].barsHeld);
      GlobalVariableSet(k + "p", (double)g_swapParks[i].parkTime);
      GlobalVariableSet(k + "r", (double)g_swapParks[i].reopenAfter);
     }
  }

void LoadSwapParks()
  {
   ArrayResize(g_swapParks, 0);
   if(!TripleSwapFeatureOn())
      return;
   const string p = SwapGvPrefix();
   if(!GlobalVariableCheck(p + "N"))
      return;
   int n = (int)GlobalVariableGet(p + "N");
   if(n <= 0)
      return;
   if(n > SWAP_PARK_CAP)
      n = SWAP_PARK_CAP;
   ArrayResize(g_swapParks, n);
   for(int i = 0; i < n; i++)
     {
      const string k = p + "i" + IntegerToString(i);
      g_swapParks[i].type        = (ENUM_POSITION_TYPE)(int)GlobalVariableGet(k + "t");
      g_swapParks[i].lots        = GlobalVariableGet(k + "l");
      g_swapParks[i].barsHeld    = (int)GlobalVariableGet(k + "b");
      g_swapParks[i].parkTime    = (datetime)GlobalVariableGet(k + "p");
      g_swapParks[i].reopenAfter = (datetime)GlobalVariableGet(k + "r");
     }
   g_swapStatus = "parked " + IntegerToString(n) + " (loaded)";
   Print("Triple-swap parks restored: ", n);
  }

void RemoveSwapParkAt(const int index)
  {
   const int n = CountSwapParks();
   if(index < 0 || index >= n)
      return;
   for(int i = index; i < n - 1; i++)
      g_swapParks[i] = g_swapParks[i + 1];
   ArrayResize(g_swapParks, n - 1);
  }

void ClearAllSwapParks(const string why)
  {
   if(CountSwapParks() <= 0)
      return;
   Print("Triple-swap parks cleared (", CountSwapParks(), "): ", why);
   ArrayResize(g_swapParks, 0);
   PersistSwapParks();
   g_swapStatus = "cleared: " + why;
  }

string TripleSwapStatusText()
  {
   if(!InpAvoidTripleSwap)
      return "OFF";
   const datetime now    = BrokerTimeNow();
   const datetime charge = TripleSwapChargeTime(now);
   string txt = "ON " + TripleSwapDowName(TripleSwapRolloverDow())
                + " rollover " + TimeToString(charge, TIME_DATE|TIME_MINUTES)
                + " closeFrom " + TimeToString(charge - TRIPLE_SWAP_LEAD_SEC, TIME_MINUTES);
   if(IsTripleSwapCloseWindow())
      txt += " | CLOSE WINDOW";
   const int n = CountSwapParks();
   if(n > 0)
      txt += " | parked=" + IntegerToString(n);
   if(g_swapStatus != "" && g_swapStatus != "OFF")
      txt += " | " + g_swapStatus;
   return txt;
  }

void TrackSwapBonus(const ulong ticket, const int barsHeld)
  {
   if(ticket == 0)
      return;
   const int n = ArraySize(g_swapBonusTickets);
   for(int i = 0; i < n; i++)
     {
      if(g_swapBonusTickets[i] == ticket)
        {
         g_swapBonusBars[i] = barsHeld;
         return;
        }
     }
   ArrayResize(g_swapBonusTickets, n + 1);
   ArrayResize(g_swapBonusBars, n + 1);
   g_swapBonusTickets[n] = ticket;
   g_swapBonusBars[n]    = MathMax(0, barsHeld);
  }

void RemoveSwapBonus(const ulong ticket)
  {
   const int n = ArraySize(g_swapBonusTickets);
   for(int i = n - 1; i >= 0; i--)
     {
      if(g_swapBonusTickets[i] != ticket)
         continue;
      for(int j = i; j < n - 1; j++)
        {
         g_swapBonusTickets[j] = g_swapBonusTickets[j + 1];
         g_swapBonusBars[j]    = g_swapBonusBars[j + 1];
        }
      ArrayResize(g_swapBonusTickets, n - 1);
      ArrayResize(g_swapBonusBars, n - 1);
      return;
     }
  }

int SwapBonusFor(const ulong ticket)
  {
   const int n = ArraySize(g_swapBonusTickets);
   for(int i = 0; i < n; i++)
     {
      if(g_swapBonusTickets[i] == ticket)
         return g_swapBonusBars[i];
     }
   return 0;
  }

void ManageTripleSwapAvoidance();
bool IsTradeLocked();
void UpdateComment(const ENUM_SIGNAL_SRC signal, const bool locked);

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRsiPeriod < 1 || InpMomEmaPeriod < 1 || InpMomSmaPeriod < 1 ||
      InpMacdFast < 1 || InpMacdSlow < 1 || InpMacdSignal < 1 || InpAdxPeriod < 1)
     {
      Print("Invalid indicator periods.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMacdFast >= InpMacdSlow)
     {
      Print("MACD Fast must be smaller than Slow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMomEmaPeriod >= InpMomSmaPeriod)
     {
      Print("Momentum EMA period must be smaller than SMA period.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxBarsHold < 1)
     {
      Print("InpMaxBarsHold must be >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxPositions < 1)
     {
      Print("InpMaxPositions must be >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!IsValidHour(InpSession1StartHour) || !IsValidHour(InpSession1EndHour) ||
      !IsValidHour(InpSession2StartHour) || !IsValidHour(InpSession2EndHour))
     {
      Print("Session hours must be 0-23.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpUsePercentSLTP)
     {
      if(InpStopLossPercent <= 0.0 || InpTakeProfitPercent <= 0.0)
        {
         Print("Percent SL/TP must be > 0 when InpUsePercentSLTP=true.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpStopLossPercent >= 5.0 || InpTakeProfitPercent >= 5.0)
         Print("WARNING: SL/TP >= 5% of PRICE is enormous on FX (10% of EURUSD ≈ 1000+ pips). Prefer points mode.");
     }
   else
     {
      if(InpStopLossPoints < 1 || InpTakeProfitPoints < 1)
        {
         Print("SL/TP points must be >= 1 when InpUsePercentSLTP=false.");
         return INIT_PARAMETERS_INCORRECT;
        }
     }

   const ENUM_TIMEFRAMES tf = SignalTF();

   g_rsiHandle  = iRSI(_Symbol, tf, InpRsiPeriod, InpRsiApplied);
   g_emaHandle  = iMA(_Symbol, tf, InpMomEmaPeriod, 0, MODE_EMA, InpMomApplied);
   g_smaHandle  = iMA(_Symbol, tf, InpMomSmaPeriod, 0, MODE_SMA, InpMomApplied);
   g_macdHandle = iMACD(_Symbol, tf, InpMacdFast, InpMacdSlow, InpMacdSignal, InpMacdApplied);
   g_adxHandle  = iADX(_Symbol, tf, InpAdxPeriod);

   if(g_rsiHandle == INVALID_HANDLE || g_emaHandle == INVALID_HANDLE ||
      g_smaHandle == INVALID_HANDLE || g_macdHandle == INVALID_HANDLE ||
      g_adxHandle == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
     }

   ArrayResize(g_macdMain, 3);
   ArrayResize(g_macdSignal, 3);
   ArrayResize(g_rsi, 3);
   ArrayResize(g_ema, 3);
   ArrayResize(g_sma, 3);
   ArrayResize(g_adxMain, 3);
   ArrayResize(g_adxPlusDi, 3);
   ArrayResize(g_adxMinusDi, 3);
   ArraySetAsSeries(g_macdMain, true);
   ArraySetAsSeries(g_macdSignal, true);
   ArraySetAsSeries(g_rsi, true);
   ArraySetAsSeries(g_ema, true);
   ArraySetAsSeries(g_sma, true);
   ArraySetAsSeries(g_adxMain, true);
   ArraySetAsSeries(g_adxPlusDi, true);
   ArraySetAsSeries(g_adxMinusDi, true);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   // Clean runtime state on (re)init so stale cooldown/latches cannot block forever
   g_lastBarTime           = 0;
   g_pendingDir            = 0;
   g_pendingBars           = 0;
   g_extBuyArmed           = true;
   g_extSellArmed          = true;
   g_tradeCooldownBarsLeft = 0;
   g_tradedThisBar         = false;
   g_activeSource          = "none";
   g_blockReason           = "";
   ArrayResize(g_swapParks, 0);
   ArrayResize(g_swapBonusTickets, 0);
   ArrayResize(g_swapBonusBars, 0);
   LoadSwapParks();

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("WARNING: Terminal AutoTrading is disabled.");
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("WARNING: EA trading is disabled (Allow Algo Trading).");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      Print("WARNING: Account does not allow Expert Advisors to trade.");

   string sltpMode;
   if(InpUsePercentSLTP)
      sltpMode = "PERCENT price SL=" + DoubleToString(InpStopLossPercent, 2)
                 + "% TP=" + DoubleToString(InpTakeProfitPercent, 2) + "%";
   else
      sltpMode = "POINTS SL=" + IntegerToString(InpStopLossPoints)
                 + " TP=" + IntegerToString(InpTakeProfitPoints);

   Print("TF=", EnumToString(tf),
         " | P1=", InpUsePrio1, " P2=", InpUsePrio2, " P3=", InpUsePrio3,
         " | EMA", InpMomEmaPeriod, "/SMA", InpMomSmaPeriod,
         " | ADX filter=", InpUseAdxFilter,
         " period=", InpAdxPeriod,
         " min=", DoubleToString(InpAdxMinLevel, 1),
         " DI=", InpAdxUseDiDirection,
         " | cooldown ", InpTradeCooldownBars, " bars",
         " | maxHold ", InpMaxBarsHold, " bars",
         " | lot=", DoubleToString(NormalizeVolume(InpLots), 2),
         " | oneTrade=", InpOneTradeOnly,
         " | maxPos=", EffectiveMaxPositions(),
         " | spreadInSLTP=", InpIncludeSpread,
         " | session=", (InpUseSessionFilter ? SessionStatusText() : "OFF"),
         " | tripleSwap=", TripleSwapStatusText(),
         " | ", sltpMode);

   if(InpAvoidTripleSwap)
     {
      Print("Triple-swap avoid ON (FX): close 1h before ",
            TripleSwapDowName(TripleSwapRolloverDow()),
            " rollover ", TimeToString(TripleSwapChargeTime(BrokerTimeNow()), TIME_DATE|TIME_MINUTES),
            " and reopen next day if MaxBarsHold still valid.");
      EventSetTimer(30);
     }

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_macdHandle != INVALID_HANDLE) IndicatorRelease(g_macdHandle);
   if(g_rsiHandle  != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_emaHandle  != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   if(g_smaHandle  != INVALID_HANDLE) IndicatorRelease(g_smaHandle);
   if(g_adxHandle  != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(TripleSwapFeatureOn())
      ManageTripleSwapAvoidance();
   if(InpShowComments)
      UpdateComment(SIGNAL_NONE, IsTradeLocked());
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   const bool newBar = CheckNewBar();
   if(newBar)
     {
      g_tradedThisBar = false;
      g_blockReason   = "";
     }

   ManageTripleSwapAvoidance();
   ManageMaxBarHoldExits();

   if(!newBar)
     {
      if(InpShowComments)
         UpdateComment(SIGNAL_NONE, IsTradeLocked());
      return;
     }

   if(InpUseSessionFilter && !IsInTradingSession())
      ClearPending(); // drop overnight MACD waits so they cannot fire at session open

   ENUM_SIGNAL_SRC signal = SIGNAL_NONE;

   // Try priorities in order. A detected higher prio that FAILS to open
   // (ADX / session / lock) must not swallow EMA or MACD on this bar.
   if(InpUsePrio1)
     {
      signal = DetectExtremeSignal();
      if(signal != SIGNAL_NONE)
         ExecuteSignal(signal);
     }

   if(InpUsePrio2)
     {
      const ENUM_SIGNAL_SRC mom = DetectMomentumSignal();
      if(mom != SIGNAL_NONE)
        {
         if(g_tradedThisBar)
            Print("Prio 2 EMA skipped: already opened this bar via ",
                  EnumToString(signal));
         else
           {
            if(signal != SIGNAL_NONE)
               Print("Prio 2 EMA used — higher prio ", EnumToString(signal),
                     " did not open");
            signal = mom;
            ExecuteSignal(signal);
           }
        }
     }

   if(!g_tradedThisBar && InpUsePrio3)
     {
      const ENUM_SIGNAL_SRC macd = DetectMacdSignal();
      if(macd != SIGNAL_NONE)
        {
         if(signal != SIGNAL_NONE)
            Print("Prio 3 MACD used — higher prio ", EnumToString(signal),
                  " did not open");
         signal = macd;
         ExecuteSignal(signal);
        }
     }
   else if(g_tradedThisBar)
      ClearPending(); // actually opened — drop leftover MACD wait


   const bool locked = IsTradeLocked();

   if(g_tradeCooldownBarsLeft > 0 && !g_tradedThisBar)
      g_tradeCooldownBarsLeft--;

   UpdateComment(signal, locked);
  }

//+------------------------------------------------------------------+
bool IsTradeLocked()
  {
   if(g_tradedThisBar)
     {
      g_blockReason = "already traded this bar";
      return true;
     }
   if(IsTripleSwapCloseWindow())
     {
      g_blockReason = "triple-swap window (FX rollover)";
      return true;
     }
   if(InpUseSessionFilter && !IsInTradingSession())
     {
      g_blockReason = "outside session (" + SessionStatusText() + ")";
      return true;
     }
   if(g_tradeCooldownBarsLeft > 0)
     {
      g_blockReason = "bar cooldown (" + IntegerToString(g_tradeCooldownBarsLeft) + " left)";
      return true;
     }
   const int openCount = CountOurPositions();
   const int maxPos = EffectiveMaxPositions();
   if(openCount >= maxPos)
     {
      g_blockReason = InpOneTradeOnly
                      ? "position already open"
                      : ("max positions (" + IntegerToString(openCount)
                         + "/" + IntegerToString(maxPos) + ")");
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool CanOpenTrade()
  {
   return !IsTradeLocked();
  }

//+------------------------------------------------------------------+
void MarkTradeOpened()
  {
   g_tradedThisBar = true;
   g_tradeCooldownBarsLeft = MathMax(InpTradeCooldownBars, 0);
   ClearPending();
  }

//+------------------------------------------------------------------+
int EffectiveMaxPositions()
  {
   if(InpOneTradeOnly)
      return 1;
   return MathMax(InpMaxPositions, 1);
  }

//+------------------------------------------------------------------+
bool SignalIsBuy(const ENUM_SIGNAL_SRC signal)
  {
   return (signal == SIGNAL_EXT_BUY || signal == SIGNAL_MOM_BUY || signal == SIGNAL_MACD_BUY);
  }

//+------------------------------------------------------------------+
bool SignalIsSell(const ENUM_SIGNAL_SRC signal)
  {
   return (signal == SIGNAL_EXT_SELL || signal == SIGNAL_MOM_SELL || signal == SIGNAL_MACD_SELL);
  }

//+------------------------------------------------------------------+
ENUM_SIGNAL_SRC DetectExtremeSignal()
  {
   // Prio 1: closed-bar RSI in extreme zone. Retry every bar while still in
   // the zone and armed — a single missed cross (session/ADX/cooldown) used
   // to swallow the whole dip. Latch disarms only AFTER a successful open.
   if(!CopyRsi())
      return SIGNAL_NONE;

   const double rsiCurr = g_rsi[1];
   const double rsiPrev = g_rsi[2];
   const bool inOversold   = (rsiCurr < InpRsiOversold);
   const bool inOverbought = (rsiCurr > InpRsiOverbought);

   if(!inOversold)
      g_extBuyArmed = true;
   if(!inOverbought)
      g_extSellArmed = true;

   if(g_extSellArmed && inOverbought)
     {
      Print("Prio 1 SELL: closed RSI in overbought ",
            DoubleToString(rsiPrev, 2), " -> ", DoubleToString(rsiCurr, 2),
            " > OB=", DoubleToString(InpRsiOverbought, 1),
            " period=", InpRsiPeriod);
      return SIGNAL_EXT_SELL;
     }
   if(g_extBuyArmed && inOversold)
     {
      Print("Prio 1 BUY: closed RSI in oversold ",
            DoubleToString(rsiPrev, 2), " -> ", DoubleToString(rsiCurr, 2),
            " < OS=", DoubleToString(InpRsiOversold, 1),
            " period=", InpRsiPeriod);
      return SIGNAL_EXT_BUY;
     }
   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
ENUM_SIGNAL_SRC DetectMomentumSignal()
  {
   // Prio 2: closed-bar EMA/SMA cross (bar[1] vs bar[2], never the forming bar).
   // BUY  = EMA crossed SMA from below (golden cross).
   // SELL = EMA crossed SMA from above (death cross).
   if(!CopyMomentum())
      return SIGNAL_NONE;

   const double emaPrev = g_ema[2];
   const double emaCurr = g_ema[1];
   const double smaPrev = g_sma[2];
   const double smaCurr = g_sma[1];

   const bool crossUp   = (emaPrev < smaPrev && emaCurr >= smaCurr);
   const bool crossDown = (emaPrev > smaPrev && emaCurr <= smaCurr);

   if(crossUp)
     {
      Print("Prio 2 BUY: EMA crossed SMA from below",
            " | EMA[2]=", DoubleToString(emaPrev, _Digits),
            " SMA[2]=", DoubleToString(smaPrev, _Digits),
            " -> EMA[1]=", DoubleToString(emaCurr, _Digits),
            " SMA[1]=", DoubleToString(smaCurr, _Digits));
      return SIGNAL_MOM_BUY;
     }
   if(crossDown)
     {
      Print("Prio 2 SELL: EMA crossed SMA from above",
            " | EMA[2]=", DoubleToString(emaPrev, _Digits),
            " SMA[2]=", DoubleToString(smaPrev, _Digits),
            " -> EMA[1]=", DoubleToString(emaCurr, _Digits),
            " SMA[1]=", DoubleToString(smaCurr, _Digits));
      return SIGNAL_MOM_SELL;
     }
   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
ENUM_SIGNAL_SRC DetectMacdSignal()
  {
   if(!CopyMacdAndRsi())
      return SIGNAL_NONE;

   const double macdPrev   = g_macdMain[2];
   const double macdCurr   = g_macdMain[1];
   const double signalPrev = g_macdSignal[2];
   const double signalCurr = g_macdSignal[1];
   const double rsiPrev    = g_rsi[2];
   const double rsiCurr    = g_rsi[1];

   const bool macdCrossUp   = (macdPrev <= signalPrev && macdCurr > signalCurr);
   const bool macdCrossDown = (macdPrev >= signalPrev && macdCurr < signalCurr);
   const bool macdBullish   = (macdCurr > signalCurr);
   const bool macdBearish   = (macdCurr < signalCurr);

   // Confirmation: RSI already on the correct side OR a fresh cross through the level.
   // (Old logic required a fresh cross only — if RSI was already >50 on MACD cross, pending expired unused.)
   const bool rsiCrossAboveBuy  = (rsiPrev <= InpRsiBuyLevel  && rsiCurr > InpRsiBuyLevel);
   const bool rsiCrossBelowSell = (rsiPrev >= InpRsiSellLevel && rsiCurr < InpRsiSellLevel);
   const bool rsiBuyConfirm     = (rsiCurr > InpRsiBuyLevel)  || rsiCrossAboveBuy;
   const bool rsiSellConfirm    = (rsiCurr < InpRsiSellLevel) || rsiCrossBelowSell;

   if(!InpMacdRequireRsiConfirm)
     {
      ClearPending();
      if(macdCrossUp)
         return SIGNAL_MACD_BUY;
      if(macdCrossDown)
         return SIGNAL_MACD_SELL;
      return SIGNAL_NONE;
     }

   if(macdCrossUp)
     {
      g_pendingDir  = 1;
      g_pendingBars = 0;
     }
   else if(macdCrossDown)
     {
      g_pendingDir  = -1;
      g_pendingBars = 0;
     }

   if(g_pendingDir == 1 && macdBearish)
      ClearPending();
   if(g_pendingDir == -1 && macdBullish)
      ClearPending();

   ENUM_SIGNAL_SRC signal = SIGNAL_NONE;

   if(g_pendingDir == 1)
     {
      if(rsiBuyConfirm && macdBullish)
        {
         signal = SIGNAL_MACD_BUY;
         ClearPending();
        }
      else if(!macdCrossUp)
        {
         g_pendingBars++;
         if(g_pendingBars >= MathMax(InpRsiConfirmBars, 1))
            ClearPending();
        }
     }
   else if(g_pendingDir == -1)
     {
      if(rsiSellConfirm && macdBearish)
        {
         signal = SIGNAL_MACD_SELL;
         ClearPending();
        }
      else if(!macdCrossDown)
        {
         g_pendingBars++;
         if(g_pendingBars >= MathMax(InpRsiConfirmBars, 1))
            ClearPending();
        }
     }

   return signal;
  }

//+------------------------------------------------------------------+
void ExecuteSignal(const ENUM_SIGNAL_SRC signal)
  {
   Print("Signal fire: ", EnumToString(signal));

   const bool isBuy  = SignalIsBuy(signal);
   const bool isSell = SignalIsSell(signal);
   if(!isBuy && !isSell)
      return;

   // Opposite book is always flattened first — also when OneTradeOnly=false stacking.
   const bool hasOpposite = (isBuy && HasOurPosition(POSITION_TYPE_SELL))
                            || (isSell && HasOurPosition(POSITION_TYPE_BUY));
   if(hasOpposite)
     {
      CloseAllOurPositions("contradictory " + EnumToString(signal));
      g_tradeCooldownBarsLeft = 0; // reverse is allowed immediately after flatten
      if((isBuy && HasOurPosition(POSITION_TYPE_SELL)) ||
         (isSell && HasOurPosition(POSITION_TYPE_BUY)))
        {
         Print("Opposite flatten incomplete — skip open ", EnumToString(signal));
         return;
        }
     }

   if(!PassesAdxFilter(isBuy))
     {
      Print("ADX filter blocked ", EnumToString(signal), ": ", g_blockReason);
      return;
     }

   if(isBuy && HasOurPosition(POSITION_TYPE_BUY) && InpOneTradeOnly)
     {
      Print("OpenBuy skipped: OneTradeOnly, BUY already open");
      return;
     }
   if(isSell && HasOurPosition(POSITION_TYPE_SELL) && InpOneTradeOnly)
     {
      Print("OpenSell skipped: OneTradeOnly, SELL already open");
      return;
     }

   switch(signal)
     {
      case SIGNAL_EXT_BUY:
         g_activeSource = "Prio 1: RSI Min";
         OpenBuy("P1 RSI EXT BUY", true);
         break;
      case SIGNAL_EXT_SELL:
         g_activeSource = "Prio 1: RSI Max";
         OpenSell("P1 RSI EXT SELL", true);
         break;
      case SIGNAL_MOM_BUY:
         g_activeSource = "Prio 2: EMA/SMA momentum";
         OpenBuy("P2 MOM BUY", false);
         break;
      case SIGNAL_MOM_SELL:
         g_activeSource = "Prio 2: EMA/SMA momentum";
         OpenSell("P2 MOM SELL", false);
         break;
      case SIGNAL_MACD_BUY:
         g_activeSource = "Prio 3: MACD";
         OpenBuy("P3 MACD BUY", false);
         break;
      case SIGNAL_MACD_SELL:
         g_activeSource = "Prio 3: MACD";
         OpenSell("P3 MACD SELL", false);
         break;
      default:
         break;
     }
  }

//+------------------------------------------------------------------+
void UpdateComment(const ENUM_SIGNAL_SRC signal, const bool locked)
  {
   if(!InpShowComments)
      return;

   string pendingTxt = "none";
   if(g_pendingDir == 1)
      pendingTxt = "BUY wait RSI>" + DoubleToString(InpRsiBuyLevel, 0)
                   + " (" + IntegerToString(g_pendingBars) + "/"
                   + IntegerToString(InpRsiConfirmBars) + ")";
   else if(g_pendingDir == -1)
      pendingTxt = "SELL wait RSI<" + DoubleToString(InpRsiSellLevel, 0)
                   + " (" + IntegerToString(g_pendingBars) + "/"
                   + IntegerToString(InpRsiConfirmBars) + ")";

   string sigTxt = "none";
   if(signal == SIGNAL_EXT_BUY)   sigTxt = "P1 EXT BUY";
   if(signal == SIGNAL_EXT_SELL)  sigTxt = "P1 EXT SELL";
   if(signal == SIGNAL_MOM_BUY)   sigTxt = "P2 MOM BUY";
   if(signal == SIGNAL_MOM_SELL)  sigTxt = "P2 MOM SELL";
   if(signal == SIGNAL_MACD_BUY)  sigTxt = "P3 MACD BUY";
   if(signal == SIGNAL_MACD_SELL) sigTxt = "P3 MACD SELL";

   double rsiClosed = 0.0, rsiForm = 0.0, emaNow = 0.0, smaNow = 0.0;
   double adxNow = 0.0, plusDiNow = 0.0, minusDiNow = 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_rsiHandle, 0, 1, 1, buf) >= 1) rsiClosed = buf[0];
   if(CopyBuffer(g_rsiHandle, 0, 0, 1, buf) >= 1) rsiForm = buf[0];
   if(CopyBuffer(g_emaHandle, 0, 1, 1, buf) >= 1) emaNow = buf[0];
   if(CopyBuffer(g_smaHandle, 0, 1, 1, buf) >= 1) smaNow = buf[0];
   if(g_adxHandle != INVALID_HANDLE)
     {
      if(CopyBuffer(g_adxHandle, 0, 1, 1, buf) >= 1) adxNow = buf[0];
      if(CopyBuffer(g_adxHandle, 1, 1, 1, buf) >= 1) plusDiNow = buf[0];
      if(CopyBuffer(g_adxHandle, 2, 1, 1, buf) >= 1) minusDiNow = buf[0];
     }

   string adxTxt = InpUseAdxFilter
                   ? ("ON min=" + DoubleToString(InpAdxMinLevel, 1)
                      + " DI=" + (InpAdxUseDiDirection ? "ON" : "OFF"))
                   : "OFF";

   Comment(
      "TF=", EnumToString(SignalTF()), " | 1 open/bar; RSI confirm=MACD only\n",
      "Prio1 RSI Min/Max: ", (InpUsePrio1 ? "ON" : "OFF"),
      " | Prio2 EMA", InpMomEmaPeriod, "/SMA", InpMomSmaPeriod, ": ", (InpUsePrio2 ? "ON" : "OFF"),
      " | Prio3 MACD: ", (InpUsePrio3 ? "ON" : "OFF"), "\n",
      "ADX filter: ", adxTxt,
      " | ADX=", DoubleToString(adxNow, 1),
      " +DI=", DoubleToString(plusDiNow, 1),
      " -DI=", DoubleToString(minusDiNow, 1), "\n",
      "Active: ", g_activeSource, "\n",
      "Signal: ", sigTxt,
      locked ? (" LOCKED: " + g_blockReason) : "",
      (g_blockReason != "" && StringFind(g_blockReason, "ADX") >= 0 && !locked)
         ? (" BLOCKED: " + g_blockReason) : "", "\n",
      "RSI period=", IntegerToString(InpRsiPeriod),
      " OS/OB=", DoubleToString(InpRsiOversold, 0), "/", DoubleToString(InpRsiOverbought, 0),
      " closed[1]=", DoubleToString(rsiClosed, 2),
      " form[0]=", DoubleToString(rsiForm, 2),
      (rsiClosed < InpRsiOversold ? " ZONE-BUY" : ""),
      (rsiClosed > InpRsiOverbought ? " ZONE-SELL" : ""),
      " armedB/S=", (g_extBuyArmed ? "Y" : "N"), "/", (g_extSellArmed ? "Y" : "N"), "\n",
      "  EMA=", DoubleToString(emaNow, _Digits),
      "  SMA=", DoubleToString(smaNow, _Digits), "\n",
      "Pending MACD: ", pendingTxt, "\n",
      "Session: ", (InpUseSessionFilter ? ("ON " + SessionStatusText()
                   + (IsInTradingSession() ? " OPEN" : " CLOSED")) : "OFF"), "\n",
      "Triple swap: ", TripleSwapStatusText(), "\n",
      "Cooldown bars: ", IntegerToString(g_tradeCooldownBarsLeft),
      "/", IntegerToString(InpTradeCooldownBars),
      " | MaxBarsHold=", HoldStatusText(), "\n",
      "Mode: ", (InpOneTradeOnly ? "one trade" : "stack same dir"),
      " | pos ", IntegerToString(CountOurPositions()), "/", IntegerToString(EffectiveMaxPositions()),
      " BUY=", IntegerToString(CountOurPositionsOf(POSITION_TYPE_BUY)),
      " SELL=", IntegerToString(CountOurPositionsOf(POSITION_TYPE_SELL)), "\n",
      "SL/TP: ", InpUsePercentSLTP
         ? ("%" + DoubleToString(InpStopLossPercent, 2) + "/" + DoubleToString(InpTakeProfitPercent, 2) + " of price")
         : (IntegerToString(InpStopLossPoints) + "/" + IntegerToString(InpTakeProfitPoints) + " points"),
      InpIncludeSpread ? " +spread" : "",
      " | spread=", DoubleToString(CurrentSpreadPoints(), 1), " pts"
   );
  }

//+------------------------------------------------------------------+
void ClearPending()
  {
   g_pendingDir  = 0;
   g_pendingBars = 0;
  }

//+------------------------------------------------------------------+
bool IsOurPositionTicket(const ulong ticket)
  {
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
int EstimateBarsHeld(const datetime openTime)
  {
   if(openTime <= 0)
      return 0;
   const int shift = iBarShift(_Symbol, SignalTF(), openTime, false);
   if(shift >= 0)
      return shift;
   const int sec = PeriodSeconds(SignalTF());
   if(sec <= 0)
      return 0;
   const int elapsed = (int)((TimeCurrent() - openTime) / sec);
   return MathMax(elapsed, 0);
  }

int BarsHeldForTicket(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return SwapBonusFor(ticket);
   const int held = EstimateBarsHeld((datetime)PositionGetInteger(POSITION_TIME));
   return (held + SwapBonusFor(ticket));
  }

//+------------------------------------------------------------------+
string HoldStatusText()
  {
   int n = 0;
   int oldest = 0;
   string list = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;
      const int held = BarsHeldForTicket(ticket);
      n++;
      if(held > oldest)
         oldest = held;
      if(list != "")
         list += " ";
      list += "#" + IntegerToString((long)ticket) + "(" + IntegerToString(held) + ")";
     }
   if(n <= 0)
      return ("0/" + IntegerToString(InpMaxBarsHold));
   return (IntegerToString(oldest) + "/" + IntegerToString(InpMaxBarsHold) + " " + list);
  }

//+------------------------------------------------------------------+
void ManageMaxBarHoldExits()
  {
   const int maxHold = MathMax(InpMaxBarsHold, 1);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;

      const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      const int held = BarsHeldForTicket(ticket);
      if(held < maxHold)
         continue;

      if(!g_trade.PositionClose(ticket))
         Print("MaxBarsHold close failed: ", g_trade.ResultRetcode(), " ",
               g_trade.ResultRetcodeDescription(), " ticket=", ticket,
               " held=", held, "/", maxHold);
      else
        {
         Print("MaxBarsHold closed ticket=", ticket,
               " held=", held, "/", maxHold,
               " open=", TimeToString(openTime, TIME_DATE|TIME_MINUTES));
         RemoveSwapBonus(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
bool CheckNewBar()
  {
   datetime barTime = iTime(_Symbol, SignalTF(), 0);
   if(barTime == 0)
      return false;
   if(barTime == g_lastBarTime)
      return false;
   g_lastBarTime = barTime;
   return true;
  }

//+------------------------------------------------------------------+
bool CopySeriesBuffer(const int handle, const int buffer, const int count, double &dest[])
  {
   // CopyBuffer can drop AS_SERIES on dynamic arrays. Re-apply every time so
   // dest[0]=current, dest[1]=last closed, dest[2]=previous closed.
   if(handle == INVALID_HANDLE)
      return false;
   if(CopyBuffer(handle, buffer, 0, count, dest) < count)
      return false;
   ArraySetAsSeries(dest, true);
   return true;
  }

//+------------------------------------------------------------------+
bool CopyRsi()
  {
   return CopySeriesBuffer(g_rsiHandle, 0, 3, g_rsi);
  }

//+------------------------------------------------------------------+
bool CopyMomentum()
  {
   if(!CopySeriesBuffer(g_emaHandle, 0, 3, g_ema))
      return false;
   if(!CopySeriesBuffer(g_smaHandle, 0, 3, g_sma))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool CopyMacdAndRsi()
  {
   if(!CopySeriesBuffer(g_macdHandle, 0, 3, g_macdMain))
      return false;
   if(!CopySeriesBuffer(g_macdHandle, 1, 3, g_macdSignal))
      return false;
   if(!CopySeriesBuffer(g_rsiHandle, 0, 3, g_rsi))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool CopyAdx()
  {
   // ADX main=0, +DI=1, -DI=2 — closed bar [1] used by PassesAdxFilter
   if(!CopySeriesBuffer(g_adxHandle, 0, 3, g_adxMain))
      return false;
   if(!CopySeriesBuffer(g_adxHandle, 1, 3, g_adxPlusDi))
      return false;
   if(!CopySeriesBuffer(g_adxHandle, 2, 3, g_adxMinusDi))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
// ADX gate for ALL priorities: trend strength + optional DI direction.
// BUY:  ADX >= min  and  (if DI on) +DI > -DI
// SELL: ADX >= min  and  (if DI on) -DI > +DI
bool PassesAdxFilter(const bool isBuy)
  {
   if(!InpUseAdxFilter)
      return true;

   if(g_adxHandle == INVALID_HANDLE || !CopyAdx())
     {
      g_blockReason = "ADX data unavailable";
      return false;
     }

   const double adx     = g_adxMain[1];
   const double plusDi  = g_adxPlusDi[1];
   const double minusDi = g_adxMinusDi[1];

   if(adx < InpAdxMinLevel)
     {
      g_blockReason = "ADX no trend (" + DoubleToString(adx, 1)
                      + " < " + DoubleToString(InpAdxMinLevel, 1) + ")";
      return false;
     }

   if(InpAdxUseDiDirection)
     {
      if(isBuy && !(plusDi > minusDi))
        {
         g_blockReason = "ADX DI block BUY (+DI=" + DoubleToString(plusDi, 1)
                         + " <= -DI=" + DoubleToString(minusDi, 1) + ")";
         return false;
        }
      if(!isBuy && !(minusDi > plusDi))
        {
         g_blockReason = "ADX DI block SELL (-DI=" + DoubleToString(minusDi, 1)
                         + " <= +DI=" + DoubleToString(plusDi, 1) + ")";
         return false;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
bool HasOurPosition(const ENUM_POSITION_TYPE type)
  {
   return (CountOurPositionsOf(type) > 0);
  }

//+------------------------------------------------------------------+
bool HasAnyOurPosition()
  {
   return (CountOurPositions() > 0);
  }

//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!IsOurPositionTicket(PositionGetTicket(i)))
         continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
int CountOurPositionsOf(const ENUM_POSITION_TYPE type)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
void CloseAllOurPositions(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;
      if(!g_trade.PositionClose(ticket))
         Print("Flatten failed: ", g_trade.ResultRetcode(), " ",
               g_trade.ResultRetcodeDescription(), " ticket=", ticket, " ", why);
      else
        {
         Print("Flatten ", why, " ticket=", ticket);
         RemoveSwapBonus(ticket);
        }
     }
   ClearAllSwapParks(why);
  }

//+------------------------------------------------------------------+
double TickSize()
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return tick;
  }

//+------------------------------------------------------------------+
double FloorToTick(const double price)
  {
   const double tick = TickSize();
   if(tick <= 0.0)
      return price;
   return MathFloor(price / tick + 1e-12) * tick;
  }

//+------------------------------------------------------------------+
double CeilToTick(const double price)
  {
   const double tick = TickSize();
   if(tick <= 0.0)
      return price;
   return MathCeil(price / tick - 1e-12) * tick;
  }

//+------------------------------------------------------------------+
double CurrentSpreadPrice()
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
      return 0.0;
   return (ask - bid);
  }

//+------------------------------------------------------------------+
double CurrentSpreadPoints()
  {
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;
   return CurrentSpreadPrice() / point;
  }

//+------------------------------------------------------------------+
double BrokerStopIndentPrice()
  {
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return TickSize();
   const long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * point;
  }

//+------------------------------------------------------------------+
double SafetyBufferPrice()
  {
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double tick  = TickSize();
   const double fromTicks  = 3.0 * ((tick > 0.0) ? tick : point);
   const double fromPoints = (point > 0.0) ? 10.0 * point : fromTicks;
   return MathMax(fromTicks, fromPoints);
  }

//+------------------------------------------------------------------+
// Minimum distance FROM ENTRY so SL/TP sit beyond Bid/Ask + broker stops.
// Old code used stops_level+1 point and ignored spread — on indices/CFDs
// default 500 pts is often INSIDE the spread, so SL was snapped to Bid-1
// point and the position auto-closed on the open tick.
double MinStopDistanceFromEntry()
  {
   return CurrentSpreadPrice() + BrokerStopIndentPrice() + SafetyBufferPrice();
  }

//+------------------------------------------------------------------+
double NormalizeVolume(const double lots)
  {
   const double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vol = lots;
   if(vstep > 0.0)
      vol = MathRound(vol / vstep) * vstep;
   if(vmin > 0.0 && vol < vmin)
      vol = vmin;
   if(vmax > 0.0 && vol > vmax)
      vol = vmax;
   const int volDigits = (vstep > 0.0 && vstep < 1.0)
                         ? (int)MathMax(0, MathCeil(-MathLog10(vstep) - 1e-12))
                         : 0;
   return NormalizeDouble(vol, volDigits);
  }

//+------------------------------------------------------------------+
bool StopsWouldTriggerNow(const ENUM_ORDER_TYPE orderType, const double sl, const double tp)
  {
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || sl <= 0.0 || tp <= 0.0)
      return true;
   if(orderType == ORDER_TYPE_BUY)
      return (sl >= bid || tp <= bid);
   return (sl <= ask || tp >= ask);
  }

//+------------------------------------------------------------------+
void CalcSLTPFromEntry(const ENUM_ORDER_TYPE orderType, const double entry, double &sl, double &tp)
  {
   const int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double tick    = TickSize();
   const double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double minFromEntry = MinStopDistanceFromEntry();
   const double minFromClose = BrokerStopIndentPrice() + SafetyBufferPrice();

   sl = 0.0;
   tp = 0.0;
   if(point <= 0.0 || entry <= 0.0 || tick <= 0.0)
     {
      Print("CalcSLTPFromEntry: invalid point/entry/tick");
      return;
     }

   double slDist = 0.0;
   double tpDist = 0.0;

   if(InpUsePercentSLTP)
     {
      slDist = entry * (MathMax(InpStopLossPercent, 0.01) / 100.0);
      tpDist = entry * (MathMax(InpTakeProfitPercent, 0.01) / 100.0);
     }
   else
     {
      slDist = (double)MathMax(InpStopLossPoints, 1) * point;
      tpDist = (double)MathMax(InpTakeProfitPoints, 1) * point;
     }

   // Chart is Bid. BUY opens at Ask / SELL closes at Ask, so raw SL from entry
   // is tighter than the input by exactly the spread — most stops were spread hits.
   const double spreadPx = CurrentSpreadPrice();
   if(InpIncludeSpread && spreadPx > 0.0)
     {
      slDist += spreadPx;
      tpDist += spreadPx;
     }

   if(slDist < minFromEntry)
     {
      Print("SL distance widened from ", DoubleToString(slDist, digits),
            " to ", DoubleToString(minFromEntry, digits),
            " (spread=", DoubleToString(CurrentSpreadPoints(), 1), " pts",
            " + stops/freeze + buffer) — old SL would close on open");
      slDist = minFromEntry;
     }
   if(tpDist < minFromEntry)
     {
      Print("TP distance widened from ", DoubleToString(tpDist, digits),
            " to ", DoubleToString(minFromEntry, digits),
            " (spread=", DoubleToString(CurrentSpreadPoints(), 1), " pts)");
      tpDist = minFromEntry;
     }

   if(orderType == ORDER_TYPE_BUY)
     {
      sl = FloorToTick(entry - slDist);
      tp = CeilToTick(entry + tpDist);
      const double slMax = FloorToTick(bid - minFromClose);
      const double tpMin = CeilToTick(MathMax(ask, bid) + minFromClose);
      if(sl > slMax)
         sl = slMax;
      if(tp < tpMin)
         tp = tpMin;
      if(sl >= bid)
         sl = FloorToTick(bid - MathMax(minFromClose, tick));
      if(tp <= bid || tp <= entry)
         tp = CeilToTick(MathMax(entry, bid) + MathMax(minFromClose, tick));
     }
   else
     {
      sl = CeilToTick(entry + slDist);
      tp = FloorToTick(entry - tpDist);
      const double slMin = CeilToTick(ask + minFromClose);
      const double tpMax = FloorToTick(MathMin(bid, ask) - minFromClose);
      if(sl < slMin)
         sl = slMin;
      if(tp > tpMax)
         tp = tpMax;
      if(sl <= ask)
         sl = CeilToTick(ask + MathMax(minFromClose, tick));
      if(tp >= ask || tp >= entry)
         tp = FloorToTick(MathMin(entry, ask) - MathMax(minFromClose, tick));
     }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   if(StopsWouldTriggerNow(orderType, sl, tp) || sl <= 0.0 || tp <= 0.0)
     {
      Print("CalcSLTP rejected suicide levels ", EnumToString(orderType),
            " entry=", DoubleToString(entry, digits),
            " sl=", DoubleToString(sl, digits),
            " tp=", DoubleToString(tp, digits),
            " bid=", DoubleToString(bid, digits),
            " ask=", DoubleToString(ask, digits));
      sl = 0.0;
      tp = 0.0;
      return;
     }

   Print("CalcSLTP ", EnumToString(orderType),
         " entry=", DoubleToString(entry, digits),
         " sl=", DoubleToString(sl, digits),
         " tp=", DoubleToString(tp, digits),
         " slDist=", DoubleToString(slDist, digits),
         " tpDist=", DoubleToString(tpDist, digits),
         " spreadPts=", DoubleToString(CurrentSpreadPoints(), 1),
         " includeSpread=", InpIncludeSpread,
         " mode=", (InpUsePercentSLTP ? "percent" : "points"));
  }

//+------------------------------------------------------------------+
void CalcSLTP(const ENUM_ORDER_TYPE orderType, double &sl, double &tp)
  {
   const double entry = (orderType == ORDER_TYPE_BUY)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   CalcSLTPFromEntry(orderType, entry, sl, tp);
  }

//+------------------------------------------------------------------+
bool EnsurePositionSLTP(const ulong ticket, const ENUM_POSITION_TYPE type)
  {
   if(ticket == 0 || !PositionSelectByTicket(ticket))
     {
      Print("EnsurePositionSLTP: cannot select ticket ", ticket);
      return false;
     }

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   if(curSL > 0.0 && curTP > 0.0)
     {
      Print("SL/TP OK ticket=", ticket,
            " SL=", DoubleToString(curSL, _Digits),
            " TP=", DoubleToString(curTP, _Digits));
      return true;
     }

   const ENUM_ORDER_TYPE orderType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl, tp;
   CalcSLTPFromEntry(orderType, openPrice, sl, tp);
   if(sl <= 0.0 || tp <= 0.0)
     {
      Print("EnsurePositionSLTP: CalcSLTP returned zero levels for ticket ", ticket);
      return false;
     }

   if(curSL > 0.0)
      sl = curSL;
   if(curTP > 0.0)
      tp = curTP;

   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   Print("SL/TP missing on ticket=", ticket,
         " curSL=", DoubleToString(curSL, digits),
         " curTP=", DoubleToString(curTP, digits),
         " -> modify SL=", DoubleToString(sl, digits),
         " TP=", DoubleToString(tp, digits));

   if(!g_trade.PositionModify(ticket, sl, tp))
     {
      Print("PositionModify FAILED ticket=", ticket,
            " ret=", g_trade.ResultRetcode(), " ",
            g_trade.ResultRetcodeDescription());
      return false;
     }

   if(!PositionSelectByTicket(ticket))
      return false;

   curSL = PositionGetDouble(POSITION_SL);
   curTP = PositionGetDouble(POSITION_TP);
   const bool ok = (curSL > 0.0 && curTP > 0.0);
   Print(ok ? "PositionModify OK" : "PositionModify still missing levels",
         " ticket=", ticket,
         " SL=", DoubleToString(curSL, digits),
         " TP=", DoubleToString(curTP, digits));
   return ok;
  }

//+------------------------------------------------------------------+
bool IsInvalidStopsRetcode(const uint retcode)
  {
   return (retcode == TRADE_RETCODE_INVALID_STOPS ||
           retcode == TRADE_RETCODE_INVALID_PRICE ||
           retcode == TRADE_RETCODE_INVALID_ORDER);
  }

bool SwapHoldStillValid(const int barsHeld)
  {
   return (barsHeld < MathMax(InpMaxBarsHold, 1));
  }

bool SwapParkStillApplicable(const SwapPark &park)
  {
   if((BrokerTimeNow() - park.parkTime) > SWAP_PARK_STALE_SEC)
     {
      Print("Triple-swap reopen skipped: stale park");
      return false;
     }
   if(!SwapHoldStillValid(park.barsHeld))
     {
      Print("Triple-swap reopen skipped: MaxBarsHold exhausted");
      return false;
     }
   return true;
  }

bool OpenSwapReopen(const SwapPark &park)
  {
   const bool isBuy = (park.type == POSITION_TYPE_BUY);
   if(isBuy && HasOurPosition(POSITION_TYPE_SELL))
     {
      Print("Triple-swap reopen blocked: opposite SELL still open");
      return false;
     }
   if(!isBuy && HasOurPosition(POSITION_TYPE_BUY))
     {
      Print("Triple-swap reopen blocked: opposite BUY still open");
      return false;
     }

   const ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double sl, tp;
   CalcSLTP(orderType, sl, tp);
   if(sl <= 0.0 || tp <= 0.0)
     {
      Print("Triple-swap reopen blocked: invalid SL/TP");
      return false;
     }

   const double lots = NormalizeVolume(park.lots);
   if(lots <= 0.0)
     {
      Print("Triple-swap reopen blocked: invalid lots");
      return false;
     }

   const string comment = isBuy ? "MACD RSI SWAP REOPEN BUY"
                                : "MACD RSI SWAP REOPEN SELL";
   bool ok = isBuy
             ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, comment)
             : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);
   if(!ok)
     {
      const uint ret = g_trade.ResultRetcode();
      Print("Triple-swap reopen failed: ", ret, " ", g_trade.ResultRetcodeDescription());
      if(!IsInvalidStopsRetcode(ret))
         return false;
      ok = isBuy
           ? g_trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, comment)
           : g_trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, comment);
      if(!ok)
        {
         Print("Triple-swap reopen retry without SL/TP failed: ",
               g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         return false;
        }
     }

   const ulong ticket = FindNewestOurPosition(park.type);
   if(ticket == 0)
     {
      Print("Triple-swap reopen: fill not found");
      return false;
     }

   TrackSwapBonus(ticket, park.barsHeld);
   EnsurePositionSLTP(ticket, park.type);
   Print("Triple-swap reopened ticket=", ticket,
         " type=", EnumToString(park.type),
         " lots=", DoubleToString(lots, 2),
         " barsHeld=", park.barsHeld);
   return true;
  }

void ParkAndCloseForTripleSwap()
  {
   const datetime now    = BrokerTimeNow();
   const datetime charge = TripleSwapChargeTime(now);
   bool any = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;

      const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double lots = PositionGetDouble(POSITION_VOLUME);
      const int barsHeld = BarsHeldForTicket(ticket);

      if(!g_trade.PositionClose(ticket))
        {
         Print("Triple-swap close failed ticket=", ticket, " ",
               g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         continue;
        }

      RemoveSwapBonus(ticket);
      const int n = CountSwapParks();
      ArrayResize(g_swapParks, n + 1);
      g_swapParks[n].type        = type;
      g_swapParks[n].lots        = lots;
      g_swapParks[n].barsHeld    = barsHeld;
      g_swapParks[n].parkTime    = now;
      g_swapParks[n].reopenAfter = charge;
      any = true;
      Print("Triple-swap parked ticket=", ticket,
            " type=", EnumToString(type),
            " lots=", DoubleToString(lots, 2),
            " barsHeld=", barsHeld,
            " reopenAfter=", TimeToString(charge, TIME_DATE|TIME_MINUTES));
     }

   if(any)
     {
      PersistSwapParks();
      g_swapStatus = "closed for 3-day swap, reopen next day";
     }
  }

void TryReopenSwapParks()
  {
   if(!HasSwapParkExposure())
      return;
   if(IsTripleSwapCloseWindow())
      return;

   const datetime now = BrokerTimeNow();
   if(InpUseSessionFilter && !IsInTradingSession())
     {
      g_swapStatus = "waiting session to reopen";
      return;
     }

   int opened = 0;
   for(int i = CountSwapParks() - 1; i >= 0; i--)
     {
      const SwapPark park = g_swapParks[i];
      if(now < park.reopenAfter)
         continue;
      if(DayStartOf(now) <= DayStartOf(park.parkTime))
         continue;
      if(!SwapParkStillApplicable(park))
        {
         RemoveSwapParkAt(i);
         PersistSwapParks();
         continue;
        }
      if(CountOurPositions() >= EffectiveMaxPositions())
        {
         Print("Triple-swap reopen blocked: max positions");
         break;
        }
      if(OpenSwapReopen(park))
        {
         RemoveSwapParkAt(i);
         PersistSwapParks();
         opened++;
        }
     }

   if(opened > 0)
     {
      g_tradedThisBar = true;
      g_swapStatus    = "reopened " + IntegerToString(opened);
      g_activeSource  = "triple-swap reopen";
     }
   else if(!HasSwapParkExposure())
      g_swapStatus = "idle";
  }

void ManageTripleSwapAvoidance()
  {
   if(!TripleSwapFeatureOn())
     {
      g_swapStatus = "OFF";
      return;
     }
   if(IsTripleSwapCloseWindow())
     {
      ParkAndCloseForTripleSwap();
      return;
     }
   TryReopenSwapParks();
  }

//+------------------------------------------------------------------+
void OpenBuy(const string comment, const bool isExtreme)
  {
   if(HasOurPosition(POSITION_TYPE_SELL))
     {
      Print("OpenBuy blocked: opposite SELL still open");
      return;
     }
   if(!CanOpenTrade())
     {
      Print("OpenBuy blocked: ", g_blockReason);
      return;
     }

   double sl, tp;
   CalcSLTP(ORDER_TYPE_BUY, sl, tp);
   if(sl <= 0.0 || tp <= 0.0)
     {
      Print("OpenBuy blocked: invalid SL/TP after CalcSLTP");
      return;
     }

   const double lots = NormalizeVolume(InpLots);
   if(lots <= 0.0)
     {
      Print("OpenBuy blocked: invalid lot size after normalize");
      return;
     }

   if(!g_trade.Buy(lots, _Symbol, 0.0, sl, tp, comment))
     {
      const uint ret = g_trade.ResultRetcode();
      Print("Buy failed: ", ret, " ", g_trade.ResultRetcodeDescription(),
            " lots=", DoubleToString(lots, 2),
            " sl=", DoubleToString(sl, _Digits),
            " tp=", DoubleToString(tp, _Digits));
      if(!IsInvalidStopsRetcode(ret))
         return;
      // Broker rejected stops on market order — open bare, then PositionModify
      if(!g_trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, comment))
        {
         Print("Buy retry without SL/TP also failed: ",
               g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         return;
        }
      Print("Buy opened WITHOUT SL/TP — will attach via PositionModify");
     }

   MarkTradeOpened();
   if(isExtreme)
      g_extBuyArmed = false;
   ulong ticket = FindNewestOurPosition(POSITION_TYPE_BUY);
   if(ticket != 0)
      EnsurePositionSLTP(ticket, POSITION_TYPE_BUY);
   else
      Print("OpenBuy: position ticket not found after fill");
  }

//+------------------------------------------------------------------+
void OpenSell(const string comment, const bool isExtreme)
  {
   if(HasOurPosition(POSITION_TYPE_BUY))
     {
      Print("OpenSell blocked: opposite BUY still open");
      return;
     }
   if(!CanOpenTrade())
     {
      Print("OpenSell blocked: ", g_blockReason);
      return;
     }

   double sl, tp;
   CalcSLTP(ORDER_TYPE_SELL, sl, tp);
   if(sl <= 0.0 || tp <= 0.0)
     {
      Print("OpenSell blocked: invalid SL/TP after CalcSLTP");
      return;
     }

   const double lots = NormalizeVolume(InpLots);
   if(lots <= 0.0)
     {
      Print("OpenSell blocked: invalid lot size after normalize");
      return;
     }

   if(!g_trade.Sell(lots, _Symbol, 0.0, sl, tp, comment))
     {
      const uint ret = g_trade.ResultRetcode();
      Print("Sell failed: ", ret, " ", g_trade.ResultRetcodeDescription(),
            " lots=", DoubleToString(lots, 2),
            " sl=", DoubleToString(sl, _Digits),
            " tp=", DoubleToString(tp, _Digits));
      if(!IsInvalidStopsRetcode(ret))
         return;
      if(!g_trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, comment))
        {
         Print("Sell retry without SL/TP also failed: ",
               g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         return;
        }
      Print("Sell opened WITHOUT SL/TP — will attach via PositionModify");
     }

   MarkTradeOpened();
   if(isExtreme)
      g_extSellArmed = false;
   ulong ticket = FindNewestOurPosition(POSITION_TYPE_SELL);
   if(ticket != 0)
      EnsurePositionSLTP(ticket, POSITION_TYPE_SELL);
   else
      Print("OpenSell: position ticket not found after fill");
  }

//+------------------------------------------------------------------+
ulong FindNewestOurPosition(const ENUM_POSITION_TYPE type)
  {
   ulong   bestTicket = 0;
   datetime bestTime  = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= bestTime)
        {
         bestTime   = t;
         bestTicket = ticket;
        }
     }
   return bestTicket;
  }
//+------------------------------------------------------------------+
