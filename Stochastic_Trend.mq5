//+------------------------------------------------------------------+
//|                                             Stochastic_Trend.mq5 |
//|  US30 / index-oriented trend EA.                                 |
//|  Trade Stochastic signals ONLY with EMA trend (+ ADX).           |
//|  Uptrend  = EMA Fast > EMA Slow  -> BUY only                     |
//|  Downtrend= EMA Fast < EMA Slow  -> SELL only                    |
//|                                                                  |
//|  CLOSE (v1.90): ticket rides EMA trend until a CLEAR flip OR     |
//|  MaxBarsHold (hard cap) for THAT ticket.                         |
//|  BUY close:  EMA fast < EMA slow.  SELL close: EMA fast > slow.  |
//|  No min-distance / no ADX>=25 required to close.                 |
//|  Opposite extreme (InpCloseOnOppositeExtreme, default ON):       |
//|  While BUY(s) are open, if osc hits OB then later OS → flatten.  |
//|  While SELL(s) are open, if osc hits OS then later OB → flatten. |
//|  Latch is independent of RequireExtreme/ADX (those only gate     |
//|  ENTRIES; Extreme+ADX never opens BUY at OB, so open-time flags  |
//|  alone would never fire).                                        |
//|                                                                  |
//|  PYRAMID (v1.50): while trend unchanged, add 1 position every    |
//|  InpAddEveryBars, until InpMaxPositions. Same direction as trend.|
//|  Each ticket = 1 open + 1 close, own hold timer, own SL/TP.      |
//|  Never add on the same bar as the last open.                     |
//|  At most ONE NEW entry per bar.                                  |
//|                                                                  |
//|  NEWS (v1.81): paginated JSON {date d-m-Y H:i:s, signal}. []=end.|
//|  Backfill remembers last signal for later flips only.            |
//|  Live poll arms bias / trades. API OFF => no news block.         |
//|  Driven ONLY by visible inputs — no hidden period swaps.         |
//|                                                                  |
//|  ENTRY (v1.81): closed-bar oscillator IN EMA trend opens.        |
//|  OSC_STOCH: K/D cross [2]->[1] (Low/High like the MT5 chart).    |
//|  OSC_RSI:   mid-50 cross, or leave OS/OB when extreme is on.     |
//|  RSI extreme (v1.82): BUY leave OS, SELL leave OB — zone on      |
//|  closed [2] or [3], rising/falling confirmation on [1].          |
//|  InpStochRequireExtreme applies to BOTH Stoch and RSI (OFF).     |
//|  ADX optional, default OFF. EMA = side filter + close on flip.   |
//|  EMA is NOT an entry.                                            |
//|                                                                  |
//|  NOTE: "bars" = candles on InpTimeframe (e.g. 12 on M15 = 3h).   |
//|  SL/TP: points = SYMBOL_POINT (not Dow index points).            |
//|  After every open, POSITION_SL/TP are verified (+ PositionModify).|
//|  Session hours: new entries only; SL/TP + MaxBarsHold still run. |
//|                                                                  |
//|  TRIPLE SWAP (v1.93, FX e.g. EURUSD, default ON): close 1h before|
//|  the 3-day swap rollover (usually Wed 23:00 server), reopen next |
//|  day if EMA trend + MaxBarsHold still valid.                     |
//+------------------------------------------------------------------+
#property copyright "My robots"
#property version   "1.93"
#property strict

#include <Trade\Trade.mqh>

#define HARD_SLIPPAGE          30
#define HOLD_MAX_POSITIONS_CAP 20
#define TRIPLE_SWAP_LEAD_SEC   3600
#define SWAP_PARK_STALE_SEC    129600
#define NEWS_STRONG_BARS       5
#define NEWS_HTTP_TIMEOUT_MS   4000
#define NEWS_MAX_PAGES         50
#define RSI_MID_LEVEL          50.0

enum ENUM_OSC_MODE
  {
   OSC_STOCH = 0, // Stochastic
   OSC_RSI   = 1  // RSI
  };

enum ENUM_SESSION_CLOCK
  {
   SESSION_CLOCK_SERVER = 0, // Broker server time
   SESSION_CLOCK_GMT    = 1, // GMT / UTC
   SESSION_CLOCK_LOCAL  = 2  // PC local time
  };

//==================== OSCILLATOR ====================================
input group "=== Oscillator ==="
input ENUM_OSC_MODE      InpOscillator         = OSC_STOCH;     // Oscillator: Stochastic | RSI (tester: Reset inputs)

//==================== STOCHASTIC ====================================
input group "=== Stochastic ==="
input int                InpStochKPeriod       = 26;            // %K
input int                InpStochDPeriod       = 10;             // %D
input int                InpStochSlowing       = 10;             // Slowing
input double             InpStochOversold      = 20.0;          // Oversold (when RequireExtreme)
input double             InpStochOverbought    = 80.0;          // Overbought (when RequireExtreme)
input bool               InpStochRequireExtreme = true;       // Require OS/OB (also RSI; OFF = any K/D / 50 cross)
input ENUM_STO_PRICE     InpStochPriceField    = STO_LOWHIGH;   // Price field (MT5 chart = Low/High)

//==================== RSI ===========================================
input group "=== RSI ==="
input int                InpRsiPeriod          = 14;            // RSI period (OSC_RSI only)
input ENUM_APPLIED_PRICE InpRsiApplied         = PRICE_CLOSE;   // RSI price
input double             InpRsiOversold        = 30.0;          // RSI oversold (when RequireExtreme)
input double             InpRsiOverbought      = 70.0;          // RSI overbought (when RequireExtreme)

//==================== TREND EMA =====================================
input group "=== Trend (EMA) ==="
input int                InpEmaFast            = 81;            // Fast EMA
input int                InpEmaSlow            = 255;           // Slow EMA

//==================== ADX ===========================================
input group "=== ADX ==="
input bool               InpUseAdxFilter       = true;        // ADX strength filter (OFF = does not block oscillator; no DI filter)
input int                InpAdxPeriod          = 14;            // ADX period
input double             InpAdxMinLevel        = 15.0;          // Min ADX (only when filter ON)

//==================== TRADE =========================================
// 1 point = SYMBOL_POINT, not a Dow index point.
input group "=== Trade ==="
input double             InpLots               = 0.010;          // Lot
input int                InpStopLossPoints     = 400;          // SL in points
input int                InpTakeProfitPoints   = 500;          // TP in points
input int                InpMaxPositions       = 10;            // Max open positions
input int                InpAddEveryBars       = 6;             // Add every X bars in the same trend (0=off)
input int                InpMaxBarsHold        = 20;            // Hard bar limit per ticket (hold until EMA flip)
input bool               InpCloseOnOppositeExtreme = true;      // Flatten: while BUY, osc was at OB then fell to OS
input int                InpTradeCooldownBars  = 4;             // Pause after signal (adds still use AddEveryBars)

// Hours are inclusive (8 and 16 = 08:00-16:59). End < start wraps midnight.
input group "=== Session hours ==="
input bool               InpUseSessionFilter   = true;        // Limit NEW entries to session hours
input ENUM_SESSION_CLOCK InpSessionClock       = SESSION_CLOCK_SERVER; // Clock for hours below
input int                InpSession1StartHour  = 8;           // Window 1 start hour 0-23 (London ~08)
input int                InpSession1EndHour    = 16;          // Window 1 end hour 0-23 inclusive
input bool               InpUseSession2        = true;        // Second window (NY overlap)
input int                InpSession2StartHour  = 13;          // Window 2 start hour 0-23 (NY ~13)
input int                InpSession2EndHour    = 21;          // Window 2 end hour 0-23 inclusive

input group "=== Triple swap (FX) ==="
input bool               InpAvoidTripleSwap    = true;          // Close 1h before 3-day swap; reopen next day if still valid

//==================== GENERAL ========================================
input group "=== Ogolne ==="
input ulong              InpMagic              = 26091211;      // Magic
input ENUM_TIMEFRAMES    InpTimeframe          = PERIOD_CURRENT; // Signal timeframe
input bool               InpShowComments       = true;          // Chart comment

//==================== NEWS API ======================================
// GET {url}?page=N&from=dd-mm-YYYY HH:MM:SS  (append & if URL already has ?)
// page = 1-based. from = InpNewsBackfillFrom in payload format d-m-Y H:i:s.
// Each page is a JSON array of { "date":"d-m-Y H:i:s", "signal":"positive|neutral|negative" }.
// Wrapper {"data":[...]} or {"news":[...]} is accepted. Empty array [] = no more pages.
// Typical REST: page 1 = newest. Backfill pages only set bias; live poll applies trades.
input group "=== News API ==="
input bool               InpUseNewsApi         = false;         // Use news API (default OFF)
input string             InpNewsApiUrl         = "";            // Endpoint URL (GET)
input string             InpNewsApiToken       = "";            // Bearer/token header
input int                InpNewsPollSeconds    = 5;             // Long-poll / poll interval seconds
input datetime           InpNewsBackfillFrom   = D'2026.01.01 00:00:00'; // Fetch news from this date forward (backfill)
input double             InpNewsFlipLotMult    = 1.5;           // Lot multiplier after a flip (next open)

enum ENUM_SIGNAL_SRC
  {
   SIGNAL_NONE = 0,
   SIGNAL_STOCH_BUY,
   SIGNAL_STOCH_SELL,
   SIGNAL_RSI_BUY,
   SIGNAL_RSI_SELL,
   SIGNAL_PYRAMID_BUY,
   SIGNAL_PYRAMID_SELL,
   SIGNAL_NEWS_BUY,
   SIGNAL_NEWS_SELL
  };

enum ENUM_NEWS_SENT
  {
   NEWS_SENT_NONE = 0,
   NEWS_SENT_NEUTRAL,
   NEWS_SENT_POSITIVE,
   NEWS_SENT_NEGATIVE
  };

struct NewsItem
  {
   datetime       when;
   ENUM_NEWS_SENT sent;
   string         signalRaw;
  };

enum ENUM_TREND_DIR
  {
   TREND_FLAT = 0,
   TREND_UP,
   TREND_DOWN
  };

int      g_stochHandle   = INVALID_HANDLE;
int      g_rsiHandle     = INVALID_HANDLE;
int      g_emaFastHandle = INVALID_HANDLE;
int      g_emaSlowHandle = INVALID_HANDLE;
int      g_adxHandle     = INVALID_HANDLE;
double   g_stochK[];
double   g_stochD[];
double   g_rsi[];
double   g_emaFast[];
double   g_emaSlow[];
double   g_adxMain[];
double   g_adxPlusDi[];
double   g_adxMinusDi[];
datetime g_lastBarTime   = 0;
CTrade   g_trade;

int      g_maxPositions = 3;
ulong    g_holdTickets[];
int      g_holdBarsHeld[];
datetime g_holdOpenTime[];
bool     g_holdOpenedAtHigh[];
bool     g_holdOpenedAtLow[];

int             g_tradeCooldownBarsLeft = 0;
bool            g_tradedThisBar         = false;
datetime        g_lastAddBarTime        = 0;
ENUM_TREND_DIR  g_campaignTrend         = TREND_FLAT;
bool            g_buysSawOverbought     = false; // latch while BUYs open (not only at fill)
bool            g_sellsSawOversold      = false;
string          g_activeSource          = "none";
string          g_blockReason           = "";
string          g_signalKind            = "none";

bool            g_newsBackfillDone      = false;
datetime        g_newsLastProcessedTime = 0;
string          g_newsLastSignal        = "";
string          g_newsStatus            = "OFF";
string          g_newsLastError         = "";
string          g_newsPrintedError      = "";
bool            g_newsBadItemLogged     = false;
ENUM_NEWS_SENT  g_newsLastActionable    = NEWS_SENT_NONE;
bool            g_newsLiveBiasArmed     = false;
bool            g_newsStrong            = false;
int             g_newsStrongBarsLeft    = 0;
bool            g_newsFlipLotPending    = false;
double          g_newsFlipLotMult       = 1.5;
datetime        g_lastOscCopyFailBar    = 0;

struct SwapPark
  {
   ENUM_POSITION_TYPE type;
   double             lots;
   int                barsHeld;
   datetime           originalOpen;
   bool               atHigh;
   bool               atLow;
   datetime           parkTime;
   datetime           reopenAfter;
  };

SwapPark        g_swapParks[];
string          g_swapStatus            = "OFF";

//+------------------------------------------------------------------+
bool UseRsiOscillator()
  {
   return (InpOscillator == OSC_RSI);
  }

string OscillatorName()
  {
   return UseRsiOscillator() ? "RSI" : "Stoch";
  }

ENUM_TIMEFRAMES SignalTF()
  {
   return (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;
  }

bool IsValidHour(const int hour)
  {
   return (hour >= 0 && hour <= 23);
  }

string SessionClockName()
  {
   if(InpSessionClock == SESSION_CLOCK_GMT)
      return "GMT";
   if(InpSessionClock == SESSION_CLOCK_LOCAL)
      return "Local";
   return "Server";
  }

datetime SessionTimeNow()
  {
   if(InpSessionClock == SESSION_CLOCK_GMT)
      return TimeGMT();
   if(InpSessionClock == SESSION_CLOCK_LOCAL)
      return TimeLocal();
   return TimeCurrent();
  }

int SessionHourNow()
  {
   MqlDateTime dt;
   TimeToStruct(SessionTimeNow(), dt);
   return dt.hour;
  }

string FormatHourWindow(const int startHour, const int endHour)
  {
   return IntegerToString(startHour, 2, '0') + "-" + IntegerToString(endHour, 2, '0');
  }

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

string SessionStatusText()
  {
   string txt = SessionClockName() + " " + FormatHourWindow(InpSession1StartHour, InpSession1EndHour);
   if(InpUseSession2)
      txt += "+" + FormatHourWindow(InpSession2StartHour, InpSession2EndHour);
   txt += " now=" + IntegerToString(SessionHourNow(), 2, '0');
   return txt;
  }

//+------------------------------------------------------------------+
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
   long rollover = 3;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_SWAP_ROLLOVER3DAYS, rollover))
      return 3;
   return (int)rollover;
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
   return ("STSW" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_");
  }

void ClearSwapParkGlobals()
  {
   const string p = SwapGvPrefix();
   const int n = (int)GlobalVariableGet(p + "N");
   GlobalVariableDel(p + "N");
   GlobalVariableDel(p + "C");
   GlobalVariableDel(p + "BOB");
   GlobalVariableDel(p + "SOS");
   const int cap = MathMax(n, HOLD_MAX_POSITIONS_CAP);
   for(int i = 0; i < cap; i++)
     {
      const string k = p + "i" + IntegerToString(i);
      GlobalVariableDel(k + "t");
      GlobalVariableDel(k + "l");
      GlobalVariableDel(k + "b");
      GlobalVariableDel(k + "o");
      GlobalVariableDel(k + "f");
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
   GlobalVariableSet(p + "C", (double)g_campaignTrend);
   GlobalVariableSet(p + "BOB", g_buysSawOverbought ? 1.0 : 0.0);
   GlobalVariableSet(p + "SOS", g_sellsSawOversold ? 1.0 : 0.0);
   for(int i = 0; i < n; i++)
     {
      const string k = p + "i" + IntegerToString(i);
      double flags = 0.0;
      if(g_swapParks[i].atHigh)
         flags += 1.0;
      if(g_swapParks[i].atLow)
         flags += 2.0;
      GlobalVariableSet(k + "t", (double)g_swapParks[i].type);
      GlobalVariableSet(k + "l", g_swapParks[i].lots);
      GlobalVariableSet(k + "b", (double)g_swapParks[i].barsHeld);
      GlobalVariableSet(k + "o", (double)g_swapParks[i].originalOpen);
      GlobalVariableSet(k + "f", flags);
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
   if(n > HOLD_MAX_POSITIONS_CAP)
      n = HOLD_MAX_POSITIONS_CAP;
   ArrayResize(g_swapParks, n);
   if(GlobalVariableCheck(p + "C"))
      g_campaignTrend = (ENUM_TREND_DIR)(int)GlobalVariableGet(p + "C");
   if(GlobalVariableCheck(p + "BOB"))
      g_buysSawOverbought = (GlobalVariableGet(p + "BOB") > 0.5);
   if(GlobalVariableCheck(p + "SOS"))
      g_sellsSawOversold = (GlobalVariableGet(p + "SOS") > 0.5);
   for(int i = 0; i < n; i++)
     {
      const string k = p + "i" + IntegerToString(i);
      g_swapParks[i].type         = (ENUM_POSITION_TYPE)(int)GlobalVariableGet(k + "t");
      g_swapParks[i].lots         = GlobalVariableGet(k + "l");
      g_swapParks[i].barsHeld     = (int)GlobalVariableGet(k + "b");
      g_swapParks[i].originalOpen = (datetime)GlobalVariableGet(k + "o");
      const int flags             = (int)GlobalVariableGet(k + "f");
      g_swapParks[i].atHigh       = ((flags & 1) != 0);
      g_swapParks[i].atLow        = ((flags & 2) != 0);
      g_swapParks[i].parkTime     = (datetime)GlobalVariableGet(k + "p");
      g_swapParks[i].reopenAfter  = (datetime)GlobalVariableGet(k + "r");
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

void DropSwapParksOfType(const ENUM_POSITION_TYPE type, const string why)
  {
   int dropped = 0;
   for(int i = CountSwapParks() - 1; i >= 0; i--)
     {
      if(g_swapParks[i].type != type)
         continue;
      RemoveSwapParkAt(i);
      dropped++;
     }
   if(dropped > 0)
     {
      PersistSwapParks();
      Print("Triple-swap dropped ", dropped, " parked ", EnumToString(type), ": ", why);
     }
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

//+------------------------------------------------------------------+
int EffectiveTradeCooldownBars()
  {
   return MathMax(InpTradeCooldownBars, 0);
  }

int EffectiveMaxBarsHold()
  {
   return InpMaxBarsHold;
  }

int EffectiveMaxPositions()
  {
   return g_maxPositions;
  }

int EffectiveAddEveryBars()
  {
   return InpAddEveryBars;
  }

string SignalKindText(const ENUM_SIGNAL_SRC signal)
  {
   switch(signal)
     {
      case SIGNAL_STOCH_BUY:
      case SIGNAL_STOCH_SELL:
         return "KD cross";
      case SIGNAL_RSI_BUY:
      case SIGNAL_RSI_SELL:
         return "RSI cross";
      case SIGNAL_PYRAMID_BUY:
      case SIGNAL_PYRAMID_SELL:
         return "dokup";
      case SIGNAL_NEWS_BUY:
      case SIGNAL_NEWS_SELL:
         return "news";
      default:
         return "none";
     }
  }

bool IsBuySignal(const ENUM_SIGNAL_SRC signal)
  {
   return (signal == SIGNAL_STOCH_BUY || signal == SIGNAL_RSI_BUY ||
           signal == SIGNAL_PYRAMID_BUY || signal == SIGNAL_NEWS_BUY);
  }

bool IsSellSignal(const ENUM_SIGNAL_SRC signal)
  {
   return (signal == SIGNAL_STOCH_SELL || signal == SIGNAL_RSI_SELL ||
           signal == SIGNAL_PYRAMID_SELL || signal == SIGNAL_NEWS_SELL);
  }

void ResetCampaign()
  {
   g_campaignTrend       = TREND_FLAT;
   g_lastAddBarTime      = 0;
   g_buysSawOverbought   = false;
   g_sellsSawOversold    = false;
  }

void RememberOpen(const ENUM_TREND_DIR dir)
  {
   g_tradedThisBar         = true;
   g_tradeCooldownBarsLeft = EffectiveTradeCooldownBars();
   g_lastAddBarTime        = g_lastBarTime;
   if(g_lastAddBarTime == 0)
      g_lastAddBarTime = iTime(_Symbol, SignalTF(), 0);
   if(dir == TREND_UP || dir == TREND_DOWN)
      g_campaignTrend = dir;
  }

//+------------------------------------------------------------------+
ENUM_NEWS_SENT ParseNewsSentiment(string raw)
  {
   StringTrimLeft(raw);
   StringTrimRight(raw);
   StringToLower(raw);
   if(raw == "positive")
      return NEWS_SENT_POSITIVE;
   if(raw == "negative")
      return NEWS_SENT_NEGATIVE;
   if(raw == "neutral")
      return NEWS_SENT_NEUTRAL;
   return NEWS_SENT_NONE;
  }

string NewsSentimentText(const ENUM_NEWS_SENT sent)
  {
   if(sent == NEWS_SENT_POSITIVE)
      return "positive";
   if(sent == NEWS_SENT_NEGATIVE)
      return "negative";
   if(sent == NEWS_SENT_NEUTRAL)
      return "neutral";
   return "none";
  }

string FormatNewsDateDmY(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringFormat("%02d-%02d-%04d %02d:%02d:%02d",
                       dt.day, dt.mon, dt.year, dt.hour, dt.min, dt.sec);
  }

bool ParseNewsDateDmY(string raw, datetime &out)
  {
   out = 0;
   StringTrimLeft(raw);
   StringTrimRight(raw);
   if(raw == "")
      return false;

   string parts[];
   if(StringSplit(raw, ' ', parts) < 2)
      return false;

   string dparts[];
   string tparts[];
   if(StringSplit(parts[0], '-', dparts) != 3)
      return false;
   if(StringSplit(parts[1], ':', tparts) < 2)
      return false;

   const int day    = (int)StringToInteger(dparts[0]);
   const int month  = (int)StringToInteger(dparts[1]);
   const int year   = (int)StringToInteger(dparts[2]);
   const int hour   = (int)StringToInteger(tparts[0]);
   const int minute = (int)StringToInteger(tparts[1]);
   const int second = (ArraySize(tparts) >= 3) ? (int)StringToInteger(tparts[2]) : 0;
   if(year < 1970 || month < 1 || month > 12 || day < 1 || day > 31)
      return false;
   if(hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59)
      return false;

   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year = year;
   dt.mon  = month;
   dt.day  = day;
   dt.hour = hour;
   dt.min  = minute;
   dt.sec  = second;
   out = StructToTime(dt);
   return (out > 0);
  }

string NewsApiUrlEncode(string s)
  {
   StringReplace(s, " ", "%20");
   return s;
  }

string BuildNewsApiUrl(const int page)
  {
   string url = InpNewsApiUrl;
   const string q = "page=" + IntegerToString(MathMax(page, 1))
                    + "&from=" + NewsApiUrlEncode(FormatNewsDateDmY(InpNewsBackfillFrom));
   if(StringFind(url, "?") >= 0)
      url += "&" + q;
   else
      url += "?" + q;
   return url;
  }

int FindNewsJsonArrayStart(const string json)
  {
   int key = StringFind(json, "\"data\"");
   if(key < 0)
      key = StringFind(json, "\"news\"");
   int start = -1;
   if(key >= 0)
      start = StringFind(json, "[", key);
   if(start < 0)
      start = StringFind(json, "[");
   return start;
  }

bool ExtractJsonStringField(const string obj, const string key, string &out)
  {
   out = "";
   const string needle = "\"" + key + "\"";
   const int k = StringFind(obj, needle);
   if(k < 0)
      return false;
   const int colon = StringFind(obj, ":", k + StringLen(needle));
   if(colon < 0)
      return false;

   const int n = StringLen(obj);
   int i = colon + 1;
   while(i < n)
     {
      const ushort c = (ushort)StringGetCharacter(obj, i);
      if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
        {
         i++;
         continue;
        }
      if(c != '"')
         return false;

      i++;
      string cur = "";
      bool   esc = false;
      for(; i < n; i++)
        {
         const ushort ch = (ushort)StringGetCharacter(obj, i);
         if(esc)
           {
            cur += ShortToString(ch);
            esc = false;
            continue;
           }
         if(ch == '\\')
           {
            esc = true;
            continue;
           }
         if(ch == '"')
           {
            out = cur;
            return true;
           }
         cur += ShortToString(ch);
        }
      return false;
     }
   return false;
  }

void ExtractJsonObjects(const string json, const int arrayStart, string &objs[])
  {
   ArrayResize(objs, 0);
   const int n = StringLen(json);
   int  depth    = 0;
   int  objStart = -1;
   bool inStr    = false;
   bool esc      = false;

   for(int i = arrayStart; i < n; i++)
     {
      const ushort c = (ushort)StringGetCharacter(json, i);
      if(esc)
        {
         esc = false;
         continue;
        }
      if(c == '\\' && inStr)
        {
         esc = true;
         continue;
        }
      if(c == '"')
        {
         inStr = !inStr;
         continue;
        }
      if(inStr)
         continue;
      if(c == '{')
        {
         if(depth == 0)
            objStart = i;
         depth++;
        }
      else if(c == '}')
        {
         depth--;
         if(depth == 0 && objStart >= 0)
           {
            const int k = ArraySize(objs);
            ArrayResize(objs, k + 1);
            objs[k] = StringSubstr(json, objStart, i - objStart + 1);
            objStart = -1;
           }
        }
      else if(c == ']' && depth == 0)
         break;
     }
  }

void LogNewsBadItemOnce(const string detail)
  {
   if(g_newsBadItemLogged)
      return;
   g_newsBadItemLogged = true;
   Print("News API: malformed item skipped (logged once): ", detail);
  }

int ParseNewsJsonObjects(const string json, NewsItem &out[])
  {
   ArrayResize(out, 0);
   const int start = FindNewsJsonArrayStart(json);
   if(start < 0)
      return -1;

   string objs[];
   ExtractJsonObjects(json, start, objs);
   const int nObj = ArraySize(objs);
   for(int i = 0; i < nObj; i++)
     {
      string dateRaw = "";
      string sigRaw  = "";
      if(!ExtractJsonStringField(objs[i], "date", dateRaw) ||
         !ExtractJsonStringField(objs[i], "signal", sigRaw))
        {
         LogNewsBadItemOnce("missing date/signal in " + StringSubstr(objs[i], 0, 80));
         continue;
        }

      datetime when = 0;
      if(!ParseNewsDateDmY(dateRaw, when))
        {
         LogNewsBadItemOnce("bad date '" + dateRaw + "'");
         continue;
        }

      const ENUM_NEWS_SENT sent = ParseNewsSentiment(sigRaw);
      if(sent == NEWS_SENT_NONE)
        {
         LogNewsBadItemOnce("unknown signal '" + sigRaw + "'");
         continue;
        }

      const int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k].when      = when;
      out[k].sent      = sent;
      out[k].signalRaw = sigRaw;
     }
   return ArraySize(out);
  }

void SortNewsItemsByDate(NewsItem &items[])
  {
   const int n = ArraySize(items);
   for(int i = 1; i < n; i++)
     {
      NewsItem key = items[i];
      int j = i - 1;
      while(j >= 0 && items[j].when > key.when)
        {
         items[j + 1] = items[j];
         j--;
        }
      items[j + 1] = key;
     }
  }

bool NewsItemExists(const NewsItem &items[], const NewsItem &item)
  {
   const int n = ArraySize(items);
   for(int i = 0; i < n; i++)
     {
      if(items[i].when == item.when && items[i].sent == item.sent)
         return true;
     }
   return false;
  }

void AppendNewsItemUnique(NewsItem &dest[], const NewsItem &item)
  {
   if(NewsItemExists(dest, item))
      return;
   const int k = ArraySize(dest);
   ArrayResize(dest, k + 1);
   dest[k] = item;
  }

void AppendNewsItemsUnique(NewsItem &dest[], const NewsItem &src[])
  {
   const int n = ArraySize(src);
   for(int i = 0; i < n; i++)
      AppendNewsItemUnique(dest, src[i]);
  }

void ClearNewsTradeBias()
  {
   g_newsLastActionable = NEWS_SENT_NONE;
   g_newsLiveBiasArmed  = false;
   g_newsStrong         = false;
   g_newsStrongBarsLeft = 0;
   g_newsFlipLotPending = false;
  }

void ResetNewsState()
  {
   g_newsBackfillDone      = false;
   g_newsLastProcessedTime = 0;
   g_newsLastSignal        = "";
   g_newsLastError         = "";
   g_newsPrintedError      = "";
   g_newsBadItemLogged     = false;
   ClearNewsTradeBias();
   g_newsStatus            = InpUseNewsApi ? "waiting" : "OFF";
  }

void ClosePositionsAgainstNews(const ENUM_NEWS_SENT newDir)
  {
   const bool closeBuys  = (newDir == NEWS_SENT_NEGATIVE);
   const bool closeSells = (newDir == NEWS_SENT_POSITIVE);
   if(!closeBuys && !closeSells)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;

      const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const bool against = ((closeBuys && type == POSITION_TYPE_BUY) ||
                            (closeSells && type == POSITION_TYPE_SELL));
      if(!against)
         continue;

      if(!g_trade.PositionClose(ticket))
         Print("News-flip close failed: ", g_trade.ResultRetcode(), " ",
               g_trade.ResultRetcodeDescription(), " ticket=", ticket);
      else
        {
         Print("Position closed: news flip ticket=", ticket,
               " type=", EnumToString(type),
               " news=", NewsSentimentText(newDir));
         RemoveHoldByTicket(ticket);
        }
     }

   if(closeBuys)
      DropSwapParksOfType(POSITION_TYPE_BUY, "news flip");
   if(closeSells)
      DropSwapParksOfType(POSITION_TYPE_SELL, "news flip");

   if(!HasAnyOurPosition() && !HasSwapParkExposure())
      ResetCampaign();
  }

void ApplyActionableNews(const ENUM_NEWS_SENT sent, const string raw, const bool executeTrades)
  {
   if(sent != NEWS_SENT_POSITIVE && sent != NEWS_SENT_NEGATIVE)
      return;

   const bool isFlip = (g_newsLastActionable != NEWS_SENT_NONE &&
                        g_newsLastActionable != sent);

   g_newsLastActionable = sent;
   g_newsLastSignal     = raw;

   if(!executeTrades)
     {
      // Backfill: remember last direction for later live flips, do NOT arm blocks.
      g_newsLiveBiasArmed  = false;
      g_newsStrong         = false;
      g_newsStrongBarsLeft = 0;
      g_newsFlipLotPending = false;
      g_newsStatus = "last=" + raw + " | memory";
      return;
     }

   g_newsLiveBiasArmed = true;

   if(isFlip)
     {
      ClosePositionsAgainstNews(sent);
      g_newsStrong         = true;
      g_newsStrongBarsLeft = NEWS_STRONG_BARS;
      g_newsFlipLotPending = true;
      g_newsStatus = "last=" + raw + " | FLIP-STRONG";
      Print("News FLIP-STRONG: ", NewsSentimentText(sent),
            " close-against + bias window ", NEWS_STRONG_BARS, " bars",
            " lotMult=", DoubleToString(g_newsFlipLotMult, 2));
     }
   else
     {
      g_newsStrong         = false;
      g_newsStrongBarsLeft = 0;
      g_newsStatus = "last=" + raw + " | mild";
      Print("News mild bias: ", NewsSentimentText(sent),
            " (block opposite opens)");
     }
  }

void ProcessNewsItemsChrono(NewsItem &items[], const bool executeTrades)
  {
   SortNewsItemsByDate(items);
   const int n = ArraySize(items);
   const datetime cutoff = executeTrades ? g_newsLastProcessedTime : (datetime)0;
   datetime maxSeen = g_newsLastProcessedTime;
   int applied = 0;

   for(int i = 0; i < n; i++)
     {
      if(items[i].when < InpNewsBackfillFrom)
         continue;
      if(executeTrades && items[i].when <= cutoff)
         continue;

      g_newsLastSignal = items[i].signalRaw;
      if(items[i].sent == NEWS_SENT_NEUTRAL)
        {
         // Neutral does not change last actionable.
        }
      else if(items[i].sent == NEWS_SENT_POSITIVE || items[i].sent == NEWS_SENT_NEGATIVE)
         ApplyActionableNews(items[i].sent, items[i].signalRaw, executeTrades);

      if(items[i].when > maxSeen)
         maxSeen = items[i].when;
      applied++;
     }

   if(maxSeen > g_newsLastProcessedTime)
      g_newsLastProcessedTime = maxSeen;

   if(!executeTrades)
     {
      if(applied <= 0 && g_newsLastProcessedTime <= 0)
         g_newsLastProcessedTime = TimeCurrent();
      g_newsBackfillDone = true;
      g_newsStatus = "last=" + (g_newsLastSignal == "" ? "none" : g_newsLastSignal);
      if(g_newsLastActionable != NEWS_SENT_NONE)
         g_newsStatus += " | memory (no block)";
      Print("News API backfill done: used=", applied,
            " last=", (g_newsLastSignal == "" ? "none" : g_newsLastSignal),
            " actionable=", NewsSentimentText(g_newsLastActionable),
            " liveBias=OFF",
            " lastTime=", TimeToString(g_newsLastProcessedTime, TIME_DATE|TIME_SECONDS));
      return;
     }

   if(applied <= 0)
      return;

   if(g_newsStrong && g_newsStrongBarsLeft > 0)
      g_newsStatus = "last=" + g_newsLastSignal + " | FLIP-STRONG";
   else if(g_newsLastActionable != NEWS_SENT_NONE && StringFind(g_newsStatus, "FLIP-STRONG") < 0)
      g_newsStatus = "last=" + g_newsLastSignal + " | mild";
   else if(g_newsLastSignal != "" && g_newsLastActionable == NEWS_SENT_NONE)
      g_newsStatus = "last=" + g_newsLastSignal;
  }

bool FetchNewsHttp(const int page, string &body)
  {
   body = "";
   if(InpNewsApiUrl == "")
     {
      g_newsLastError = "URL empty";
      g_newsStatus = "error URL empty";
      return false;
     }

   string headers = "";
   if(InpNewsApiToken != "")
      headers = "Authorization: Bearer " + InpNewsApiToken + "\r\n";

   char   data[];
   char   result[];
   string resultHeaders;
   ArrayResize(data, 0);

   const string url = BuildNewsApiUrl(page);
   ResetLastError();
   const int http = WebRequest("GET", url, headers, NEWS_HTTP_TIMEOUT_MS,
                               data, result, resultHeaders);
   if(http == -1)
     {
      const int err = GetLastError();
      g_newsLastError = IntegerToString(err);
      if(err == 4060)
         g_newsStatus = "error 4060 URL not allowed";
      else
         g_newsStatus = "error " + IntegerToString(err);
      if(g_newsPrintedError != g_newsLastError)
        {
         Print("News API WebRequest failed: error=", err,
               " (401/404/4060 URL not allowed). Keeping last bias.");
         g_newsPrintedError = g_newsLastError;
        }
      return false;
     }

   if(http != 200)
     {
      g_newsLastError = "HTTP " + IntegerToString(http);
      g_newsStatus = "error HTTP " + IntegerToString(http);
      if(g_newsPrintedError != g_newsLastError)
        {
         Print("News API HTTP ", http, " — keeping last bias.");
         g_newsPrintedError = g_newsLastError;
        }
      return false;
     }

   g_newsLastError    = "";
   g_newsPrintedError = "";
   body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
  }

bool ParseNewsPageOrFail(const string body, NewsItem &items[])
  {
   ArrayResize(items, 0);
   const int parsed = ParseNewsJsonObjects(body, items);
   if(parsed < 0)
     {
      g_newsStatus = "error bad JSON";
      if(g_newsPrintedError != "bad JSON")
        {
         Print("News API: cannot parse JSON array. Body starts: ",
               StringSubstr(body, 0, 80));
         g_newsPrintedError = "bad JSON";
        }
      return false;
     }
   return true;
  }

void BackfillNewsHistory()
  {
   NewsItem collected[];
   ArrayResize(collected, 0);
   g_newsStatus = "backfill";

   for(int page = 1; page <= NEWS_MAX_PAGES; page++)
     {
      string body = "";
      if(!FetchNewsHttp(page, body))
         return;

      NewsItem pageItems[];
      if(!ParseNewsPageOrFail(body, pageItems))
         return;

      const int n = ArraySize(pageItems);
      if(n <= 0)
        {
         Print("News API backfill: empty page ", page, " — stop");
         break;
        }

      int kept = 0;
      for(int i = 0; i < n; i++)
        {
         if(pageItems[i].when < InpNewsBackfillFrom)
            continue;
         AppendNewsItemUnique(collected, pageItems[i]);
         kept++;
        }
      Print("News API backfill page ", page, " raw=", n, " kept>=from=", kept);

      if(page == NEWS_MAX_PAGES)
         Print("News API backfill stopped at max pages ", NEWS_MAX_PAGES);
     }

   ProcessNewsItemsChrono(collected, false);
  }

void PollNewsApiLive()
  {
   NewsItem collected[];
   ArrayResize(collected, 0);
   bool overlap = false;

   for(int page = 1; page <= NEWS_MAX_PAGES && !overlap; page++)
     {
      string body = "";
      if(!FetchNewsHttp(page, body))
         return;

      NewsItem pageItems[];
      if(!ParseNewsPageOrFail(body, pageItems))
         return;

      const int n = ArraySize(pageItems);
      if(n <= 0)
        {
         if(page == 1)
            return;
         break;
        }

      AppendNewsItemsUnique(collected, pageItems);
      for(int i = 0; i < n; i++)
        {
         if(pageItems[i].when <= g_newsLastProcessedTime)
           {
            overlap = true;
            break;
           }
        }
     }

   ProcessNewsItemsChrono(collected, true);
  }

void PollNewsApi()
  {
   if(!InpUseNewsApi)
      return;
   if(!g_newsBackfillDone)
     {
      BackfillNewsHistory();
      return;
     }
   PollNewsApiLive();
  }

bool NewsBlocksBuy()
  {
   if(!InpUseNewsApi)
      return false;
   if(!g_newsLiveBiasArmed)
      return false;
   return (g_newsLastActionable == NEWS_SENT_NEGATIVE);
  }

bool NewsBlocksSell()
  {
   if(!InpUseNewsApi)
      return false;
   if(!g_newsLiveBiasArmed)
      return false;
   return (g_newsLastActionable == NEWS_SENT_POSITIVE);
  }

bool NewsStrongBuyOk()
  {
   return (InpUseNewsApi && g_newsLiveBiasArmed && g_newsStrong &&
           g_newsStrongBarsLeft > 0 &&
           g_newsLastActionable == NEWS_SENT_POSITIVE);
  }

bool NewsStrongSellOk()
  {
   return (InpUseNewsApi && g_newsLiveBiasArmed && g_newsStrong &&
           g_newsStrongBarsLeft > 0 &&
           g_newsLastActionable == NEWS_SENT_NEGATIVE);
  }

void DecayNewsStrongWindow()
  {
   if(!g_newsStrong)
      return;
   if(g_newsStrongBarsLeft > 0)
      g_newsStrongBarsLeft--;
   if(g_newsStrongBarsLeft <= 0)
     {
      g_newsStrong = false;
      if(g_newsLastActionable != NEWS_SENT_NONE)
         g_newsStatus = "last=" + g_newsLastSignal + " | mild";
     }
  }

string NewsCommentLine()
  {
   if(!InpUseNewsApi)
      return "News API: OFF (no bias)";
   if(g_newsLastError != "")
      return ("News API: " + g_newsStatus);
   if(g_newsStrong && g_newsStrongBarsLeft > 0)
      return ("News API: last=" + (g_newsLastSignal == "" ? "none" : g_newsLastSignal)
              + " | FLIP-STRONG (" + IntegerToString(g_newsStrongBarsLeft) + " bars)");
   if(!g_newsLiveBiasArmed && g_newsLastActionable != NEWS_SENT_NONE)
      return ("News API: last=" + (g_newsLastSignal == "" ? "none" : g_newsLastSignal)
              + " | memory (no block)");
   return ("News API: " + g_newsStatus);
  }

double LotsForNextOpen()
  {
   double lots = InpLots;
   if(g_newsFlipLotPending && g_newsFlipLotMult > 1.0)
      lots *= g_newsFlipLotMult;
   return NormalizeVolume(lots);
  }

void ConsumeNewsFlipLotIfOpened()
  {
   if(g_newsFlipLotPending)
     {
      g_newsFlipLotPending = false;
      Print("News flip lot multiplier consumed");
     }
  }

ENUM_SIGNAL_SRC DetectOscillatorSignal();
ENUM_SIGNAL_SRC DetectRsiTrendSignal();
ENUM_SIGNAL_SRC DetectStochTrendSignal();
bool            CopyRsi();
bool            CopyStoch();
bool            CopyActiveOscillator();
bool            CreateStochHandle();
bool            CreateRsiHandle();
void            LogOscCopyFailOnce(const string which);
double          ClosedOscValue();
double          OscOverboughtLevel();
double          OscOversoldLevel();
bool            OscClosedAtHighExtreme();
bool            OscClosedAtLowExtreme();
void            InferOpenExtremes(const datetime openTime, bool &atHigh, bool &atLow);
void            ManageOppositeExtremeExits();
void            MarkHoldTicketsExtreme(const ENUM_POSITION_TYPE type, const bool high);
bool            HasOurPosition(const ENUM_POSITION_TYPE type);
bool            OscTouchedLevelSince(const datetime openTime, const bool wantHigh);
void            ManageTripleSwapAvoidance();

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEmaFast < 1 || InpEmaSlow < 1 || InpAdxPeriod < 1)
     {
      Print("Nieprawidlowe okresy wskaznikow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpEmaFast >= InpEmaSlow)
     {
      Print("EMA Fast musi byc mniejsza niz Slow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!UseRsiOscillator())
     {
      if(InpStochKPeriod < 1 || InpStochDPeriod < 1 || InpStochSlowing < 1)
        {
         Print("Nieprawidlowe okresy Stochastic.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpStochOversold >= InpStochOverbought)
        {
         Print("Wyprzedanie Stochastic musi byc < wykupienia.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpStochOversold < 0.0 || InpStochOverbought > 100.0)
        {
         Print("Poziomy Stochastic musza byc w 0..100.");
         return INIT_PARAMETERS_INCORRECT;
        }
     }
   else
     {
      if(InpRsiPeriod < 1)
        {
         Print("Nieprawidlowy okres RSI.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpRsiOversold >= InpRsiOverbought)
        {
         Print("Wyprzedanie RSI musi byc < wykupienia.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpRsiOversold < 0.0 || InpRsiOverbought > 100.0)
        {
         Print("Poziomy RSI musza byc w 0..100.");
         return INIT_PARAMETERS_INCORRECT;
        }
     }
   if(InpMaxBarsHold < 1)
     {
      Print("MaxBarsHold musi byc >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpAdxMinLevel < 0.0 || InpAdxMinLevel > 100.0)
     {
      Print("ADX min musi byc w 0..100.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTradeCooldownBars < 0 || InpAddEveryBars < 0)
     {
      Print("Cooldown i AddEveryBars musza byc >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpStopLossPoints < 1 || InpTakeProfitPoints < 1)
     {
      Print("SL/TP w punktach musza byc >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!IsValidHour(InpSession1StartHour) || !IsValidHour(InpSession1EndHour) ||
      !IsValidHour(InpSession2StartHour) || !IsValidHour(InpSession2EndHour))
     {
      Print("Session hours must be 0-23.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_maxPositions = InpMaxPositions;
   if(g_maxPositions < 1)
     {
      Print("InpMaxPositions < 1 — ustawiam 1.");
      g_maxPositions = 1;
     }
   if(g_maxPositions > HOLD_MAX_POSITIONS_CAP)
     {
      Print("InpMaxPositions > ", HOLD_MAX_POSITIONS_CAP,
            " — ustawiam ", HOLD_MAX_POSITIONS_CAP, ".");
      g_maxPositions = HOLD_MAX_POSITIONS_CAP;
     }

   const ENUM_TIMEFRAMES tf = SignalTF();

   CreateStochHandle();
   CreateRsiHandle();
   g_emaFastHandle = iMA(_Symbol, tf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, tf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_adxHandle     = iADX(_Symbol, tf, InpAdxPeriod);

   const bool oscOk = UseRsiOscillator()
                      ? (g_rsiHandle != INVALID_HANDLE)
                      : (g_stochHandle != INVALID_HANDLE);
   if(!oscOk || g_emaFastHandle == INVALID_HANDLE ||
      g_emaSlowHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE)
     {
      Print("Nie udalo sie utworzyc wskaznikow. Error: ", GetLastError(),
            " osc=", OscillatorName(),
            " stochH=", g_stochHandle, " rsiH=", g_rsiHandle);
      return INIT_FAILED;
     }
   if(UseRsiOscillator() && g_stochHandle == INVALID_HANDLE)
      Print("WARNING: Stochastic handle invalid (RSI mode still runs).");
   if(!UseRsiOscillator() && g_rsiHandle == INVALID_HANDLE)
      Print("WARNING: RSI handle invalid (Stoch mode still runs).");

   ArraySetAsSeries(g_stochK, true);
   ArraySetAsSeries(g_stochD, true);
   ArraySetAsSeries(g_rsi, true);
   ArraySetAsSeries(g_emaFast, true);
   ArraySetAsSeries(g_emaSlow, true);
   ArraySetAsSeries(g_adxMain, true);
   ArraySetAsSeries(g_adxPlusDi, true);
   ArraySetAsSeries(g_adxMinusDi, true);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(HARD_SLIPPAGE);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_lastBarTime           = 0;
   g_tradeCooldownBarsLeft = 0;
   g_tradedThisBar         = false;
   g_activeSource          = "none";
   g_blockReason           = "";
   g_signalKind            = "none";
   g_newsFlipLotMult       = (InpNewsFlipLotMult > 0.0) ? InpNewsFlipLotMult : 1.5;
   ResetNewsState();
   ResetCampaign();
   ArrayResize(g_holdTickets, 0);
   ArrayResize(g_holdBarsHeld, 0);
   ArrayResize(g_holdOpenTime, 0);
   ArrayResize(g_holdOpenedAtHigh, 0);
   ArrayResize(g_holdOpenedAtLow, 0);
   RebuildHoldTracking();
   SyncCampaignFromPositions();
   LoadSwapParks();
   g_lastBarTime = iTime(_Symbol, SignalTF(), 0);

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("WARNING: AutoTrading w terminalu wylaczone.");
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("WARNING: EA trading wylaczone (Allow Algo Trading).");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      Print("WARNING: Konto nie pozwala na handel EA.");

   const int    d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   Print("Stochastic_Trend v1.93 | TF=", EnumToString(tf),
         " | osc=", OscillatorName(), " raw=", IntegerToString((int)InpOscillator),
         (UseRsiOscillator()
          ? (" period=" + IntegerToString(InpRsiPeriod)
             + " applied=" + EnumToString(InpRsiApplied)
             + " OS/OB=" + DoubleToString(InpRsiOversold, 0) + "/"
             + DoubleToString(InpRsiOverbought, 0))
          : (" K/D/S=" + IntegerToString(InpStochKPeriod) + "/"
             + IntegerToString(InpStochDPeriod) + "/" + IntegerToString(InpStochSlowing)
             + " price=" + EnumToString(InpStochPriceField)
             + " OS/OB=" + DoubleToString(InpStochOversold, 0) + "/"
             + DoubleToString(InpStochOverbought, 0))),
         " extreme=", InpStochRequireExtreme,
         " | EMA", InpEmaFast, "/", InpEmaSlow,
         " | ADX filter=", InpUseAdxFilter,
         " min=", DoubleToString(InpAdxMinLevel, 1),
         " | cooldown ", EffectiveTradeCooldownBars(), " bars",
         " | dokup co ", EffectiveAddEveryBars(), " bars",
         " | maxHold ", EffectiveMaxBarsHold(), " bars",
         " | oppositeExtreme=", InpCloseOnOppositeExtreme,
         " | maxPos ", EffectiveMaxPositions(),
         " | lot=", DoubleToString(NormalizeVolume(InpLots), 2),
         " | SL/TP pts ", InpStopLossPoints, "/", InpTakeProfitPoints,
         " | session=", (InpUseSessionFilter ? SessionStatusText() : "OFF"),
         " | tripleSwap=", TripleSwapStatusText());
   if(UseRsiOscillator())
      Print("Wejscie RSI: zamkniety bar [1] vs [2], NIE formujacy [0]. ",
            InpStochRequireExtreme
            ? "Extreme ON: BUY wychodzi z OS ([3]/[2] w strefie, [1] powyzej i rosnie), SELL wychodzi z OB (z trendem EMA)."
            : "Extreme OFF: BUY crossover 50, SELL crossunder 50 (z trendem EMA).");
   else
      Print("Wejscie Stoch: zamkniety bar [1] vs [2], NIE formujacy [0]. Wykres Stochastic musi miec te same K/D/S + ",
            EnumToString(InpStochPriceField), " (MT5 default=Low/High). Extreme=",
            InpStochRequireExtreme ? "ON (OS/OB)" : "OFF (kazdy K/D z EMA).");
   if(InpStochRequireExtreme)
      Print("WARNING: InpStochRequireExtreme=true — poza OS/OB sygnal jest odrzucany (Stoch i RSI). MT5 czesto pamieta stary set.");
   if(InpCloseOnOppositeExtreme)
      Print("Opposite extreme flatten ON: while BUY(s) open, osc hitting OB latches; later [1]<=OS flattens ALL. ",
            "SELL latch at OS then [1]>=OB same. Independent of RequireExtreme/ADX (entries can be at OS in uptrend). OS/OB=",
            DoubleToString(OscOversoldLevel(), 0), "/", DoubleToString(OscOverboughtLevel(), 0),
            ". 1 close per ticket. MaxBarsHold + EMA-flip remain.");
   if(InpUseAdxFilter)
      Print("WARNING: ADX filter ON (min=", DoubleToString(InpAdxMinLevel, 1),
            ") — slaby ADX zablokuje oscylator w trendzie EMA. Wylacz, zeby kazdy cross w EMA otwieral.");
   Print("US30 SL/TP hint: Digits=", d, " point=", DoubleToString(p, d),
         " => SL≈", DoubleToString((double)InpStopLossPoints * p, d),
         " TP≈", DoubleToString((double)InpTakeProfitPoints * p, d),
         " index. Digits=2: 5000/10000; Digits=1: 500/1000; Digits=0: 50/100.");

   if(InpAvoidTripleSwap)
      Print("Triple-swap avoid ON (FX): close 1h before ",
            TripleSwapDowName(TripleSwapRolloverDow()),
            " rollover ", TimeToString(TripleSwapChargeTime(BrokerTimeNow()), TIME_DATE|TIME_MINUTES),
            " and reopen next day if EMA trend + MaxBarsHold still valid.");

   int timerSec = 0;
   if(InpUseNewsApi)
     {
      if(InpNewsApiUrl == "")
         Print("WARNING: InpUseNewsApi=true but InpNewsApiUrl is empty — no WebRequest.");
      Print("News API ON | poll=", MathMax(InpNewsPollSeconds, 1), "s",
            " | flipLotMult=", DoubleToString(g_newsFlipLotMult, 2));
      Print("News API whitelist URL: ", InpNewsApiUrl);
      Print("News API backfill from ", TimeToString(InpNewsBackfillFrom, TIME_DATE|TIME_SECONDS),
            " | pagination: page (1-based) + from (d-m-Y H:i:s)");
      Print("MT5: add the News API URL in Tools → Options → Expert Advisors → Allow WebRequest for listed URL.");
      timerSec = MathMax(InpNewsPollSeconds, 1);
      PollNewsApi();
     }
   else
     {
      ClearNewsTradeBias();
      Print("News API OFF (InpUseNewsApi=false) — no WebRequest, no news bias, opens not blocked.");
     }
   if(TripleSwapFeatureOn())
      timerSec = (timerSec > 0) ? MathMin(timerSec, 30) : 30;
   if(timerSec > 0)
      EventSetTimer(timerSec);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_stochHandle   != INVALID_HANDLE) IndicatorRelease(g_stochHandle);
   if(g_rsiHandle     != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   if(g_adxHandle     != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(InpUseNewsApi)
      PollNewsApi();
   if(TripleSwapFeatureOn())
      ManageTripleSwapAvoidance();
   if(InpShowComments)
      UpdateComment(SIGNAL_NONE, IsTradeLocked());
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!InpUseNewsApi)
      ClearNewsTradeBias();

   const bool newBar = CheckNewBar();
   if(newBar)
     {
      g_tradedThisBar = false;
      g_blockReason   = "";
     }

   ManageTripleSwapAvoidance();

   if(!newBar)
     {
      PruneClosedHolds();
      if(InpShowComments)
         UpdateComment(SIGNAL_NONE, IsTradeLocked());
      return;
     }

   ManageMaxBarHoldExits();
   ManageTrendChangeExits();
   ManageOppositeExtremeExits();

   ENUM_SIGNAL_SRC signal = DetectOscillatorSignal();
   const bool locked = IsTradeLocked();

   if(signal != SIGNAL_NONE)
     {
      if(locked)
         Print((UseRsiOscillator() ? "RSI CROSS" : "K/D CROSS"),
               " ignored (locked): ", g_blockReason,
               " signal=", EnumToString(signal));
      else
         ExecuteSignal(signal);
     }
   else if(!locked)
      signal = TryNewsForcedEntry();

   if(!g_tradedThisBar)
      ManagePyramidAdds();

   if(g_tradeCooldownBarsLeft > 0 && !g_tradedThisBar)
      g_tradeCooldownBarsLeft--;

   DecayNewsStrongWindow();
   UpdateComment(signal, locked);
  }

//+------------------------------------------------------------------+
bool IsTradeLocked()
  {
   if(g_tradedThisBar)
     {
      g_blockReason = "juz otwarto na tym barze";
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
      g_blockReason = "cooldown (" + IntegerToString(g_tradeCooldownBarsLeft) + " left)";
      return true;
     }
   const int openCount = CountOurPositions();
   if(openCount >= EffectiveMaxPositions())
     {
      g_blockReason = "max pozycji (" + IntegerToString(openCount)
                      + "/" + IntegerToString(EffectiveMaxPositions()) + ")";
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
ENUM_TREND_DIR RawEmaTrend()
  {
   if(!CopyTrend())
      return TREND_FLAT;
   const double fast = g_emaFast[1];
   const double slow = g_emaSlow[1];
   if(fast > slow)
      return TREND_UP;
   if(fast < slow)
      return TREND_DOWN;
   return TREND_FLAT;
  }

//+------------------------------------------------------------------+
ENUM_TREND_DIR CurrentTrend()
  {
   return RawEmaTrend();
  }

void LogKdReject(const string why,
                 const double kPrev, const double dPrev,
                 const double kCurr, const double dCurr,
                 const ENUM_TREND_DIR trend)
  {
   g_blockReason = why;
   Print("K/D CROSS rejected: ", why,
         " | closed[2] K=", DoubleToString(kPrev, 2), " D=", DoubleToString(dPrev, 2),
         " -> [1] K=", DoubleToString(kCurr, 2), " D=", DoubleToString(dCurr, 2),
         " | EMA=", EnumToString(trend),
         " | extreme=", InpStochRequireExtreme,
         " | TF=", EnumToString(SignalTF()),
         " | price=", EnumToString(InpStochPriceField));
  }

void LogRsiReject(const string why,
                  const double rsiPrev, const double rsiCurr,
                  const ENUM_TREND_DIR trend)
  {
   g_blockReason = why;
   Print("RSI CROSS rejected: ", why,
         " | closed[3] RSI=", DoubleToString(g_rsi[3], 2),
         " [2]=", DoubleToString(rsiPrev, 2),
         " -> [1] RSI=", DoubleToString(rsiCurr, 2),
         " | EMA=", EnumToString(trend),
         " | extreme=", InpStochRequireExtreme,
         " | OS/OB=", DoubleToString(InpRsiOversold, 0), "/",
         DoubleToString(InpRsiOverbought, 0),
         " | TF=", EnumToString(SignalTF()));
  }

//+------------------------------------------------------------------+
ENUM_SIGNAL_SRC DetectOscillatorSignal()
  {
   if(UseRsiOscillator())
      return DetectRsiTrendSignal();
   return DetectStochTrendSignal();
  }

//+------------------------------------------------------------------+
ENUM_SIGNAL_SRC DetectRsiTrendSignal()
  {
   if(!CopyRsi())
     {
      g_blockReason = "RSI CopyBuffer fail";
      LogOscCopyFailOnce("RSI");
      return SIGNAL_NONE;
     }

   const ENUM_TREND_DIR trend = CurrentTrend();
   const double rsiOlder = g_rsi[3];
   const double rsiPrev  = g_rsi[2];
   const double rsiCurr  = g_rsi[1];

   bool crossUp   = false;
   bool crossDown = false;
   if(InpStochRequireExtreme)
     {
      // Leave OS/OB: zone on closed [2] or [3], [1] already outside and still
      // rising (BUY) / falling (SELL). One-bar [2]->[1] miss if RSI gapped
      // through the line or the exact leave bar was blocked (cooldown/ADX).
      const bool wasOversold   = (MathMin(rsiPrev, rsiOlder) <= InpRsiOversold);
      const bool wasOverbought = (MathMax(rsiPrev, rsiOlder) >= InpRsiOverbought);
      crossUp   = (wasOversold && rsiCurr > InpRsiOversold && rsiCurr > rsiPrev);
      crossDown = (wasOverbought && rsiCurr < InpRsiOverbought && rsiCurr < rsiPrev);
     }
   else
     {
      crossUp   = (rsiPrev <= RSI_MID_LEVEL && rsiCurr > RSI_MID_LEVEL);
      crossDown = (rsiPrev >= RSI_MID_LEVEL && rsiCurr < RSI_MID_LEVEL);
     }

   if(!crossUp && !crossDown)
      return SIGNAL_NONE;

   if(trend == TREND_FLAT)
     {
      LogRsiReject("brak trendu EMA (flat) — RSI cross jest, ale fast==slow",
                   rsiPrev, rsiCurr, trend);
      return SIGNAL_NONE;
     }

   if(crossUp)
     {
      if(trend != TREND_UP)
        {
         LogRsiReject("RSI BUY cross, ale EMA DOWN — tylko SELL w downtrendzie",
                      rsiPrev, rsiCurr, trend);
         return SIGNAL_NONE;
        }
      if(NewsBlocksBuy())
        {
         LogRsiReject("news bias blocks BUY", rsiPrev, rsiCurr, trend);
         return SIGNAL_NONE;
        }
      Print("RSI CROSS accepted: BUY",
            " | closed[3] RSI=", DoubleToString(rsiOlder, 2),
            " [2]=", DoubleToString(rsiPrev, 2),
            " -> [1] RSI=", DoubleToString(rsiCurr, 2),
            " | EMA=", EnumToString(trend),
            " | extreme=", InpStochRequireExtreme);
      return SIGNAL_RSI_BUY;
     }

   if(crossDown)
     {
      if(trend != TREND_DOWN)
        {
         LogRsiReject("RSI SELL cross, ale EMA UP — tylko BUY w uptrendzie",
                      rsiPrev, rsiCurr, trend);
         return SIGNAL_NONE;
        }
      if(NewsBlocksSell())
        {
         LogRsiReject("news bias blocks SELL", rsiPrev, rsiCurr, trend);
         return SIGNAL_NONE;
        }
      Print("RSI CROSS accepted: SELL",
            " | closed[3] RSI=", DoubleToString(rsiOlder, 2),
            " [2]=", DoubleToString(rsiPrev, 2),
            " -> [1] RSI=", DoubleToString(rsiCurr, 2),
            " | EMA=", EnumToString(trend),
            " | extreme=", InpStochRequireExtreme);
      return SIGNAL_RSI_SELL;
     }

   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
ENUM_SIGNAL_SRC DetectStochTrendSignal()
  {
   if(!CopyStoch())
     {
      g_blockReason = "Stoch CopyBuffer fail";
      LogOscCopyFailOnce("Stoch");
      return SIGNAL_NONE;
     }

   const ENUM_TREND_DIR trend = CurrentTrend();
   const double kPrev = g_stochK[2];
   const double kCurr = g_stochK[1];
   const double dPrev = g_stochD[2];
   const double dCurr = g_stochD[1];

   const bool crossUp   = (kPrev <= dPrev && kCurr > dCurr);
   const bool crossDown = (kPrev >= dPrev && kCurr < dCurr);

   if(!crossUp && !crossDown)
      return SIGNAL_NONE;

   if(trend == TREND_FLAT)
     {
      LogKdReject("brak trendu EMA (flat) — K/D jest, ale fast==slow",
                  kPrev, dPrev, kCurr, dCurr, trend);
      return SIGNAL_NONE;
     }

   if(crossUp)
     {
      if(trend != TREND_UP)
        {
         LogKdReject("K/D BUY cross, ale EMA DOWN — tylko SELL w downtrendzie",
                     kPrev, dPrev, kCurr, dCurr, trend);
         return SIGNAL_NONE;
        }
      if(!StochBuyZoneOk(kPrev, kCurr))
        {
         LogKdReject("K/D BUY cross poza OS (" + DoubleToString(InpStochOversold, 0)
                     + ") — InpStochRequireExtreme=true",
                     kPrev, dPrev, kCurr, dCurr, trend);
         return SIGNAL_NONE;
        }
      if(NewsBlocksBuy())
        {
         LogKdReject("news bias blocks BUY", kPrev, dPrev, kCurr, dCurr, trend);
         return SIGNAL_NONE;
        }
      Print("K/D CROSS accepted: BUY",
            " | closed[2] K=", DoubleToString(kPrev, 2), " D=", DoubleToString(dPrev, 2),
            " -> [1] K=", DoubleToString(kCurr, 2), " D=", DoubleToString(dCurr, 2),
            " | EMA=", EnumToString(trend),
            " | extreme=", InpStochRequireExtreme);
      return SIGNAL_STOCH_BUY;
     }

   if(crossDown)
     {
      if(trend != TREND_DOWN)
        {
         LogKdReject("K/D SELL cross, ale EMA UP — tylko BUY w uptrendzie",
                     kPrev, dPrev, kCurr, dCurr, trend);
         return SIGNAL_NONE;
        }
      if(!StochSellZoneOk(kPrev, kCurr))
        {
         LogKdReject("K/D SELL cross poza OB (" + DoubleToString(InpStochOverbought, 0)
                     + ") — InpStochRequireExtreme=true",
                     kPrev, dPrev, kCurr, dCurr, trend);
         return SIGNAL_NONE;
        }
      if(NewsBlocksSell())
        {
         LogKdReject("news bias blocks SELL", kPrev, dPrev, kCurr, dCurr, trend);
         return SIGNAL_NONE;
        }
      Print("K/D CROSS accepted: SELL",
            " | closed[2] K=", DoubleToString(kPrev, 2), " D=", DoubleToString(dPrev, 2),
            " -> [1] K=", DoubleToString(kCurr, 2), " D=", DoubleToString(dCurr, 2),
            " | EMA=", EnumToString(trend),
            " | extreme=", InpStochRequireExtreme);
      return SIGNAL_STOCH_SELL;
     }

   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
bool StochBuyZoneOk(const double kPrev, const double kCurr)
  {
   if(!InpStochRequireExtreme)
      return true;
   return (kPrev <= InpStochOversold || kCurr <= InpStochOversold);
  }

//+------------------------------------------------------------------+
bool StochSellZoneOk(const double kPrev, const double kCurr)
  {
   if(!InpStochRequireExtreme)
      return true;
   return (kPrev >= InpStochOverbought || kCurr >= InpStochOverbought);
  }

//+------------------------------------------------------------------+
void ExecuteSignal(const ENUM_SIGNAL_SRC signal)
  {
   Print("Signal fire: ", EnumToString(signal), " kind=", SignalKindText(signal));
   g_signalKind = SignalKindText(signal);

   const bool isBuy  = IsBuySignal(signal);
   const bool isSell = IsSellSignal(signal);
   const bool newsForced = (signal == SIGNAL_NEWS_BUY || signal == SIGNAL_NEWS_SELL);
   if((isBuy || isSell) && !newsForced && !PassesAdxFilter(isBuy))
     {
      Print("ADX filter blocked ", EnumToString(signal), ": ", g_blockReason);
      return;
     }

   switch(signal)
     {
      case SIGNAL_STOCH_BUY:
         g_activeSource = "KD cross BUY + EMA up";
         OpenBuy("STOCH TREND BUY KD", false);
         break;
      case SIGNAL_STOCH_SELL:
         g_activeSource = "KD cross SELL + EMA down";
         OpenSell("STOCH TREND SELL KD", false);
         break;
      case SIGNAL_RSI_BUY:
         g_activeSource = "RSI cross BUY + EMA up";
         OpenBuy("RSI TREND BUY", false);
         break;
      case SIGNAL_RSI_SELL:
         g_activeSource = "RSI cross SELL + EMA down";
         OpenSell("RSI TREND SELL", false);
         break;
      case SIGNAL_NEWS_BUY:
         g_activeSource = "NEWS flip BUY (Stoch override)";
         OpenBuy("STOCH TREND NEWS BUY", false, true);
         break;
      case SIGNAL_NEWS_SELL:
         g_activeSource = "NEWS flip SELL (Stoch override)";
         OpenSell("STOCH TREND NEWS SELL", false, true);
         break;
      default:
         break;
     }
  }

//+------------------------------------------------------------------+
ENUM_SIGNAL_SRC TryNewsForcedEntry()
  {
   if(!NewsStrongBuyOk() && !NewsStrongSellOk())
      return SIGNAL_NONE;
   if(g_tradedThisBar)
      return SIGNAL_NONE;
   if(CountOurPositions() >= EffectiveMaxPositions())
      return SIGNAL_NONE;

   const ENUM_TREND_DIR ema = CurrentTrend();
   if(NewsStrongBuyOk())
     {
      if(ema == TREND_UP)
         Print("News strong BUY: EMA aligned (preferred)");
      else
         Print("News strong BUY: EMA not aligned — news overrides Stoch");
      ExecuteSignal(SIGNAL_NEWS_BUY);
      return SIGNAL_NEWS_BUY;
     }

   if(NewsStrongSellOk())
     {
      if(ema == TREND_DOWN)
         Print("News strong SELL: EMA aligned (preferred)");
      else
         Print("News strong SELL: EMA not aligned — news overrides Stoch");
      ExecuteSignal(SIGNAL_NEWS_SELL);
      return SIGNAL_NEWS_SELL;
     }
   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
void ManagePyramidAdds()
  {
   const int every = EffectiveAddEveryBars();
   if(every < 1)
      return;
   if(g_tradedThisBar)
      return;

   const ENUM_TREND_DIR trend = CurrentTrend();
   if(trend != TREND_UP && trend != TREND_DOWN)
      return;

   const int openCount = CountOurPositions();
   if(openCount <= 0)
      return;
   if(openCount >= EffectiveMaxPositions())
      return;

   if(g_campaignTrend != TREND_FLAT && g_campaignTrend != trend)
      return;

   if(trend == TREND_UP && !HasOurPosition(POSITION_TYPE_BUY))
      return;
   if(trend == TREND_DOWN && !HasOurPosition(POSITION_TYPE_SELL))
      return;
   if(trend == TREND_UP && NewsBlocksBuy())
     {
      g_blockReason = "news bias blocks dokup BUY";
      return;
     }
   if(trend == TREND_DOWN && NewsBlocksSell())
     {
      g_blockReason = "news bias blocks dokup SELL";
      return;
     }

   if(g_lastAddBarTime == 0)
      SyncCampaignFromPositions();
   if(g_lastAddBarTime == 0)
      return;

   const int barsSince = iBarShift(_Symbol, SignalTF(), g_lastAddBarTime, false);
   if(barsSince < 0 || barsSince < every)
     {
      const int left = (barsSince < 0) ? every : (every - barsSince);
      g_blockReason = "dokup za " + IntegerToString(left) + " bar(ow)";
      return;
     }

   g_signalKind   = "dokup";
   g_activeSource = (trend == TREND_UP) ? "dokup BUY (trend bez zmian)"
                                        : "dokup SELL (trend bez zmian)";
   Print("Pyramid add: trend=", EnumToString(trend),
         " barsSince=", barsSince, " every=", every,
         " open=", openCount, "/", EffectiveMaxPositions());

   if(trend == TREND_UP)
      OpenBuy("STOCH TREND PYRAMID BUY", true);
   else
      OpenSell("STOCH TREND PYRAMID SELL", true);
  }

//+------------------------------------------------------------------+
void ManageTrendChangeExits()
  {
   if(!HasAnyOurPosition())
     {
      if(!HasSwapParkExposure())
         ResetCampaign();
      return;
     }
   if(!CopyTrend())
      return;

   const double fast = g_emaFast[1];
   const double slow = g_emaSlow[1];
   const bool trendDown = (fast < slow);
   const bool trendUp   = (fast > slow);
   if(!trendDown && !trendUp)
      return;

   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;

      const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const bool against = ((type == POSITION_TYPE_BUY && trendDown) ||
                            (type == POSITION_TYPE_SELL && trendUp));
      if(!against)
         continue;

      if(!g_trade.PositionClose(ticket))
         Print("Trend-flip close failed: ", g_trade.ResultRetcode(), " ",
               g_trade.ResultRetcodeDescription(), " ticket=", ticket);
      else
        {
         Print("Position closed: EMA trend flip ticket=", ticket,
               " type=", EnumToString(type),
               " fast=", DoubleToString(fast, digits),
               " slow=", DoubleToString(slow, digits));
         RemoveHoldByTicket(ticket);
        }
     }

   if(!HasAnyOurPosition() && !HasSwapParkExposure())
      ResetCampaign();
   else
      g_campaignTrend = trendUp ? TREND_UP : TREND_DOWN;
  }

//+------------------------------------------------------------------+
bool CopyActiveOscillator()
  {
   return UseRsiOscillator() ? CopyRsi() : CopyStoch();
  }

double OscOverboughtLevel()
  {
   return UseRsiOscillator() ? InpRsiOverbought : InpStochOverbought;
  }

double OscOversoldLevel()
  {
   return UseRsiOscillator() ? InpRsiOversold : InpStochOversold;
  }

double ClosedOscValue()
  {
   return UseRsiOscillator() ? g_rsi[1] : g_stochK[1];
  }

bool OscClosedAtHighExtreme()
  {
   if(!CopyActiveOscillator())
      return false;
   return (ClosedOscValue() >= OscOverboughtLevel());
  }

bool OscClosedAtLowExtreme()
  {
   if(!CopyActiveOscillator())
      return false;
   return (ClosedOscValue() <= OscOversoldLevel());
  }

void InferOpenExtremes(const datetime openTime, bool &atHigh, bool &atLow)
  {
   atHigh = false;
   atLow  = false;
   if(openTime <= 0)
      return;

   const int shift = iBarShift(_Symbol, SignalTF(), openTime, false);
   if(shift < 0)
      return;

   // Open happens on the new bar [0]; the signal used closed [1] = shift+1.
   const int oscShift = shift + 1;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(UseRsiOscillator())
     {
      if(g_rsiHandle == INVALID_HANDLE)
         return;
      if(CopyBuffer(g_rsiHandle, 0, oscShift, 1, buf) < 1)
         return;
      atHigh = (buf[0] >= InpRsiOverbought);
      atLow  = (buf[0] <= InpRsiOversold);
      return;
     }

   if(g_stochHandle == INVALID_HANDLE)
      return;
   if(CopyBuffer(g_stochHandle, 0, oscShift, 1, buf) < 1)
      return;
   atHigh = (buf[0] >= InpStochOverbought);
   atLow  = (buf[0] <= InpStochOversold);
  }

bool OscTouchedLevelSince(const datetime openTime, const bool wantHigh)
  {
   if(openTime <= 0)
      return false;
   int shift = iBarShift(_Symbol, SignalTF(), openTime, false);
   if(shift < 0)
      shift = 0;
   int count = shift + 1;
   if(count < 1)
      count = 1;
   if(count > 500)
      count = 500;

   const int handle = UseRsiOscillator() ? g_rsiHandle : g_stochHandle;
   if(handle == INVALID_HANDLE)
      return false;

   double buf[];
   ArraySetAsSeries(buf, true);
   const int copied = CopyBuffer(handle, 0, 1, count, buf);
   if(copied < 1)
      return false;

   const double level = wantHigh ? OscOverboughtLevel() : OscOversoldLevel();
   for(int i = 0; i < copied; i++)
     {
      if(wantHigh && buf[i] >= level)
         return true;
      if(!wantHigh && buf[i] <= level)
         return true;
     }
   return false;
  }

void CloseAllOurMagicPositions(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;

      const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(!g_trade.PositionClose(ticket))
         Print("Opposite-extreme close failed: ", g_trade.ResultRetcode(), " ",
               g_trade.ResultRetcodeDescription(), " ticket=", ticket);
      else
        {
         Print("Position closed: ", reason, " ticket=", ticket,
               " type=", EnumToString(type));
         RemoveHoldByTicket(ticket);
        }
     }

   if(!HasAnyOurPosition() && !HasSwapParkExposure())
      ResetCampaign();
  }

void MarkHoldTicketsExtreme(const ENUM_POSITION_TYPE type, const bool high)
  {
   const int n = ArraySize(g_holdTickets);
   for(int i = 0; i < n; i++)
     {
      if(!IsOurPositionTicket(g_holdTickets[i]))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;
      if(high)
         g_holdOpenedAtHigh[i] = true;
      else
         g_holdOpenedAtLow[i] = true;
     }
  }

void ManageOppositeExtremeExits()
  {
   if(!InpCloseOnOppositeExtreme)
      return;
   if(!HasAnyOurPosition())
     {
      if(!HasSwapParkExposure())
        {
         g_buysSawOverbought = false;
         g_sellsSawOversold  = false;
        }
      return;
     }
   if(!CopyActiveOscillator())
     {
      LogOscCopyFailOnce(OscillatorName());
      return;
     }

   const double osc     = ClosedOscValue();
   const bool   nowLow  = (osc <= OscOversoldLevel());
   const bool   nowHigh = (osc >= OscOverboughtLevel());
   const bool   hasBuy  = HasOurPosition(POSITION_TYPE_BUY);
   const bool   hasSell = HasOurPosition(POSITION_TYPE_SELL);

   // Latch OB/OS WHILE holding — RequireExtreme+ADX never opens BUY at OB,
   // so fill-time flags alone would never flatten.
   if(hasBuy && nowHigh)
     {
      if(!g_buysSawOverbought)
         Print("Opposite extreme LATCH: open BUY(s) saw ", OscillatorName(),
               " OB [1]=", DoubleToString(osc, 2),
               " (>=", DoubleToString(OscOverboughtLevel(), 0), ")");
      g_buysSawOverbought = true;
      MarkHoldTicketsExtreme(POSITION_TYPE_BUY, true);
     }
   if(hasSell && nowLow)
     {
      if(!g_sellsSawOversold)
         Print("Opposite extreme LATCH: open SELL(s) saw ", OscillatorName(),
               " OS [1]=", DoubleToString(osc, 2),
               " (<=", DoubleToString(OscOversoldLevel(), 0), ")");
      g_sellsSawOversold = true;
      MarkHoldTicketsExtreme(POSITION_TYPE_SELL, false);
     }
   if(!hasBuy)
      g_buysSawOverbought = false;
   if(!hasSell)
      g_sellsSawOversold = false;

   bool hasBuyFromHigh = g_buysSawOverbought;
   bool hasSellFromLow = g_sellsSawOversold;
   const int n = ArraySize(g_holdTickets);
   for(int i = 0; i < n; i++)
     {
      if(!IsOurPositionTicket(g_holdTickets[i]))
         continue;
      const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY && g_holdOpenedAtHigh[i])
         hasBuyFromHigh = true;
      else if(type == POSITION_TYPE_SELL && g_holdOpenedAtLow[i])
         hasSellFromLow = true;
     }

   const bool flattenBuysCrash  = (hasBuy && hasBuyFromHigh && nowLow);
   const bool flattenSellsRally = (hasSell && hasSellFromLow && nowHigh);
   if(!flattenBuysCrash && !flattenSellsRally)
      return;

   if(flattenBuysCrash)
      Print("Opposite extreme: buys saw OB, now OS — flatten all",
            " | ", OscillatorName(), " [1]=", DoubleToString(osc, 2),
            " OS/OB=", DoubleToString(OscOversoldLevel(), 0), "/",
            DoubleToString(OscOverboughtLevel(), 0),
            " | ADX/Extreme do not block this close");
   if(flattenSellsRally)
      Print("Opposite extreme: sells saw OS, now OB — flatten all",
            " | ", OscillatorName(), " [1]=", DoubleToString(osc, 2),
            " OS/OB=", DoubleToString(OscOversoldLevel(), 0), "/",
            DoubleToString(OscOverboughtLevel(), 0),
            " | ADX/Extreme do not block this close");

   CloseAllOurMagicPositions("opposite extreme");
  }

//+------------------------------------------------------------------+
void UpdateComment(const ENUM_SIGNAL_SRC signal, const bool locked)
  {
   if(!InpShowComments)
      return;

   string sigTxt = "none";
   if(signal == SIGNAL_STOCH_BUY)     sigTxt = "STOCH BUY (KD cross)";
   if(signal == SIGNAL_STOCH_SELL)    sigTxt = "STOCH SELL (KD cross)";
   if(signal == SIGNAL_RSI_BUY)       sigTxt = "RSI BUY (cross)";
   if(signal == SIGNAL_RSI_SELL)      sigTxt = "RSI SELL (cross)";
   if(signal == SIGNAL_PYRAMID_BUY)   sigTxt = "DOKUP BUY";
   if(signal == SIGNAL_PYRAMID_SELL)  sigTxt = "DOKUP SELL";
   if(signal == SIGNAL_NEWS_BUY)      sigTxt = "NEWS BUY (flip)";
   if(signal == SIGNAL_NEWS_SELL)     sigTxt = "NEWS SELL (flip)";
   if(signal != SIGNAL_NONE)
      g_signalKind = SignalKindText(signal);

   double kClosed = 0.0, dClosed = 0.0, kForm = 0.0, dForm = 0.0;
   double rsiClosed = 0.0, rsiForm = 0.0;
   double emaF = 0.0, emaS = 0.0;
   double adxNow = 0.0, plusDiNow = 0.0, minusDiNow = 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(g_stochHandle != INVALID_HANDLE)
     {
      if(CopyBuffer(g_stochHandle, 0, 1, 1, buf) >= 1) kClosed = buf[0];
      if(CopyBuffer(g_stochHandle, 1, 1, 1, buf) >= 1) dClosed = buf[0];
      if(CopyBuffer(g_stochHandle, 0, 0, 1, buf) >= 1) kForm = buf[0];
      if(CopyBuffer(g_stochHandle, 1, 0, 1, buf) >= 1) dForm = buf[0];
     }
   if(g_rsiHandle != INVALID_HANDLE)
     {
      if(CopyBuffer(g_rsiHandle, 0, 1, 1, buf) >= 1) rsiClosed = buf[0];
      if(CopyBuffer(g_rsiHandle, 0, 0, 1, buf) >= 1) rsiForm = buf[0];
     }
   if(CopyBuffer(g_emaFastHandle, 0, 1, 1, buf) >= 1) emaF = buf[0];
   if(CopyBuffer(g_emaSlowHandle, 0, 1, 1, buf) >= 1) emaS = buf[0];
   if(g_adxHandle != INVALID_HANDLE)
     {
      if(CopyBuffer(g_adxHandle, 0, 1, 1, buf) >= 1) adxNow = buf[0];
      if(CopyBuffer(g_adxHandle, 1, 1, 1, buf) >= 1) plusDiNow = buf[0];
      if(CopyBuffer(g_adxHandle, 2, 1, 1, buf) >= 1) minusDiNow = buf[0];
     }

   string formCross = "";
   if(UseRsiOscillator())
     {
      if(CopyRsi())
        {
         bool liveUp = false, liveDown = false;
         if(InpStochRequireExtreme)
           {
            liveUp   = (g_rsi[1] <= InpRsiOversold && g_rsi[0] > InpRsiOversold);
            liveDown = (g_rsi[1] >= InpRsiOverbought && g_rsi[0] < InpRsiOverbought);
           }
         else
           {
            liveUp   = (g_rsi[1] <= RSI_MID_LEVEL && g_rsi[0] > RSI_MID_LEVEL);
            liveDown = (g_rsi[1] >= RSI_MID_LEVEL && g_rsi[0] < RSI_MID_LEVEL);
           }
         if(liveUp)
            formCross = " | [0] FORMING RSI cross UP (EA nie handluje do zamkniecia)";
         else if(liveDown)
            formCross = " | [0] FORMING RSI cross DOWN (EA nie handluje do zamkniecia)";
        }
     }
   else if(CopyStoch())
     {
      const bool liveUp   = (g_stochK[1] <= g_stochD[1] && g_stochK[0] > g_stochD[0]);
      const bool liveDown = (g_stochK[1] >= g_stochD[1] && g_stochK[0] < g_stochD[0]);
      if(liveUp)
         formCross = " | [0] FORMING cross UP (EA nie handluje do zamkniecia)";
      else if(liveDown)
         formCross = " | [0] FORMING cross DOWN (EA nie handluje do zamkniecia)";
     }

   string trendTxt = "FLAT";
   if(emaF > emaS)
      trendTxt = "UP";
   else if(emaF < emaS)
      trendTxt = "DOWN";

   string adxTxt = InpUseAdxFilter
                   ? ("ON min=" + DoubleToString(InpAdxMinLevel, 1) + " (bez DI)")
                   : "OFF (nie blokuje)";
   string diMatch = (plusDiNow > minusDiNow) ? "+DI>-DI"
                   : (minusDiNow > plusDiNow) ? "-DI>+DI" : "DI equal";

   const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   string sltpTxt = IntegerToString(InpStopLossPoints) + "/" + IntegerToString(InpTakeProfitPoints)
                    + " pts ≈ " + DoubleToString((double)InpStopLossPoints * point, digits)
                    + "/" + DoubleToString((double)InpTakeProfitPoints * point, digits)
                    + " index";

   int addLeft = 0;
   if(EffectiveAddEveryBars() > 0 && g_lastAddBarTime > 0)
     {
      const int since = iBarShift(_Symbol, SignalTF(), g_lastAddBarTime, false);
      if(since >= 0 && since < EffectiveAddEveryBars())
         addLeft = EffectiveAddEveryBars() - since;
     }

   const bool showBlock = (!locked && g_blockReason != ""
                           && (StringFind(g_blockReason, "ADX") >= 0
                               || StringFind(g_blockReason, "EMA") >= 0
                               || StringFind(g_blockReason, "trend") >= 0
                               || StringFind(g_blockReason, "dokup") >= 0
                               || StringFind(g_blockReason, "news") >= 0
                               || StringFind(g_blockReason, "K/D") >= 0
                               || StringFind(g_blockReason, "RSI") >= 0
                               || StringFind(g_blockReason, "OS") >= 0
                               || StringFind(g_blockReason, "OB") >= 0
                               || StringFind(g_blockReason, "Stoch") >= 0
                               || StringFind(g_blockReason, "Copy") >= 0));

   string oscLine = "";
   if(UseRsiOscillator())
     {
      oscLine = "Osc: RSI"
                + " period=" + IntegerToString(InpRsiPeriod)
                + " " + EnumToString(InpRsiApplied)
                + "  OS/OB=" + DoubleToString(InpRsiOversold, 0) + "/"
                + DoubleToString(InpRsiOverbought, 0)
                + (InpStochRequireExtreme ? " (extreme OS/OB)" : " (cross 50)")
                + "\n"
                + "  closed[1] RSI=" + DoubleToString(rsiClosed, 2)
                + " | forming[0] RSI=" + DoubleToString(rsiForm, 2)
                + formCross + "\n";
     }
   else
     {
      oscLine = "Osc: Stoch " + EnumToString(InpStochPriceField) + " SMA"
                + " K/D/S=" + IntegerToString(InpStochKPeriod) + "/"
                + IntegerToString(InpStochDPeriod) + "/" + IntegerToString(InpStochSlowing)
                + "  OS/OB=" + DoubleToString(InpStochOversold, 0) + "/"
                + DoubleToString(InpStochOverbought, 0)
                + (InpStochRequireExtreme ? " (wymagane)" : " (opcjonalne)")
                + "\n"
                + "  closed[1] %K=" + DoubleToString(kClosed, 2)
                + " %D=" + DoubleToString(dClosed, 2)
                + " | forming[0] %K=" + DoubleToString(kForm, 2)
                + " %D=" + DoubleToString(dForm, 2)
                + formCross + "\n";
     }

   Comment(
      "Stochastic_Trend v1.93 | TF=", EnumToString(SignalTF()),
      " | wejscie=zamkniety bar [1] | 1 ticket/bar\n",
      "Session: ", (InpUseSessionFilter ? ("ON " + SessionStatusText()
                   + (IsInTradingSession() ? " OPEN" : " CLOSED")) : "OFF"), "\n",
      "Triple swap: ", TripleSwapStatusText(), "\n",
      "Trend: ", trendTxt,
      "  EMA", IntegerToString(InpEmaFast), "=", DoubleToString(emaF, digits),
      "  EMA", IntegerToString(InpEmaSlow), "=", DoubleToString(emaS, digits),
      "  | close: flip EMA / MaxBarsHold",
      InpCloseOnOppositeExtreme ? " / opposite extreme\n" : "\n",
      InpCloseOnOppositeExtreme
      ? ("  latch BUY-saw-OB=" + (g_buysSawOverbought ? "true" : "false")
         + " SELL-saw-OS=" + (g_sellsSawOversold ? "true" : "false") + "\n")
      : "",
      oscLine,
      "ADX filter: ", adxTxt,
      " | ADX=", DoubleToString(adxNow, 1),
      " +DI=", DoubleToString(plusDiNow, 1),
      " -DI=", DoubleToString(minusDiNow, 1),
      " | ", diMatch, "\n",
      NewsCommentLine(), "\n",
      "Active: ", g_activeSource,
      " | last kind: ", g_signalKind, "\n",
      "Signal: ", sigTxt,
      locked ? (" LOCKED: " + g_blockReason) : "",
      showBlock ? (" BLOCKED: " + g_blockReason) : "", "\n",
      "Cooldown: ", IntegerToString(g_tradeCooldownBarsLeft),
      "/", IntegerToString(EffectiveTradeCooldownBars()),
      " | Dokup co ", IntegerToString(EffectiveAddEveryBars()),
      " (za ", IntegerToString(addLeft), ")",
      " | MaxBarsHold=", IntegerToString(EffectiveMaxBarsHold()), "\n",
      HoldTrackingComment(), "\n",
      "SL/TP: ", sltpTxt
   );
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
bool IsHoldTracked(const ulong ticket)
  {
   if(ticket == 0)
      return false;
   const int n = ArraySize(g_holdTickets);
   for(int i = 0; i < n; i++)
     {
      if(g_holdTickets[i] == ticket)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
int EstimateBarsHeld(const datetime openTime)
  {
   if(openTime <= 0)
      return 0;
   const int shift = iBarShift(_Symbol, SignalTF(), openTime, false);
   if(shift < 0)
      return 0;
   return shift;
  }

//+------------------------------------------------------------------+
void TrackHoldTicket(const ulong ticket, const int barsHeld,
                     const bool openedAtHighExtreme = false,
                     const bool openedAtLowExtreme = false)
  {
   if(ticket == 0)
      return;
   if(IsHoldTracked(ticket))
      return;

   datetime openTime = 0;
   if(PositionSelectByTicket(ticket))
      openTime = (datetime)PositionGetInteger(POSITION_TIME);
   if(openTime <= 0)
      openTime = iTime(_Symbol, SignalTF(), 0);

   const int n = ArraySize(g_holdTickets);
   ArrayResize(g_holdTickets, n + 1);
   ArrayResize(g_holdBarsHeld, n + 1);
   ArrayResize(g_holdOpenTime, n + 1);
   ArrayResize(g_holdOpenedAtHigh, n + 1);
   ArrayResize(g_holdOpenedAtLow, n + 1);
   g_holdTickets[n]       = ticket;
   g_holdBarsHeld[n]      = MathMax(0, barsHeld);
   g_holdOpenTime[n]      = openTime;
   g_holdOpenedAtHigh[n]  = openedAtHighExtreme;
   g_holdOpenedAtLow[n]   = openedAtLowExtreme;
  }

//+------------------------------------------------------------------+
void RemoveHoldAt(const int index)
  {
   const int n = ArraySize(g_holdTickets);
   if(index < 0 || index >= n)
      return;
   for(int i = index; i < n - 1; i++)
     {
      g_holdTickets[i]      = g_holdTickets[i + 1];
      g_holdBarsHeld[i]     = g_holdBarsHeld[i + 1];
      g_holdOpenTime[i]     = g_holdOpenTime[i + 1];
      g_holdOpenedAtHigh[i] = g_holdOpenedAtHigh[i + 1];
      g_holdOpenedAtLow[i]  = g_holdOpenedAtLow[i + 1];
     }
   ArrayResize(g_holdTickets, n - 1);
   ArrayResize(g_holdBarsHeld, n - 1);
   ArrayResize(g_holdOpenTime, n - 1);
   ArrayResize(g_holdOpenedAtHigh, n - 1);
   ArrayResize(g_holdOpenedAtLow, n - 1);
  }

//+------------------------------------------------------------------+
void RemoveHoldByTicket(const ulong ticket)
  {
   for(int i = ArraySize(g_holdTickets) - 1; i >= 0; i--)
     {
      if(g_holdTickets[i] == ticket)
         RemoveHoldAt(i);
     }
  }

//+------------------------------------------------------------------+
void SyncCampaignFromPositions()
  {
   datetime newest = 0;
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;
      const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= newest)
         newest = t;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         buys++;
      else
         sells++;
     }

   if(buys == 0 && sells == 0)
     {
      ResetCampaign();
      return;
     }

   g_lastAddBarTime = newest;
   if(buys > 0 && sells == 0)
      g_campaignTrend = TREND_UP;
   else if(sells > 0 && buys == 0)
      g_campaignTrend = TREND_DOWN;
   else
      g_campaignTrend = CurrentTrend();
  }

//+------------------------------------------------------------------+
void RebuildHoldTracking()
  {
   ArrayResize(g_holdTickets, 0);
   ArrayResize(g_holdBarsHeld, 0);
   ArrayResize(g_holdOpenTime, 0);
   ArrayResize(g_holdOpenedAtHigh, 0);
   ArrayResize(g_holdOpenedAtLow, 0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;
      const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      bool atHigh = false;
      bool atLow  = false;
      InferOpenExtremes(openTime, atHigh, atLow);
      if(!atHigh)
         atHigh = OscTouchedLevelSince(openTime, true);
      if(!atLow)
         atLow = OscTouchedLevelSince(openTime, false);
      TrackHoldTicket(ticket, EstimateBarsHeld(openTime), atHigh, atLow);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && atHigh)
         g_buysSawOverbought = true;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && atLow)
         g_sellsSawOversold = true;
     }

   Print("Hold tracking rebuilt: ", ArraySize(g_holdTickets),
         " in-progress lifecycle(s), maxPos=", EffectiveMaxPositions());
  }

//+------------------------------------------------------------------+
void PruneClosedHolds()
  {
   for(int i = ArraySize(g_holdTickets) - 1; i >= 0; i--)
     {
      if(!IsOurPositionTicket(g_holdTickets[i]))
         RemoveHoldAt(i);
     }
   if(!HasAnyOurPosition() && !HasSwapParkExposure())
      ResetCampaign();
  }

//+------------------------------------------------------------------+
void RecoverUntrackedPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;
      if(IsHoldTracked(ticket))
         continue;
      const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      bool atHigh = false;
      bool atLow  = false;
      InferOpenExtremes(openTime, atHigh, atLow);
      if(!atHigh)
         atHigh = OscTouchedLevelSince(openTime, true);
      if(!atLow)
         atLow = OscTouchedLevelSince(openTime, false);
      TrackHoldTicket(ticket, EstimateBarsHeld(openTime), atHigh, atLow);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && atHigh)
         g_buysSawOverbought = true;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && atLow)
         g_sellsSawOversold = true;
      Print("Recovered untracked lifecycle ticket=", ticket,
            " highExt=", atHigh, " lowExt=", atLow);
     }
  }

//+------------------------------------------------------------------+
string HoldTrackingComment()
  {
   const int openCount = CountOurPositions();
   const int maxP      = EffectiveMaxPositions();
   const int maxHold   = EffectiveMaxBarsHold();
   const int n         = ArraySize(g_holdTickets);

   int    oldest = 0;
   string list   = "";
   int    listed = 0;
   for(int i = 0; i < n; i++)
     {
      if(g_holdBarsHeld[i] > oldest)
         oldest = g_holdBarsHeld[i];
      if(listed < 6)
        {
         if(list != "")
            list += " ";
         list += "#" + IntegerToString((long)g_holdTickets[i])
                 + "(" + IntegerToString(g_holdBarsHeld[i]) + ")";
         listed++;
        }
     }
   if(n > listed)
      list += " ...";
   if(list == "")
      list = "none";

   return ("Pozycje: " + IntegerToString(openCount) + "/" + IntegerToString(maxP)
           + " | najstarszy hold=" + IntegerToString(oldest) + "/" + IntegerToString(maxHold)
           + " | " + list);
  }

//+------------------------------------------------------------------+
void ManageMaxBarHoldExits()
  {
   const int maxHold = EffectiveMaxBarsHold();
   for(int i = ArraySize(g_holdTickets) - 1; i >= 0; i--)
     {
      const ulong ticket = g_holdTickets[i];
      if(!IsOurPositionTicket(ticket))
        {
         RemoveHoldAt(i);
         continue;
        }

      g_holdBarsHeld[i]++;
      TryCloseHoldIfExpired(i, maxHold);
     }

   RecoverUntrackedPositions();
   for(int j = ArraySize(g_holdTickets) - 1; j >= 0; j--)
      TryCloseHoldIfExpired(j, maxHold);

   if(!HasAnyOurPosition() && !HasSwapParkExposure())
      ResetCampaign();
  }

//+------------------------------------------------------------------+
void TryCloseHoldIfExpired(const int index, const int maxHold)
  {
   if(index < 0 || index >= ArraySize(g_holdTickets))
      return;
   if(g_holdBarsHeld[index] < maxHold)
      return;

   const ulong ticket = g_holdTickets[index];
   if(!IsOurPositionTicket(ticket))
     {
      RemoveHoldAt(index);
      return;
     }

   if(!g_trade.PositionClose(ticket))
      Print("MaxBarsHold close failed: ", g_trade.ResultRetcode(), " ",
            g_trade.ResultRetcodeDescription(), " ticket=", ticket);
   else
     {
      Print("Position closed: MaxBarsHold ticket=", ticket,
            " barsHeld=", g_holdBarsHeld[index]);
      RemoveHoldAt(index);
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
bool CreateStochHandle()
  {
   if(g_stochHandle != INVALID_HANDLE)
      return true;
   if(InpStochKPeriod < 1 || InpStochDPeriod < 1 || InpStochSlowing < 1)
      return false;
   g_stochHandle = iStochastic(_Symbol, SignalTF(), InpStochKPeriod, InpStochDPeriod,
                               InpStochSlowing, MODE_SMA, InpStochPriceField);
   return (g_stochHandle != INVALID_HANDLE);
  }

//+------------------------------------------------------------------+
bool CreateRsiHandle()
  {
   if(g_rsiHandle != INVALID_HANDLE)
      return true;
   if(InpRsiPeriod < 1)
      return false;
   g_rsiHandle = iRSI(_Symbol, SignalTF(), InpRsiPeriod, InpRsiApplied);
   return (g_rsiHandle != INVALID_HANDLE);
  }

//+------------------------------------------------------------------+
void LogOscCopyFailOnce(const string which)
  {
   if(g_lastOscCopyFailBar == g_lastBarTime && g_lastBarTime != 0)
      return;
   g_lastOscCopyFailBar = g_lastBarTime;
   Print(which, " CopyBuffer failed — brak danych wskaznika.",
         " mode=", OscillatorName(),
         " stochH=", g_stochHandle, " rsiH=", g_rsiHandle,
         " err=", GetLastError(),
         " (retry next bar, not silent forever)");
  }

//+------------------------------------------------------------------+
bool CopyStoch()
  {
   if(g_stochHandle == INVALID_HANDLE)
      CreateStochHandle();
   if(g_stochHandle == INVALID_HANDLE)
      return false;
   if(CopyBuffer(g_stochHandle, 0, 0, 3, g_stochK) < 3)
      return false;
   if(CopyBuffer(g_stochHandle, 1, 0, 3, g_stochD) < 3)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool CopyRsi()
  {
   if(g_rsiHandle == INVALID_HANDLE)
      CreateRsiHandle();
   if(g_rsiHandle == INVALID_HANDLE)
      return false;
   if(CopyBuffer(g_rsiHandle, 0, 0, 4, g_rsi) < 4)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool CopyTrend()
  {
   if(CopyBuffer(g_emaFastHandle, 0, 0, 3, g_emaFast) < 3) return false;
   if(CopyBuffer(g_emaSlowHandle, 0, 0, 3, g_emaSlow) < 3) return false;
   return true;
  }

//+------------------------------------------------------------------+
bool CopyAdx()
  {
   if(CopyBuffer(g_adxHandle, 0, 0, 3, g_adxMain)    < 3) return false;
   if(CopyBuffer(g_adxHandle, 1, 0, 3, g_adxPlusDi)  < 3) return false;
   if(CopyBuffer(g_adxHandle, 2, 0, 3, g_adxMinusDi) < 3) return false;
   return true;
  }

//+------------------------------------------------------------------+
bool PassesAdxFilter(const bool isBuy)
  {
   if(!InpUseAdxFilter)
      return true;

   if(g_adxHandle == INVALID_HANDLE || !CopyAdx())
     {
      g_blockReason = "ADX data unavailable";
      return false;
     }

   const double adx    = g_adxMain[1];
   const double adxMin = InpAdxMinLevel;
   if(adx < adxMin)
     {
      g_blockReason = "ADX no trend (" + DoubleToString(adx, 1)
                      + " < " + DoubleToString(adxMin, 1) + ")"
                      + (isBuy ? " BUY" : " SELL");
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
bool HasOurPosition(const ENUM_POSITION_TYPE type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(PositionGetTicket(i)))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool HasAnyOurPosition()
  {
   return CountOurPositions() > 0;
  }

//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!IsOurPositionTicket(ticket))
         continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
double RoundToTick(const double price)
  {
   const double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      return price;
   return MathRound(price / tick) * tick;
  }

//+------------------------------------------------------------------+
double MinStopDistancePrice()
  {
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;
   const long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const long level  = MathMax(stops, freeze);
   return (double)(level + 1) * point;
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
void CalcSLTPFromEntry(const ENUM_ORDER_TYPE orderType, const double entry, double &sl, double &tp)
  {
   const int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double minDist = MinStopDistancePrice();

   sl = 0.0;
   tp = 0.0;
   if(point <= 0.0 || entry <= 0.0)
     {
      Print("CalcSLTPFromEntry: invalid point/entry");
      return;
     }

   double slDist = (double)MathMax(InpStopLossPoints, 1) * point;
   double tpDist = (double)MathMax(InpTakeProfitPoints, 1) * point;

   if(minDist > 0.0)
     {
      if(slDist < minDist)
         slDist = minDist;
      if(tpDist < minDist)
         tpDist = minDist;
     }

   if(orderType == ORDER_TYPE_BUY)
     {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = RoundToTick(entry - slDist);
      tp = RoundToTick(entry + tpDist);
      if(minDist > 0.0 && bid > 0.0 && (bid - sl) < minDist)
         sl = RoundToTick(bid - minDist);
      if(minDist > 0.0 && (tp - entry) < minDist)
         tp = RoundToTick(entry + minDist);
     }
   else
     {
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = RoundToTick(entry + slDist);
      tp = RoundToTick(entry - tpDist);
      if(minDist > 0.0 && ask > 0.0 && (sl - ask) < minDist)
         sl = RoundToTick(ask + minDist);
      if(minDist > 0.0 && (entry - tp) < minDist)
         tp = RoundToTick(entry - minDist);
     }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   Print("CalcSLTP ", EnumToString(orderType),
         " entry=", DoubleToString(entry, digits),
         " sl=", DoubleToString(sl, digits),
         " tp=", DoubleToString(tp, digits),
         " minDist=", DoubleToString(minDist, digits));
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

//+------------------------------------------------------------------+
bool SwapHoldStillValid(const int barsHeld)
  {
   const int maxHold = EffectiveMaxBarsHold();
   if(maxHold <= 0)
      return true;
   return (barsHeld < maxHold);
  }

void SnapshotHoldForTicket(const ulong ticket, int &barsHeld, bool &atHigh, bool &atLow)
  {
   barsHeld = 0;
   atHigh   = false;
   atLow    = false;
   const int n = ArraySize(g_holdTickets);
   for(int i = 0; i < n; i++)
     {
      if(g_holdTickets[i] != ticket)
         continue;
      barsHeld = g_holdBarsHeld[i];
      atHigh   = g_holdOpenedAtHigh[i];
      atLow    = g_holdOpenedAtLow[i];
      return;
     }
   if(PositionSelectByTicket(ticket))
      barsHeld = EstimateBarsHeld((datetime)PositionGetInteger(POSITION_TIME));
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

   const ENUM_TREND_DIR trend = CurrentTrend();
   if(park.type == POSITION_TYPE_BUY)
     {
      if(trend != TREND_UP)
        {
         Print("Triple-swap reopen skipped: EMA not UP");
         return false;
        }
      if(NewsBlocksBuy())
        {
         Print("Triple-swap reopen skipped: news blocks BUY");
         return false;
        }
      if(InpCloseOnOppositeExtreme && (park.atHigh || g_buysSawOverbought) &&
         OscClosedAtLowExtreme())
        {
         Print("Triple-swap reopen skipped: opposite extreme would flatten BUY");
         return false;
        }
     }
   else
     {
      if(trend != TREND_DOWN)
        {
         Print("Triple-swap reopen skipped: EMA not DOWN");
         return false;
        }
      if(NewsBlocksSell())
        {
         Print("Triple-swap reopen skipped: news blocks SELL");
         return false;
        }
      if(InpCloseOnOppositeExtreme && (park.atLow || g_sellsSawOversold) &&
         OscClosedAtHighExtreme())
        {
         Print("Triple-swap reopen skipped: opposite extreme would flatten SELL");
         return false;
        }
     }
   return true;
  }

bool OpenSwapReopen(const SwapPark &park)
  {
   const bool isBuy = (park.type == POSITION_TYPE_BUY);
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

   const string comment = isBuy ? "STOCH TREND SWAP REOPEN BUY"
                                : "STOCH TREND SWAP REOPEN SELL";
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

   g_campaignTrend = isBuy ? TREND_UP : TREND_DOWN;
   g_lastAddBarTime = iTime(_Symbol, SignalTF(), 0);
   if(park.atHigh)
      g_buysSawOverbought = true;
   if(park.atLow)
      g_sellsSawOversold = true;

   const ulong ticket = FindNewestOurPosition(park.type);
   if(ticket == 0)
     {
      Print("Triple-swap reopen: fill not found");
      return false;
     }

   TrackHoldTicket(ticket, park.barsHeld, park.atHigh, park.atLow);
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
      const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int barsHeld = 0;
      bool atHigh = false;
      bool atLow  = false;
      SnapshotHoldForTicket(ticket, barsHeld, atHigh, atLow);

      if(!g_trade.PositionClose(ticket))
        {
         Print("Triple-swap close failed ticket=", ticket, " ",
               g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         continue;
        }

      RemoveHoldByTicket(ticket);
      const int n = CountSwapParks();
      ArrayResize(g_swapParks, n + 1);
      g_swapParks[n].type         = type;
      g_swapParks[n].lots         = lots;
      g_swapParks[n].barsHeld     = barsHeld;
      g_swapParks[n].originalOpen = openTime;
      g_swapParks[n].atHigh       = atHigh;
      g_swapParks[n].atLow        = atLow;
      g_swapParks[n].parkTime     = now;
      g_swapParks[n].reopenAfter  = charge;
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
   else if(HasAnyOurPosition())
      g_swapStatus = "close window, close pending";
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
      g_signalKind    = "swap reopen";
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
void OpenBuy(const string comment, const bool pyramidAdd, const bool newsForced = false)
  {
   if(pyramidAdd)
     {
      if(g_tradedThisBar)
        {
         Print("OpenBuy pyramid blocked: already traded this bar");
         return;
        }
      if(CountOurPositions() >= EffectiveMaxPositions())
        {
         Print("OpenBuy pyramid blocked: max positions");
         return;
        }
     }
   else if(newsForced)
     {
      if(g_tradedThisBar)
        {
         Print("OpenBuy news blocked: already traded this bar");
         return;
        }
      if(CountOurPositions() >= EffectiveMaxPositions())
        {
         Print("OpenBuy news blocked: max positions");
         return;
        }
     }
   else if(!CanOpenTrade())
     {
      Print("OpenBuy blocked: ", g_blockReason);
      return;
     }
   if(!newsForced && NewsBlocksBuy())
     {
      Print("OpenBuy blocked: news bias");
      return;
     }

   double sl, tp;
   CalcSLTP(ORDER_TYPE_BUY, sl, tp);
   if(sl <= 0.0 || tp <= 0.0)
     {
      Print("OpenBuy blocked: invalid SL/TP after CalcSLTP");
      return;
     }

   const double lots = LotsForNextOpen();
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
      if(!g_trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, comment))
        {
         Print("Buy retry without SL/TP also failed: ",
               g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         return;
        }
      Print("Buy opened WITHOUT SL/TP — will attach via PositionModify");
     }

   RememberOpen(TREND_UP);
   ConsumeNewsFlipLotIfOpened();
   ulong ticket = FindNewestOurPosition(POSITION_TYPE_BUY);
   if(ticket != 0)
     {
      const bool atHigh = OscClosedAtHighExtreme();
      TrackHoldTicket(ticket, 0, atHigh, false);
      if(atHigh)
         g_buysSawOverbought = true;
      EnsurePositionSLTP(ticket, POSITION_TYPE_BUY);
      if(atHigh)
         Print("BUY ticket=", ticket, " opened at HIGH extreme (",
               OscillatorName(), " [1]=", DoubleToString(ClosedOscValue(), 2),
               " OB=", DoubleToString(OscOverboughtLevel(), 0), ")");
     }
   else
      Print("OpenBuy: position ticket not found after fill");
  }

//+------------------------------------------------------------------+
void OpenSell(const string comment, const bool pyramidAdd, const bool newsForced = false)
  {
   if(pyramidAdd)
     {
      if(g_tradedThisBar)
        {
         Print("OpenSell pyramid blocked: already traded this bar");
         return;
        }
      if(CountOurPositions() >= EffectiveMaxPositions())
        {
         Print("OpenSell pyramid blocked: max positions");
         return;
        }
     }
   else if(newsForced)
     {
      if(g_tradedThisBar)
        {
         Print("OpenSell news blocked: already traded this bar");
         return;
        }
      if(CountOurPositions() >= EffectiveMaxPositions())
        {
         Print("OpenSell news blocked: max positions");
         return;
        }
     }
   else if(!CanOpenTrade())
     {
      Print("OpenSell blocked: ", g_blockReason);
      return;
     }
   if(!newsForced && NewsBlocksSell())
     {
      Print("OpenSell blocked: news bias");
      return;
     }

   double sl, tp;
   CalcSLTP(ORDER_TYPE_SELL, sl, tp);
   if(sl <= 0.0 || tp <= 0.0)
     {
      Print("OpenSell blocked: invalid SL/TP after CalcSLTP");
      return;
     }

   const double lots = LotsForNextOpen();
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

   RememberOpen(TREND_DOWN);
   ConsumeNewsFlipLotIfOpened();
   ulong ticket = FindNewestOurPosition(POSITION_TYPE_SELL);
   if(ticket != 0)
     {
      const bool atLow = OscClosedAtLowExtreme();
      TrackHoldTicket(ticket, 0, false, atLow);
      if(atLow)
         g_sellsSawOversold = true;
      EnsurePositionSLTP(ticket, POSITION_TYPE_SELL);
      if(atLow)
         Print("SELL ticket=", ticket, " opened at LOW extreme (",
               OscillatorName(), " [1]=", DoubleToString(ClosedOscValue(), 2),
               " OS=", DoubleToString(OscOversoldLevel(), 0), ")");
     }
   else
      Print("OpenSell: position ticket not found after fill");
  }

//+------------------------------------------------------------------+
ulong FindNewestOurPosition(const ENUM_POSITION_TYPE type)
  {
   ulong    bestTicket = 0;
   datetime bestTime   = 0;
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
