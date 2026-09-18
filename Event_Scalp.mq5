//+------------------------------------------------------------------+
//|                                                   Event_Scalp.mq5 |
//|  M15 impulse: large forming candle, pullback fill.                |
//|  Closed-bar ADX/ATR. H1 optional. No tick-burst / z-score.        |
//+------------------------------------------------------------------+
#property copyright "My robots"
#property version   "2.27"
#property strict

#include <Trade\Trade.mqh>

#define SLIPPAGE_POINTS      30
#define MAX_POSITIONS_CAP    20
#define ATR_PERIOD           14

enum ENUM_SESSION_CLOCK
  {
   SESSION_CLOCK_SERVER = 0, // Broker server time
   SESSION_CLOCK_GMT    = 1, // GMT / UTC
   SESSION_CLOCK_LOCAL  = 2  // PC local time
  };

//==================== SIGNALS =======================================
input group "=== Rapid bar ==="
input bool            InpUseRapidBar      = true;   // Rapid bar (ATR)
input double          InpRapidAtrMult     = 1.2;    // Min. candle RANGE = ATR * this
input double          InpRapidAtrMax      = 4.0;    // Skip when range >= ATR * this (0=off; < min = off)
input int             InpRapidMinPoints   = 70;     // Min. range in points (0=off)
input double          InpRapidBodyRatio   = 0.60;   // Min. |close-open| / range (0=off)
input double          InpRapidClosePos    = 0.30;   // Close in the last X of the range (0=off)
input double          InpRapidPullbackMin = 0.50;   // Enter after pullback (0=immediately on the bar)
input double          InpRapidPullbackMax = 0.60;   // Too deep pullback = abort
input bool            InpRapidUseM1       = false;  // M1 confirmation (closed bars only)
input int             InpRapidM1Bars      = 1;      // Closed M1 bars in direction (0 = last closed)
input int             InpRapidVelocitySec = 0;      // 0=off. Max seconds from bar open
input double          InpRapidVelocityAtr = 0.70;   // ATR required to count as velocity
input bool            InpRapidAbortWick   = false;  // Close Rapid when a wick reverses the bar
input double          InpRapidAbortBody   = 0.35;   // Abort when body < this and close crosses open
input int             InpRapidAbortSec    = 15;     // Wick must hold this many seconds (0=first tick)

input group "=== Trade ==="
input double          InpLots             = 0.10;   // Lot
input bool            InpUseAtrStops      = true;   // SL/TP from ATR (otherwise points)
input double          InpSlAtrMult        = 1.4;    // SL = ATR * this
input double          InpTpAtrMult        = 1.3;    // TP = ATR * this
input bool            InpUseStructSl      = false;  // SL beyond current TF low/high
input int             InpStopLossPoints   = 400;    // SL fallback (SYMBOL_POINT)
input int             InpTakeProfitPoints = 500;    // TP fallback
input double          InpBeAtrMult        = 0.50;   // BE after +ATR*this (0=off)
input double          InpTrailAtrMult     = 0.0;    // Trail ATR (0=off); never below BE
input bool            InpTrailM1          = false;  // Trail behind M1 swing
input double          InpSpreadMaxPctSl   = 0.15;   // Skip when spread > % of SL (0=off)
input double          InpMinTpSpreadMult  = 5.0;    // Skip when TP < spread * this (0=off)
input int             InpMaxPositions     = 3;      // Max open positions
input int             InpMaxBarsHold      = 3;      // Hold (TF bars)
input int             InpCooldownBars     = 0;      // Pause after open (bars)
input int             InpCooldownAfterSL  = 1;      // Pause after SL (bars)
input double          InpMaxDailyLossPct  = 2.0;    // Halt NEW entries after this-EA loss % today (0=off)

// Hours are inclusive (8 and 17 = 08:00-17:59). End < start wraps midnight.
input group "=== Session hours ==="
input bool            InpUseSessionFilter = true;   // Limit NEW entries to session hours
input ENUM_SESSION_CLOCK InpSessionClock  = SESSION_CLOCK_SERVER; // Clock for hours below
input int             InpSession1StartHour = 8;     // Window 1 start hour 0-23 (London ~08)
input int             InpSession1EndHour  = 17;     // Window 1 end hour 0-23 inclusive
input bool            InpUseSession2      = true;   // Second window (NY overlap)
input int             InpSession2StartHour = 13;    // Window 2 start hour 0-23 (NY ~13)
input int             InpSession2EndHour  = 21;     // Window 2 end hour 0-23 inclusive

// Closed-bar only. Do not add tick-burst / z-score (loses on real ticks).
input group "=== Regime ==="
input bool            InpUseAdxFilter     = true;   // Skip chop (closed ADX)
input int             InpAdxPeriod        = 14;     // ADX period
input double          InpAdxMin           = 18.0;   // Min ADX (below = chop)
input bool            InpAdxMustRise      = false;  // Require ADX rising vs prior bar
input bool            InpAdxUseDi         = false;  // +DI/-DI must match Rapid side
input bool            InpUseH1Ema         = false;  // Only with closed H1 EMA (off: more Rapid fills)
input int             InpH1EmaPeriod      = 50;     // H1 EMA period
input bool            InpUseAtrRegime     = true;   // Skip when ATR is compressed
input int             InpAtrAvgBars       = 50;     // Bars to average ATR
input double          InpMinAtrRatio      = 0.55;   // Current ATR / avg ATR (0=off)

input group "=== Ogolne ==="
input ulong           InpMagic            = 26091401;
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M15;
input bool            InpShowComments     = true;

int      g_atrHandle = INVALID_HANDLE;
int      g_adxHandle = INVALID_HANDLE;
int      g_h1EmaHandle = INVALID_HANDLE;
datetime g_barTime = 0;
CTrade   g_trade;

ulong    g_tickets[];
int      g_held[];
int      g_holdCap[];

int      g_maxPos = 1;
int      g_cooldown = 0;
bool     g_openedBar = false;
string   g_lastKind = "-";
string   g_block = "";

int      g_armState = 0; // 0 idle, 1 armed, 2 done this bar
bool     g_armBuy = false;
double   g_armOpen = 0;
double   g_armExtreme = 0;
bool     g_velOk = false;
bool     g_m1Warn = false;
bool     g_adxWarn = false;
bool     g_h1Warn = false;
datetime g_wickSince = 0;
datetime g_dayStamp = 0;
double   g_dayStartEquity = 0;
double   g_dayClosedPnl = 0;
bool     g_dayHaltPrinted = false;

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES TF()
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

int ClampMaxPos()
  {
   return MathMin(MAX_POSITIONS_CAP, MathMax(1, InpMaxPositions));
  }

int ClampHold()
  {
   return MathMax(1, InpMaxBarsHold);
  }

double PullbackMin()
  {
   return MathMax(0.0, InpRapidPullbackMin);
  }

double PullbackMax()
  {
   const double mn = PullbackMin();
   return (InpRapidPullbackMax < mn) ? mn : InpRapidPullbackMax;
  }

bool Ours(const ulong ticket)
  {
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return false;
   return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
           (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

int CountOurs()
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(Ours(PositionGetTicket(i))) c++;
   return c;
  }

datetime DayStart(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
  }

double SumOurDealsSince(const datetime from)
  {
   double s = 0;
   if(from <= 0 || !HistorySelect(from, TimeCurrent() + 1)) return 0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      s += HistoryDealGetDouble(ticket, DEAL_PROFIT)
         + HistoryDealGetDouble(ticket, DEAL_SWAP)
         + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
     }
   return s;
  }

double FloatingOurs()
  {
   double s = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(!Ours(t)) continue;
      s += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return s;
  }

void DayReset()
  {
   g_dayStamp = DayStart(TimeCurrent());
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY) - FloatingOurs();
   g_dayClosedPnl = SumOurDealsSince(g_dayStamp);
   g_dayHaltPrinted = false;
  }

void EnsureDay()
  {
   const datetime d = DayStart(TimeCurrent());
   if(d != g_dayStamp)
      DayReset();
  }

void RefreshDayClosedPnl()
  {
   EnsureDay();
   g_dayClosedPnl = SumOurDealsSince(g_dayStamp);
  }

double DayPnl()
  {
   EnsureDay();
   return g_dayClosedPnl + FloatingOurs();
  }

double DayLossPct()
  {
   EnsureDay();
   if(g_dayStartEquity <= 0.0) return 0;
   const double pnl = DayPnl();
   if(pnl >= 0.0) return 0;
   return (-pnl / g_dayStartEquity) * 100.0;
  }

bool DailyLossOk()
  {
   if(InpMaxDailyLossPct <= 0.0) return true;
   const double lossPct = DayLossPct();
   if(lossPct >= InpMaxDailyLossPct)
     {
      g_block = "daily loss " + DoubleToString(lossPct, 2) + "%";
      if(!g_dayHaltPrinted)
        {
         Print("Daily loss halt ", DoubleToString(lossPct, 2),
               "% >= ", DoubleToString(InpMaxDailyLossPct, 2),
               "% (this EA, server day)");
         g_dayHaltPrinted = true;
        }
      return false;
     }
   return true;
  }

int HoldIndex(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_tickets); i++)
      if(g_tickets[i] == ticket) return i;
   return -1;
  }

void HoldRemove(const int idx)
  {
   const int n = ArraySize(g_tickets);
   if(idx < 0 || idx >= n) return;
   for(int i = idx; i < n - 1; i++)
     {
      g_tickets[i] = g_tickets[i + 1];
      g_held[i]    = g_held[i + 1];
      g_holdCap[i] = g_holdCap[i + 1];
     }
   ArrayResize(g_tickets, n - 1);
   ArrayResize(g_held, n - 1);
   ArrayResize(g_holdCap, n - 1);
  }

void HoldDrop(const ulong ticket)
  {
   const int i = HoldIndex(ticket);
   if(i >= 0) HoldRemove(i);
  }

void HoldAdd(const ulong ticket, const int bars, const int cap)
  {
   if(ticket == 0 || HoldIndex(ticket) >= 0) return;
   const int n = ArraySize(g_tickets);
   ArrayResize(g_tickets, n + 1);
   ArrayResize(g_held, n + 1);
   ArrayResize(g_holdCap, n + 1);
   g_tickets[n] = ticket;
   g_held[n]    = MathMax(0, bars);
   g_holdCap[n] = MathMax(1, cap);
  }

void HoldPrune()
  {
   for(int i = ArraySize(g_tickets) - 1; i >= 0; i--)
      if(!Ours(g_tickets[i])) HoldRemove(i);
  }

void HoldRebuild()
  {
   ArrayResize(g_tickets, 0);
   ArrayResize(g_held, 0);
   ArrayResize(g_holdCap, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(!Ours(t)) continue;
      const datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      const int sh = (ot > 0) ? iBarShift(_Symbol, TF(), ot, false) : 0;
      HoldAdd(t, (sh < 0) ? 0 : sh, ClampHold());
     }
  }

void CloseTicket(const ulong ticket, const string why)
  {
   if(!Ours(ticket)) return;
   const ENUM_POSITION_TYPE ty = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(!g_trade.PositionClose(ticket))
      Print("Close fail ", g_trade.ResultRetcodeDescription(), " #", ticket);
   else
     {
      Print("Close ", why, " #", ticket, " ", EnumToString(ty));
      HoldDrop(ticket);
     }
  }

void HoldExpire()
  {
   for(int i = ArraySize(g_tickets) - 1; i >= 0; i--)
     {
      if(!Ours(g_tickets[i])) { HoldRemove(i); continue; }
      g_held[i]++;
      const int cap = (g_holdCap[i] > 0) ? g_holdCap[i] : ClampHold();
      if(g_held[i] >= cap)
         CloseTicket(g_tickets[i], "MaxBarsHold");
     }
  }

void ResetBarState()
  {
   g_armState = 0;
   g_armBuy = false;
   g_armOpen = 0;
   g_armExtreme = 0;
   g_velOk = (InpRapidVelocitySec <= 0);
   g_wickSince = 0;
  }

bool NewBar()
  {
   const datetime t = iTime(_Symbol, TF(), 0);
   if(t == 0 || t == g_barTime) return false;
   g_barTime = t;
   return true;
  }

bool CopyAtr(double &atr)
  {
   atr = 0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, b) < 1) return false;
   atr = b[0];
   return (atr > 0.0);
  }

bool CopyClosedBuf(const int handle, const int buffer, const int count, double &dest[])
  {
   if(handle == INVALID_HANDLE || count < 1) return false;
   // CopyBuffer can drop AS_SERIES. Re-apply after copy: dest[0]=shift 1 (last closed).
   if(CopyBuffer(handle, buffer, 1, count, dest) < count) return false;
   ArraySetAsSeries(dest, true);
   return true;
  }

bool AtrRegimeOk()
  {
   if(!InpUseAtrRegime || InpMinAtrRatio <= 0.0) return true;
   double cur = 0;
   if(!CopyAtr(cur)) return true;
   const int n = MathMax(10, InpAtrAvgBars);
   double b[];
   if(!CopyClosedBuf(g_atrHandle, 0, n, b)) return true;
   double s = 0;
   for(int i = 0; i < n; i++) s += b[i];
   const double avg = s / n;
   if(avg <= 0.0) return true;
   if(cur / avg < InpMinAtrRatio)
     {
      g_block = "ATR compressed";
      return false;
     }
   return true;
  }

bool AdxChopOk()
  {
   if(!InpUseAdxFilter) return true;
   if(g_adxHandle == INVALID_HANDLE)
     {
      if(!g_adxWarn)
        {
         Print("Rapid: brak ADX — puszczam bez filtra chop");
         g_adxWarn = true;
        }
      return true;
     }
   g_adxWarn = false;
   double adx[];
   if(!CopyClosedBuf(g_adxHandle, 0, 2, adx)) return true;
   if(adx[0] < InpAdxMin)
     {
      g_block = "ADX chop";
      return false;
     }
   if(InpAdxMustRise && adx[0] <= adx[1])
     {
      g_block = "ADX not rising";
      return false;
     }
   return true;
  }

bool AdxDiOk(const bool buy)
  {
   if(!InpUseAdxFilter || !InpAdxUseDi) return true;
   if(g_adxHandle == INVALID_HANDLE) return true;
   double pdi[], ndi[];
   if(!CopyClosedBuf(g_adxHandle, 1, 1, pdi)) return true;
   if(!CopyClosedBuf(g_adxHandle, 2, 1, ndi)) return true;
   if(buy && pdi[0] <= ndi[0])
     {
      g_block = "ADX DI against";
      return false;
     }
   if(!buy && ndi[0] <= pdi[0])
     {
      g_block = "ADX DI against";
      return false;
     }
   return true;
  }

bool H1EmaOk(const bool buy)
  {
   if(!InpUseH1Ema) return true;
   if(g_h1EmaHandle == INVALID_HANDLE || Bars(_Symbol, PERIOD_H1) < 10)
     {
      if(!g_h1Warn)
        {
         Print("Rapid: brak H1 EMA — puszczam bez HTF");
         g_h1Warn = true;
        }
      return true;
     }
   g_h1Warn = false;
   double ema[];
   if(!CopyClosedBuf(g_h1EmaHandle, 0, 1, ema)) return true;
   const double cl = iClose(_Symbol, PERIOD_H1, 1);
   if(cl <= 0.0 || ema[0] <= 0.0) return true;
   if(buy && cl < ema[0])
     {
      g_block = "H1 EMA against";
      return false;
     }
   if(!buy && cl > ema[0])
     {
      g_block = "H1 EMA against";
      return false;
     }
   return true;
  }

bool RegimeOk(const bool buy)
  {
   if(!AtrRegimeOk()) return false;
   if(!AdxChopOk()) return false;
   if(!AdxDiOk(buy)) return false;
   if(!H1EmaOk(buy)) return false;
   return true;
  }

double TickRound(const double p)
  {
   const double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return (t > 0.0) ? MathRound(p / t) * t : p;
  }

double MinStop()
  {
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pt <= 0.0) return 0.0;
   const long lv = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                           SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   return (double)(lv + 1) * pt;
  }

double SpreadPx()
  {
   return SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
  }

double SlDistance()
  {
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double md = MinStop();
   double d = (pt > 0.0) ? (double)MathMax(InpStopLossPoints, 1) * pt : md;
   double atr = 0;
   if(InpUseAtrStops && CopyAtr(atr))
      d = atr * MathMax(InpSlAtrMult, 0.1);
   return MathMax(d, md);
  }

double TpDistance()
  {
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double md = MinStop();
   double d = (pt > 0.0) ? (double)MathMax(InpTakeProfitPoints, 1) * pt : md;
   double atr = 0;
   if(InpUseAtrStops && CopyAtr(atr))
      d = atr * MathMax(InpTpAtrMult, 0.1);
   return MathMax(d, md);
  }

bool SpreadOk()
  {
   const double spr = SpreadPx();
   if(InpSpreadMaxPctSl > 0.0)
     {
      const double sl = SlDistance();
      if(sl <= 0.0) return false;
      if(spr > sl * InpSpreadMaxPctSl)
        {
         g_block = "spread";
         return false;
        }
     }
   if(InpMinTpSpreadMult > 0.0)
     {
      const double tp = TpDistance();
      if(spr > 0.0 && tp < spr * InpMinTpSpreadMult)
        {
         g_block = "TP vs spread";
         return false;
        }
     }
   return true;
  }

bool CanOpen()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { g_block = "AutoTrading OFF"; return false; }
   if(InpUseSessionFilter && !IsInTradingSession())
     { g_block = "outside session (" + SessionStatusText() + ")"; return false; }
   if(!DailyLossOk()) return false;
   if(g_openedBar) { g_block = "juz otwarto na barze"; return false; }
   if(g_cooldown > 0) { g_block = "cooldown"; return false; }
   if(CountOurs() >= g_maxPos) { g_block = "max pozycji"; return false; }
   if(!SpreadOk()) return false;
   if(!AtrRegimeOk()) return false;
   if(!AdxChopOk()) return false;
   return true;
  }

double NormVol(double lots)
  {
   const double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st > 0.0) lots = MathRound(lots / st) * st;
   if(mn > 0.0 && lots < mn) lots = mn;
   if(mx > 0.0 && lots > mx) lots = mx;
   return lots;
  }

double NextLots()
  {
   return NormVol(InpLots);
  }

void CalcSLTP(const bool buy, double &sl, double &tp)
  {
   sl = 0; tp = 0;
   const int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entry <= 0.0) return;
   const double md = MinStop();
   const double sld = SlDistance();
   const double tpd = TpDistance();
   sl = buy ? entry - sld : entry + sld;
   if(InpUseStructSl)
     {
      const double buf = MathMax(md, SpreadPx());
      const double lo = iLow(_Symbol, TF(), 0);
      const double hi = iHigh(_Symbol, TF(), 0);
      if(buy && lo > 0.0)
        {
         double st = lo - buf;
         if(entry - st < md) st = entry - md;
         if(entry - st > sld) st = entry - sld;
         sl = st;
        }
      else if(!buy && hi > 0.0)
        {
         double st = hi + buf;
         if(st - entry < md) st = entry + md;
         if(st - entry > sld) st = entry + sld;
         sl = st;
        }
     }
   tp = buy ? entry + tpd : entry - tpd;
   sl = NormalizeDouble(TickRound(sl), dg);
   tp = NormalizeDouble(TickRound(tp), dg);
  }

bool BetterSL(const bool buy, const double candidate, const double cur)
  {
   if(candidate <= 0.0) return false;
   if(cur <= 0.0) return true;
   return buy ? (candidate > cur) : (candidate < cur);
  }

bool AttachStops(const ulong ticket, const bool buy)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetDouble(POSITION_SL) > 0.0 && PositionGetDouble(POSITION_TP) > 0.0)
      return true;
   double sl, tp;
   CalcSLTP(buy, sl, tp);
   if(sl <= 0.0 || tp <= 0.0) return false;
   if(!g_trade.PositionModify(ticket, sl, tp))
     {
      Print("SL/TP modify fail #", ticket, " ", g_trade.ResultRetcodeDescription());
      return false;
     }
   Print("SL/TP OK #", ticket);
   return true;
  }

ulong Newest(const ENUM_POSITION_TYPE ty)
  {
   ulong best = 0;
   datetime bt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(!Ours(t)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ty) continue;
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(tm >= bt) { bt = tm; best = t; }
     }
   return best;
  }

void OpenDir(const bool buy, const string tag)
  {
   if(!CanOpen())
     {
      Print(buy ? "BUY" : "SELL", " blocked: ", g_block);
      return;
     }
   double sl, tp;
   CalcSLTP(buy, sl, tp);
   const double lots = NextLots();
   bool ok = buy ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, tag)
                 : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, tag);
   if(!ok)
     {
      Print(buy ? "Buy" : "Sell", " fail ", g_trade.ResultRetcodeDescription());
      if(g_trade.ResultRetcode() != TRADE_RETCODE_INVALID_STOPS)
         return;
      ok = buy ? g_trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, tag)
               : g_trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, tag);
      if(!ok) return;
      Print("Otwarto bez SL/TP — doklejam");
     }
   g_openedBar = true;
   g_armState  = 2;
   g_cooldown  = MathMax(InpCooldownBars, 0);
   g_lastKind  = tag;
   const ulong ticket = Newest(buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   if(ticket == 0) return;
   HoldAdd(ticket, 0, ClampHold());
   AttachStops(ticket, buy);
   Print("Signal ", tag, " #", ticket);
  }

void UpdateVelocity()
  {
   if(InpRapidVelocitySec <= 0)
     {
      g_velOk = true;
      return;
     }
   if(g_velOk) return;
   double atr = 0;
   if(!CopyAtr(atr)) return;
   const datetime t0 = iTime(_Symbol, TF(), 0);
   if(t0 == 0) return;
   const double op = iOpen(_Symbol, TF(), 0);
   const double cl = iClose(_Symbol, TF(), 0);
   const double hi = iHigh(_Symbol, TF(), 0);
   const double lo = iLow(_Symbol, TF(), 0);
   if(op <= 0.0 || hi <= lo) return;
   const double need = atr * InpRapidVelocityAtr;
   const double disp = MathAbs(cl - op);
   const double rng  = hi - lo;
   if(disp < need && rng < need) return;
   if((TimeCurrent() - t0) <= InpRapidVelocitySec || rng >= atr * InpRapidAtrMult)
      g_velOk = true;
  }

bool M1Confirm(const bool buy)
  {
   if(!InpRapidUseM1) return true;
   if(Bars(_Symbol, PERIOD_M1) < 5)
     {
      if(!g_m1Warn)
        {
         Print("Rapid: brak M1 — puszczam bez potwierdzenia");
         g_m1Warn = true;
        }
      return true;
     }
   g_m1Warn = false;
   const int need = MathMax(1, InpRapidM1Bars);
   for(int i = 1; i <= need; i++)
     {
      const double op = iOpen(_Symbol, PERIOD_M1, i);
      const double cl = iClose(_Symbol, PERIOD_M1, i);
      if(op <= 0.0 || cl <= 0.0) continue;
      if(buy && cl <= op)
        {
         g_block = "M1 przeciwne";
         return false;
        }
      if(!buy && cl >= op)
        {
         g_block = "M1 przeciwne";
         return false;
        }
     }
   return true;
  }

bool RapidQualify(bool &buy, const bool strict)
  {
   buy = false;
   double atr = 0;
   if(!CopyAtr(atr))
     {
      g_block = "brak ATR";
      return false;
     }
   const double hi = iHigh(_Symbol, TF(), 0);
   const double lo = iLow(_Symbol, TF(), 0);
   const double op = iOpen(_Symbol, TF(), 0);
   const double cl = iClose(_Symbol, TF(), 0);
   if(hi <= lo || op <= 0.0 || cl == op)
     {
      g_block = "brak kierunku";
      return false;
     }
   const double rng  = hi - lo;
   const double disp = MathAbs(cl - op);
   const double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double minR = (InpRapidMinPoints > 0 && pt > 0.0) ? InpRapidMinPoints * pt : 0.0;
   const double need = MathMax(atr * InpRapidAtrMult, minR);
   if(rng < need)
     {
      g_block = "krotki slup";
      return false;
     }
   const double body = disp / rng;
   if(body < 0.25)
     {
      g_block = "doji";
      return false;
     }
   buy = (cl > op);
   if(strict)
     {
      if(InpRapidBodyRatio > 0.0 && body < InpRapidBodyRatio)
        {
         g_block = "maly korpus";
         return false;
        }
      if(InpRapidClosePos > 0.0)
        {
         const double tail = buy ? ((hi - cl) / rng) : ((cl - lo) / rng);
         if(tail > InpRapidClosePos)
           {
            g_block = "close nie przy ekstremum";
            return false;
           }
        }
     }
   if(InpRapidVelocitySec > 0 && !g_velOk)
     {
      g_block = "vel wait";
      return false;
     }
   if(!M1Confirm(buy)) return false;
   if(!RegimeOk(buy)) return false;
   return true;
  }

bool RangeExhausted()
  {
   if(InpRapidAtrMax <= 0.0 || InpRapidAtrMax < InpRapidAtrMult) return false;
   double atr = 0;
   if(!CopyAtr(atr)) return false;
   const double rng = iHigh(_Symbol, TF(), 0) - iLow(_Symbol, TF(), 0);
   return (rng >= atr * InpRapidAtrMax);
  }

void ArmImpulse(const bool buy)
  {
   g_armState   = 1;
   g_armBuy     = buy;
   g_armOpen    = iOpen(_Symbol, TF(), 0);
   g_armExtreme = buy ? iHigh(_Symbol, TF(), 0) : iLow(_Symbol, TF(), 0);
   g_lastKind   = buy ? "ARM BUY" : "ARM SELL";
  }

void TryPullback()
  {
   const double op = iOpen(_Symbol, TF(), 0);
   const double cl = iClose(_Symbol, TF(), 0);
   const double hi = iHigh(_Symbol, TF(), 0);
   const double lo = iLow(_Symbol, TF(), 0);
   if(op <= 0.0) return;

   if(g_armBuy)
     {
      if(cl < op) { g_armState = 2; g_block = "arm reverse"; return; }
      g_armExtreme = MathMax(g_armExtreme, hi);
     }
   else
     {
      if(cl > op) { g_armState = 2; g_block = "arm reverse"; return; }
      g_armExtreme = (g_armExtreme <= 0.0) ? lo : MathMin(g_armExtreme, lo);
     }

   if(RangeExhausted())
     {
      g_armState = 2;
      g_block = "too extended";
      return;
     }

   const double impulse = MathAbs(g_armExtreme - g_armOpen);
   if(impulse <= 0.0) return;
   const double retrace = g_armBuy ? (g_armExtreme - cl) : (cl - g_armExtreme);
   const double frac = retrace / impulse;
   const double mx = PullbackMax();
   if(frac > mx)
     {
      g_armState = 2;
      g_block = "pullback too deep";
      return;
     }
   if(frac < PullbackMin()) return;
   if(!RegimeOk(g_armBuy))
     {
      if(StringFind(g_block, "H1") >= 0 || StringFind(g_block, "DI") >= 0)
         g_armState = 2;
      return;
     }
   OpenDir(g_armBuy, g_armBuy ? "RAPID BUY" : "RAPID SELL");
  }

void TryRapid()
  {
   if(!InpUseRapidBar) return;
   if(g_armState == 2) return;

   if(g_armState == 1)
     {
      TryPullback();
      return;
     }

   bool buy = false;
   if(!RapidQualify(buy, true)) return;
   if(RangeExhausted())
     {
      g_block = "too extended";
      return;
     }
   if(PullbackMin() <= 0.0)
      OpenDir(buy, buy ? "RAPID BUY" : "RAPID SELL");
   else
      ArmImpulse(buy);
  }

void AbortRapidWick()
  {
   if(!InpRapidAbortWick) return;
   const double op = iOpen(_Symbol, TF(), 0);
   const double cl = iClose(_Symbol, TF(), 0);
   const double hi = iHigh(_Symbol, TF(), 0);
   const double lo = iLow(_Symbol, TF(), 0);
   if(hi <= lo || op <= 0.0) return;
   const double body = MathAbs(cl - op) / (hi - lo);
   if(body >= InpRapidAbortBody)
     {
      g_wickSince = 0;
      return;
     }

   bool hit = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(!Ours(t)) continue;
      const string c = PositionGetString(POSITION_COMMENT);
      if(StringFind(c, "RAPID") < 0) continue;
      const datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(iBarShift(_Symbol, TF(), ot, false) != 0) continue;
      const bool buy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(buy && cl < op) hit = true;
      if(!buy && cl > op) hit = true;
     }
   if(!hit)
     {
      g_wickSince = 0;
      return;
     }
   if(InpRapidAbortSec > 0)
     {
      if(g_wickSince <= 0) g_wickSince = TimeCurrent();
      if((TimeCurrent() - g_wickSince) < InpRapidAbortSec) return;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(!Ours(t)) continue;
      const string c = PositionGetString(POSITION_COMMENT);
      if(StringFind(c, "RAPID") < 0) continue;
      const datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(iBarShift(_Symbol, TF(), ot, false) != 0) continue;
      const bool buy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if((buy && cl < op) || (!buy && cl > op))
         CloseTicket(t, "Rapid wick");
     }
   g_wickSince = 0;
  }

void ManageStops()
  {
   double atr = 0;
   const bool haveAtr = CopyAtr(atr);
   const double md = MinStop();
   const int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!Ours(ticket)) continue;
      const bool buy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);
      const double px = buy ? bid : ask;
      if(entry <= 0.0 || px <= 0.0) continue;
      const double profit = buy ? (bid - entry) : (entry - ask);
      const double spread = SpreadPx();
      double newSL = curSL;
      const double be = buy ? TickRound(entry + md) : TickRound(entry - md);

      if(haveAtr && InpBeAtrMult > 0.0 && profit >= atr * InpBeAtrMult && profit > spread)
        {
         if(BetterSL(buy, be, newSL)) newSL = be;
        }
      if(haveAtr && InpTrailAtrMult > 0.0 && profit > spread)
        {
         const double tr = buy ? TickRound(bid - atr * InpTrailAtrMult)
                               : TickRound(ask + atr * InpTrailAtrMult);
         const bool atOrBeyondBe = buy ? (tr >= be) : (tr <= be);
         if(atOrBeyondBe && BetterSL(buy, tr, newSL)) newSL = tr;
        }
      if(InpTrailM1 && profit > spread)
        {
         const double m1 = buy ? iLow(_Symbol, PERIOD_M1, 1) : iHigh(_Symbol, PERIOD_M1, 1);
         if(m1 > 0.0)
           {
            const double tr = buy ? TickRound(m1 - md) : TickRound(m1 + md);
            const bool atOrBeyondBe = buy ? (tr >= be) : (tr <= be);
            if(atOrBeyondBe && BetterSL(buy, tr, newSL)) newSL = tr;
           }
        }

      newSL = NormalizeDouble(TickRound(newSL), dg);
      if(!BetterSL(buy, newSL, curSL)) continue;
      const double dist = buy ? (px - newSL) : (newSL - px);
      if(dist < md) continue;
      if(!g_trade.PositionModify(ticket, newSL, curTP))
        {
         const uint rc = g_trade.ResultRetcode();
         if(rc != TRADE_RETCODE_INVALID_STOPS && rc != TRADE_RETCODE_INVALID_PRICE)
            Print("Trail/BE fail #", ticket, " ", g_trade.ResultRetcodeDescription());
        }
     }
  }

void Draw()
  {
   if(!InpShowComments) return;
   double atr = 0;
   CopyAtr(atr);
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double op = iOpen(_Symbol, TF(), 0);
   const double cl = iClose(_Symbol, TF(), 0);
   const double rng = iHigh(_Symbol, TF(), 0) - iLow(_Symbol, TF(), 0);
   const double disp = MathAbs(cl - op);
   string arm = "idle";
   if(g_armState == 1) arm = g_armBuy ? "ARM BUY" : "ARM SELL";
   else if(g_armState == 2) arm = "done";
   string regime = "";
   if(InpUseAdxFilter)
     {
      double adx[];
      if(CopyClosedBuf(g_adxHandle, 0, 1, adx))
         regime += "  ADX=" + DoubleToString(adx[0], 1);
      else
         regime += "  ADX=?";
     }
   if(InpUseH1Ema)
     {
      double ema[];
      const double h1c = iClose(_Symbol, PERIOD_H1, 1);
      if(CopyClosedBuf(g_h1EmaHandle, 0, 1, ema) && h1c > 0.0 && ema[0] > 0.0)
         regime += (h1c > ema[0] ? "  H1+" : (h1c < ema[0] ? "  H1-" : "  H1="));
      else
         regime += "  H1=?";
     }
   Comment(
      "Event_Scalp v2.27  ", EnumToString(TF()), "\n",
      "Session: ", (InpUseSessionFilter ? ("ON " + SessionStatusText()
                   + (IsInTradingSession() ? " OPEN" : " CLOSED")) : "OFF"), "\n",
      "Rapid: ", InpUseRapidBar ? "ON" : "OFF",
      "  ", arm,
      "  vel=", (g_velOk ? "OK" : "wait"),
      "  ATR=", DoubleToString(atr, _Digits),
      regime, "\n",
      "disp=", DoubleToString(pt > 0 ? disp / pt : 0, 0),
      "  rng=", DoubleToString(pt > 0 ? rng / pt : 0, 0), " pkt",
      "  min=", DoubleToString((pt > 0 && atr > 0) ? atr * InpRapidAtrMult / pt : 0, 0),
      "  body=", DoubleToString((rng > 0) ? 100.0 * disp / rng : 0, 0), "%\n",
      g_lastKind, (g_block != "" ? (" | " + g_block) : ""), "\n",
      "Pos ", CountOurs(), "/", g_maxPos,
      "  hold ", ClampHold(),
      "  CD ", g_cooldown,
      "  spr ", DoubleToString(pt > 0 ? SpreadPx() / pt : 0, 0),
      (InpMaxDailyLossPct > 0.0
         ? ("  dd " + DoubleToString(DayLossPct(), 2) + "/" + DoubleToString(InpMaxDailyLossPct, 1) + "%")
         : "  dd OFF")
   );
  }

int OnInit()
  {
   if(!InpUseRapidBar)
     {
      Print("Wlacz Rapid bar.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!IsValidHour(InpSession1StartHour) || !IsValidHour(InpSession1EndHour) ||
      !IsValidHour(InpSession2StartHour) || !IsValidHour(InpSession2EndHour))
     {
      Print("Session hours must be 0-23.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpUseAdxFilter && InpAdxPeriod < 2)
     {
      Print("ADX period must be >= 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpUseH1Ema && InpH1EmaPeriod < 2)
     {
      Print("H1 EMA period must be >= 2.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_maxPos = ClampMaxPos();
   g_atrHandle = iATR(_Symbol, TF(), ATR_PERIOD);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("iATR fail ", GetLastError());
      return INIT_FAILED;
     }

   g_adxHandle = INVALID_HANDLE;
   if(InpUseAdxFilter)
     {
      g_adxHandle = iADX(_Symbol, TF(), InpAdxPeriod);
      if(g_adxHandle == INVALID_HANDLE)
         Print("iADX fail ", GetLastError(), " — puszczam bez filtra chop");
     }

   g_h1EmaHandle = INVALID_HANDLE;
   if(InpUseH1Ema)
     {
      g_h1EmaHandle = iMA(_Symbol, PERIOD_H1, InpH1EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_h1EmaHandle == INVALID_HANDLE)
         Print("H1 iMA fail ", GetLastError(), " — puszczam bez HTF");
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(SLIPPAGE_POINTS);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   HoldRebuild();
   DayReset();
   ResetBarState();
   g_barTime = iTime(_Symbol, TF(), 0);
   g_m1Warn = false;
   g_adxWarn = false;
   g_h1Warn = false;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("UWAGA: AutoTrading OFF");

   Print("Event_Scalp 2.27 M15 Rapid rng>=ATR*", DoubleToString(InpRapidAtrMult, 2),
         " SL/TP ATR ", InpUseAtrStops, " ", DoubleToString(InpSlAtrMult, 2), "/",
         DoubleToString(InpTpAtrMult, 2),
         " pullback=", DoubleToString(PullbackMin(), 2), "-", DoubleToString(PullbackMax(), 2),
         " ADX=", (InpUseAdxFilter ? DoubleToString(InpAdxMin, 0) : "OFF"),
         " H1EMA=", (InpUseH1Ema ? IntegerToString(InpH1EmaPeriod) : "OFF"),
         " ATRratio=", (InpUseAtrRegime ? DoubleToString(InpMinAtrRatio, 2) : "OFF"),
         " | session=", (InpUseSessionFilter ? SessionStatusText() : "OFF"),
         " dailyLoss=", (InpMaxDailyLossPct > 0.0 ? (DoubleToString(InpMaxDailyLossPct, 1) + "%") : "OFF"));
   Print("Reset Inputow w MT5 (prawy klik na EA -> Reset) jesli widzisz stare 2.26 bez daily loss.");

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_adxHandle != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   if(g_h1EmaHandle != INVALID_HANDLE) IndicatorRelease(g_h1EmaHandle);
   Comment("");
  }

void OnTick()
  {
   EnsureDay();
   HoldPrune();
   if(NewBar())
     {
      g_openedBar = false;
      g_block = "";
      HoldExpire();
      if(g_cooldown > 0) g_cooldown--;
      ResetBarState();
     }
   UpdateVelocity();
   AbortRapidWick();
   ManageStops();
   TryRapid();
   Draw();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   const ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal)) return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) return;
   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   RefreshDayClosedPnl();
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;
   if(reason != DEAL_REASON_SL) return;
   if(InpCooldownAfterSL > 0)
      g_cooldown = MathMax(g_cooldown, InpCooldownAfterSL);
  }
//+------------------------------------------------------------------+
