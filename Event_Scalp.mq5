//+------------------------------------------------------------------+
//|                                                   Event_Scalp.mq5 |
//|  M5 scalp: news + rapid impulse on the same candle.               |
//|  Rapid: long bar = range vs ATR, entry on the same candle.        |
//|  Exit: ATR SL/TP, BE, trail M1, MaxBarsHold (Rapid/News).         |
//+------------------------------------------------------------------+
#property copyright "My robots"
#property version   "2.11"
#property strict

#include <Trade\Trade.mqh>

#define SLIPPAGE_POINTS      30
#define MAX_POSITIONS_CAP    20
#define NEWS_HTTP_TIMEOUT_MS 4000
#define NEWS_MAX_PAGES       50
#define ATR_PERIOD           14

enum ENUM_SESSION_CLOCK
  {
   SESSION_CLOCK_SERVER = 0, // Broker server time
   SESSION_CLOCK_GMT    = 1, // GMT / UTC
   SESSION_CLOCK_LOCAL  = 2  // PC local time
  };

//==================== SIGNALS =======================================
input group "=== Sygnaly ==="
input bool            InpUseNewsSignal    = true;   // News (primary)
input bool            InpUseRapidBar      = true;   // Rapid bar (ATR)
input bool            InpNewsRequireRapid = false;  // News only with matching Rapid

input group "=== Rapid bar ==="
input double          InpRapidAtrMult     = 1.0;    // Min. candle RANGE = ATR * this
input double          InpRapidAtrMax      = 0.2;    // Skip when range >= ATR * this (0=off; < min = off)
input int             InpRapidMinPoints   = 40;     // Min. range in points (0=off)
input double          InpRapidBodyRatio   = 0.55;   // Min. |close-open| / range (0=off)
input double          InpRapidClosePos    = 0.10;   // Close in the last X of the range (0=off)
input double          InpRapidPullbackMin = 0.30;   // Enter after pullback (0=immediately on the bar)
input double          InpRapidPullbackMax = 0.55;   // Too deep pullback = abort
input bool            InpRapidUseM1       = true;   // M1 confirmation
input int             InpRapidM1Bars      = 2;      // How many M1 bars in direction (0 = current)
input int             InpRapidVelocitySec = 0;      // 0=off. Max seconds from bar open
input double          InpRapidVelocityAtr = 0.70;   // ATR required to count as velocity
input bool            InpRapidAbortWick   = true;   // Close Rapid when a wick reverses the bar
input double          InpRapidAbortBody   = 0.35;   // Abort when body < this and close crosses open

input group "=== Trade ==="
input double          InpLots             = 0.10;   // Lot
input bool            InpUseAtrStops      = true;   // SL/TP from ATR (otherwise points)
input double          InpSlAtrMult        = 1.3;    // SL = ATR * this
input double          InpTpAtrMult        = 2.0;    // TP = ATR * this
input bool            InpUseStructSl      = false;  // SL beyond current M5 low/high
input int             InpStopLossPoints   = 400;    // SL fallback (SYMBOL_POINT)
input int             InpTakeProfitPoints = 500;    // TP fallback
input double          InpBeAtrMult        = 0.50;   // BE after +ATR*this (0=off)
input double          InpTrailAtrMult     = 0.10;   // Trail ATR (0=off)
input bool            InpTrailM1          = false;  // Trail behind M1 swing
input double          InpSpreadMaxPctSl   = 0.0;    // Skip when spread > % of SL (0=off)
input int             InpMaxPositions     = 4;      // Max open positions
input int             InpMaxBarsHold      = 7;      // Hold Rapid (TF bars)
input int             InpMaxBarsHoldNews  = 5;      // Hold News (TF bars)
input int             InpCooldownBars     = 0;      // Pause after open (bars)
input int             InpCooldownAfterSL  = 1;      // Pause after SL (bars)
input int             InpNewsConfirmBars  = 4;      // News waits for Rapid (bars)

// Hours are inclusive (8 and 17 = 08:00-17:59). End < start wraps midnight.
input group "=== Session hours ==="
input bool            InpUseSessionFilter = true;   // Limit NEW entries to session hours
input ENUM_SESSION_CLOCK InpSessionClock  = SESSION_CLOCK_SERVER; // Clock for hours below
input int             InpSession1StartHour = 8;     // Window 1 start hour 0-23 (London ~08)
input int             InpSession1EndHour  = 17;     // Window 1 end hour 0-23 inclusive
input bool            InpUseSession2      = true;   // Second window (NY overlap)
input int             InpSession2StartHour = 13;    // Window 2 start hour 0-23 (NY ~13)
input int             InpSession2EndHour  = 21;     // Window 2 end hour 0-23 inclusive

input group "=== News API ==="
input string          InpNewsApiUrl       = "";     // GET URL
input string          InpNewsApiToken     = "";     // Bearer
input int             InpNewsPollSeconds  = 5;      // Poll (s)
input datetime        InpNewsBackfillFrom = D'2026.01.01 00:00:00'; // History from
input double          InpNewsFlipLotMult  = 1.5;    // Lot after pos<->neg flip

input group "=== Ogolne ==="
input ulong           InpMagic            = 26091401;
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;
input bool            InpShowComments     = true;

enum ENUM_NEWS_SENT
  {
   NEWS_NONE = 0,
   NEWS_NEUTRAL,
   NEWS_POSITIVE,
   NEWS_NEGATIVE
  };

struct NewsItem
  {
   datetime       when;
   ENUM_NEWS_SENT sent;
   string         raw;
  };

int      g_atrHandle = INVALID_HANDLE;
datetime g_barTime = 0;
CTrade   g_trade;

ulong    g_tickets[];
int      g_held[];
int      g_holdCap[];

int      g_maxPos = 4;
int      g_cooldown = 0;
bool     g_openedBar = false;
string   g_lastKind = "-";
string   g_block = "";

bool           g_newsReady = false;
datetime       g_newsCutoff = 0;
string         g_newsStatus = "OFF";
string         g_newsErrOnce = "";
bool           g_newsBadOnce = false;
ENUM_NEWS_SENT g_newsLast = NEWS_NONE;
bool           g_flipLot = false;
ENUM_NEWS_SENT g_newsPend = NEWS_NONE;
string         g_newsPendRaw = "";
int            g_newsPendAge = 0;

int      g_armState = 0; // 0 idle, 1 armed, 2 done this bar
bool     g_armBuy = false;
double   g_armOpen = 0;
double   g_armExtreme = 0;
bool     g_velOk = false;
bool     g_m1Warn = false;

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

int ClampHoldNews()
  {
   return MathMax(1, InpMaxBarsHoldNews);
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

bool NewsNeedsRapid()
  {
   return (InpNewsRequireRapid && InpUseRapidBar && InpUseNewsSignal);
  }

ENUM_NEWS_SENT ParseSent(string s)
  {
   StringTrimLeft(s); StringTrimRight(s); StringToLower(s);
   if(s == "positive") return NEWS_POSITIVE;
   if(s == "negative") return NEWS_NEGATIVE;
   if(s == "neutral")  return NEWS_NEUTRAL;
   return NEWS_NONE;
  }

string SentText(const ENUM_NEWS_SENT s)
  {
   if(s == NEWS_POSITIVE) return "positive";
   if(s == NEWS_NEGATIVE) return "negative";
   if(s == NEWS_NEUTRAL)  return "neutral";
   return "none";
  }

string FmtNewsDate(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return StringFormat("%02d-%02d-%04d %02d:%02d:%02d",
                       d.day, d.mon, d.year, d.hour, d.min, d.sec);
  }

bool ParseNewsDate(string raw, datetime &out)
  {
   out = 0;
   StringTrimLeft(raw); StringTrimRight(raw);
   string p[], dp[], tp[];
   if(StringSplit(raw, ' ', p) < 2) return false;
   if(StringSplit(p[0], '-', dp) != 3) return false;
   if(StringSplit(p[1], ':', tp) < 2) return false;
   MqlDateTime d;
   ZeroMemory(d);
   d.day  = (int)StringToInteger(dp[0]);
   d.mon  = (int)StringToInteger(dp[1]);
   d.year = (int)StringToInteger(dp[2]);
   d.hour = (int)StringToInteger(tp[0]);
   d.min  = (int)StringToInteger(tp[1]);
   d.sec  = (ArraySize(tp) >= 3) ? (int)StringToInteger(tp[2]) : 0;
   if(d.year < 1970 || d.mon < 1 || d.mon > 12 || d.day < 1) return false;
   out = StructToTime(d);
   return (out > 0);
  }

string UrlEnc(string s)
  {
   StringReplace(s, " ", "%20");
   return s;
  }

string NewsUrl(const int page)
  {
   string url = InpNewsApiUrl;
   const string q = "page=" + IntegerToString(MathMax(page, 1))
                    + "&from=" + UrlEnc(FmtNewsDate(InpNewsBackfillFrom));
   return url + ((StringFind(url, "?") >= 0) ? "&" : "?") + q;
  }

int JsonArrayStart(const string json)
  {
   int key = StringFind(json, "\"data\"");
   if(key < 0) key = StringFind(json, "\"news\"");
   int s = (key >= 0) ? StringFind(json, "[", key) : -1;
   if(s < 0) s = StringFind(json, "[");
   return s;
  }

bool JsonField(const string obj, const string key, string &out)
  {
   out = "";
   const int k = StringFind(obj, "\"" + key + "\"");
   if(k < 0) return false;
   const int colon = StringFind(obj, ":", k);
   if(colon < 0) return false;
   const int n = StringLen(obj);
   int i = colon + 1;
   while(i < n)
     {
      const ushort c = (ushort)StringGetCharacter(obj, i);
      if(c == ' ' || c == '\t' || c == '\r' || c == '\n') { i++; continue; }
      if(c != '"') return false;
      i++;
      string cur = "";
      bool esc = false;
      for(; i < n; i++)
        {
         const ushort ch = (ushort)StringGetCharacter(obj, i);
         if(esc) { cur += ShortToString(ch); esc = false; continue; }
         if(ch == '\\') { esc = true; continue; }
         if(ch == '"') { out = cur; return true; }
         cur += ShortToString(ch);
        }
      return false;
     }
   return false;
  }

void JsonObjects(const string json, const int from, string &objs[])
  {
   ArrayResize(objs, 0);
   int depth = 0, start = -1;
   bool inStr = false, esc = false;
   const int n = StringLen(json);
   for(int i = from; i < n; i++)
     {
      const ushort c = (ushort)StringGetCharacter(json, i);
      if(esc) { esc = false; continue; }
      if(c == '\\' && inStr) { esc = true; continue; }
      if(c == '"') { inStr = !inStr; continue; }
      if(inStr) continue;
      if(c == '{') { if(depth == 0) start = i; depth++; }
      else if(c == '}')
        {
         depth--;
         if(depth == 0 && start >= 0)
           {
            const int k = ArraySize(objs);
            ArrayResize(objs, k + 1);
            objs[k] = StringSubstr(json, start, i - start + 1);
            start = -1;
           }
        }
      else if(c == ']' && depth == 0)
         break;
     }
  }

void NewsBadOnce(const string d)
  {
   if(g_newsBadOnce) return;
   g_newsBadOnce = true;
   Print("News: zly rekord (raz): ", d);
  }

int ParseNewsJson(const string json, NewsItem &out[])
  {
   ArrayResize(out, 0);
   const int start = JsonArrayStart(json);
   if(start < 0) return -1;
   string objs[];
   JsonObjects(json, start, objs);
   for(int i = 0; i < ArraySize(objs); i++)
     {
      string ds, ss;
      if(!JsonField(objs[i], "date", ds) || !JsonField(objs[i], "signal", ss))
        { NewsBadOnce("brak date/signal"); continue; }
      datetime when = 0;
      if(!ParseNewsDate(ds, when))
        { NewsBadOnce("data " + ds); continue; }
      const ENUM_NEWS_SENT sent = ParseSent(ss);
      if(sent == NEWS_NONE)
        { NewsBadOnce("signal " + ss); continue; }
      const int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k].when = when;
      out[k].sent = sent;
      out[k].raw  = ss;
     }
   return ArraySize(out);
  }

void SortNews(NewsItem &a[])
  {
   for(int i = 1; i < ArraySize(a); i++)
     {
      NewsItem key = a[i];
      int j = i - 1;
      while(j >= 0 && a[j].when > key.when) { a[j + 1] = a[j]; j--; }
      a[j + 1] = key;
     }
  }

bool NewsHas(const NewsItem &a[], const NewsItem &x)
  {
   for(int i = 0; i < ArraySize(a); i++)
      if(a[i].when == x.when && a[i].sent == x.sent) return true;
   return false;
  }

void NewsPush(NewsItem &dst[], const NewsItem &x)
  {
   if(NewsHas(dst, x)) return;
   const int k = ArraySize(dst);
   ArrayResize(dst, k + 1);
   dst[k] = x;
  }

void NewsPushAll(NewsItem &dst[], const NewsItem &src[])
  {
   for(int i = 0; i < ArraySize(src); i++) NewsPush(dst, src[i]);
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

int HoldCapFromComment(const string c)
  {
   if(StringFind(c, "NEWS") >= 0) return ClampHoldNews();
   return ClampHold();
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
      HoldAdd(t, (sh < 0) ? 0 : sh, HoldCapFromComment(PositionGetString(POSITION_COMMENT)));
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

void CloseType(const ENUM_POSITION_TYPE ty, const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(!Ours(t)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ty) continue;
      CloseTicket(t, why);
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
   if(InpSpreadMaxPctSl <= 0.0) return true;
   const double sl = SlDistance();
   if(sl <= 0.0) return false;
   if(SpreadPx() > sl * InpSpreadMaxPctSl)
     {
      g_block = "spread";
      return false;
     }
   return true;
  }

bool CanOpen()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { g_block = "AutoTrading OFF"; return false; }
   if(InpUseSessionFilter && !IsInTradingSession())
     { g_block = "outside session (" + SessionStatusText() + ")"; return false; }
   if(g_openedBar) { g_block = "juz otwarto na barze"; return false; }
   if(g_cooldown > 0) { g_block = "cooldown"; return false; }
   if(CountOurs() >= g_maxPos) { g_block = "max pozycji"; return false; }
   if(!SpreadOk()) return false;
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
   double l = InpLots;
   if(g_flipLot && InpNewsFlipLotMult > 1.0) l *= InpNewsFlipLotMult;
   return NormVol(l);
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
   g_flipLot   = false;
   g_lastKind  = tag;
   if(StringFind(tag, "NEWS") >= 0)
     {
      g_newsPend = NEWS_NONE;
      g_newsPendRaw = "";
      g_newsPendAge = 0;
     }
   const ulong ticket = Newest(buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   if(ticket == 0) return;
   HoldAdd(ticket, 0, HoldCapFromComment(tag));
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
   const int last = MathMax(0, InpRapidM1Bars);
   for(int i = 0; i <= last; i++)
     {
      const double op = iOpen(_Symbol, PERIOD_M1, i);
      const double cl = iClose(_Symbol, PERIOD_M1, i);
      if(op <= 0.0 || cl <= 0.0) continue;
      if(buy && cl > op) return true;
      if(!buy && cl < op) return true;
     }
   g_block = "M1 przeciwne";
   return false;
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
   return true;
  }

bool RangeExhausted()
  {
   if(InpRapidAtrMax <= 0.0) return false;
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
   OpenDir(g_armBuy, g_armBuy ? "RAPID BUY" : "RAPID SELL");
  }

void TryNewsConfirm()
  {
   if(g_newsPend != NEWS_POSITIVE && g_newsPend != NEWS_NEGATIVE) return;
   bool buy = false;
   if(!RapidQualify(buy, false)) return;
   const bool wantBuy = (g_newsPend == NEWS_POSITIVE);
   if(buy != wantBuy)
     {
      g_block = "news vs rapid mismatch";
      return;
     }
   OpenDir(wantBuy, wantBuy ? "NEWS+RAPID BUY" : "NEWS+RAPID SELL");
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
   if(!RapidQualify(buy, false)) return;
   if(g_newsPend == NEWS_POSITIVE && !buy)
     { g_block = "rapid vs pending news"; return; }
   if(g_newsPend == NEWS_NEGATIVE && buy)
     { g_block = "rapid vs pending news"; return; }

   string tag = buy ? "RAPID BUY" : "RAPID SELL";
   if(g_newsPend == NEWS_POSITIVE || g_newsPend == NEWS_NEGATIVE)
      tag = buy ? "NEWS+RAPID BUY" : "NEWS+RAPID SELL";
   OpenDir(buy, tag);
  }

void ApplyNewsLive(const ENUM_NEWS_SENT sent, const string raw)
  {
   if(sent != NEWS_POSITIVE && sent != NEWS_NEGATIVE) return;
   const bool flip = (g_newsLast != NEWS_NONE && g_newsLast != sent);
   g_newsLast = sent;
   if(flip)
     {
      g_flipLot = true;
      CloseType(sent == NEWS_POSITIVE ? POSITION_TYPE_SELL : POSITION_TYPE_BUY, "news flip");
      g_newsStatus = raw + " | FLIP";
      Print("News FLIP ", raw);
     }
   else
     {
      g_newsStatus = raw;
      Print("News ", raw);
     }

   if(NewsNeedsRapid())
     {
      g_newsPend = sent;
      g_newsPendRaw = raw;
      g_newsPendAge = 0;
      g_newsStatus = raw + " | wait Rapid";
      TryNewsConfirm();
      return;
     }
   OpenDir(sent == NEWS_POSITIVE, sent == NEWS_POSITIVE ? "NEWS BUY" : "NEWS SELL");
  }

void ProcessNews(NewsItem &items[], const bool live)
  {
   SortNews(items);
   datetime maxSeen = g_newsCutoff;
   int n = 0;
   for(int i = 0; i < ArraySize(items); i++)
     {
      if(items[i].when < InpNewsBackfillFrom) continue;
      if(live && items[i].when <= g_newsCutoff) continue;
      if(items[i].sent == NEWS_POSITIVE || items[i].sent == NEWS_NEGATIVE)
        {
         if(live) ApplyNewsLive(items[i].sent, items[i].raw);
         else     g_newsLast = items[i].sent;
        }
      if(items[i].when > maxSeen) maxSeen = items[i].when;
      n++;
     }
   if(maxSeen > g_newsCutoff) g_newsCutoff = maxSeen;
   if(!live)
     {
      if(n <= 0 && g_newsCutoff <= 0) g_newsCutoff = TimeCurrent();
      g_newsReady  = true;
      g_newsStatus = SentText(g_newsLast) + " | memory";
      Print("News backfill n=", n, " last=", SentText(g_newsLast));
     }
  }

bool NewsGet(const int page, string &body)
  {
   body = "";
   if(InpNewsApiUrl == "")
     { g_newsStatus = "brak URL"; return false; }
   string hdr = "";
   if(InpNewsApiToken != "")
      hdr = "Authorization: Bearer " + InpNewsApiToken + "\r\n";
   char data[], res[];
   string rh;
   ArrayResize(data, 0);
   ResetLastError();
   const int http = WebRequest("GET", NewsUrl(page), hdr, NEWS_HTTP_TIMEOUT_MS, data, res, rh);
   if(http == -1)
     {
      const int e = GetLastError();
      g_newsStatus = (e == 4060) ? "4060 Allow WebRequest" : ("err " + IntegerToString(e));
      if(g_newsErrOnce != IntegerToString(e))
        { Print("News WebRequest ", e); g_newsErrOnce = IntegerToString(e); }
      return false;
     }
   if(http != 200)
     {
      g_newsStatus = "HTTP " + IntegerToString(http);
      if(g_newsErrOnce != g_newsStatus)
        { Print("News ", g_newsStatus); g_newsErrOnce = g_newsStatus; }
      return false;
     }
   g_newsErrOnce = "";
   body = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
  }

bool NewsPage(const string body, NewsItem &items[])
  {
   ArrayResize(items, 0);
   if(ParseNewsJson(body, items) < 0)
     {
      g_newsStatus = "zly JSON";
      if(g_newsErrOnce != "json")
        { Print("News JSON: ", StringSubstr(body, 0, 80)); g_newsErrOnce = "json"; }
      return false;
     }
   return true;
  }

void NewsBackfill()
  {
   NewsItem all[];
   ArrayResize(all, 0);
   g_newsStatus = "backfill";
   for(int page = 1; page <= NEWS_MAX_PAGES; page++)
     {
      string body;
      if(!NewsGet(page, body)) return;
      NewsItem pg[];
      if(!NewsPage(body, pg)) return;
      if(ArraySize(pg) <= 0) { Print("News pusta strona ", page); break; }
      for(int i = 0; i < ArraySize(pg); i++)
         if(pg[i].when >= InpNewsBackfillFrom) NewsPush(all, pg[i]);
     }
   ProcessNews(all, false);
  }

void NewsLive()
  {
   NewsItem all[];
   ArrayResize(all, 0);
   bool seenOld = false;
   for(int page = 1; page <= NEWS_MAX_PAGES && !seenOld; page++)
     {
      string body;
      if(!NewsGet(page, body)) return;
      NewsItem pg[];
      if(!NewsPage(body, pg)) return;
      if(ArraySize(pg) <= 0) { if(page == 1) return; break; }
      NewsPushAll(all, pg);
      for(int i = 0; i < ArraySize(pg); i++)
         if(pg[i].when <= g_newsCutoff) { seenOld = true; break; }
     }
   ProcessNews(all, true);
  }

void NewsPoll()
  {
   if(!InpUseNewsSignal) return;
   if(!g_newsReady) NewsBackfill();
   else NewsLive();
  }

void AgeNewsPend()
  {
   if(g_newsPend != NEWS_POSITIVE && g_newsPend != NEWS_NEGATIVE) return;
   g_newsPendAge++;
   if(g_newsPendAge >= MathMax(1, InpNewsConfirmBars))
     {
      Print("News timeout, brak Rapid: ", g_newsPendRaw);
      g_newsStatus = g_newsPendRaw + " | timeout Rapid";
      g_newsPend = NEWS_NONE;
      g_newsPendRaw = "";
      g_newsPendAge = 0;
     }
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
   if(body >= InpRapidAbortBody) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(!Ours(t)) continue;
      const string c = PositionGetString(POSITION_COMMENT);
      if(StringFind(c, "RAPID") < 0 || StringFind(c, "NEWS") >= 0) continue;
      const datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(iBarShift(_Symbol, TF(), ot, false) != 0) continue;
      const bool buy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(buy && cl < op) CloseTicket(t, "Rapid wick");
      if(!buy && cl > op) CloseTicket(t, "Rapid wick");
     }
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
      double newSL = curSL;

      if(haveAtr && InpBeAtrMult > 0.0 && profit >= atr * InpBeAtrMult)
        {
         const double be = buy ? TickRound(entry + md) : TickRound(entry - md);
         if(BetterSL(buy, be, newSL)) newSL = be;
        }
      if(haveAtr && InpTrailAtrMult > 0.0 && profit > 0.0)
        {
         const double tr = buy ? TickRound(bid - atr * InpTrailAtrMult)
                               : TickRound(ask + atr * InpTrailAtrMult);
         if(BetterSL(buy, tr, newSL)) newSL = tr;
        }
      if(InpTrailM1 && profit > 0.0)
        {
         const double m1 = buy ? iLow(_Symbol, PERIOD_M1, 1) : iHigh(_Symbol, PERIOD_M1, 1);
         if(m1 > 0.0)
           {
            const double tr = buy ? TickRound(m1 - md) : TickRound(m1 + md);
            if(BetterSL(buy, tr, newSL)) newSL = tr;
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
   string pend = "";
   if(g_newsPend == NEWS_POSITIVE || g_newsPend == NEWS_NEGATIVE)
      pend = " pend=" + SentText(g_newsPend) + "/" + IntegerToString(g_newsPendAge);
   Comment(
      "Event_Scalp v2.11  ", EnumToString(TF()), "\n",
      "Session: ", (InpUseSessionFilter ? ("ON " + SessionStatusText()
                   + (IsInTradingSession() ? " OPEN" : " CLOSED")) : "OFF"), "\n",
      "News: ", InpUseNewsSignal ? g_newsStatus : "OFF", pend, "\n",
      "Rapid: ", InpUseRapidBar ? "ON" : "OFF",
      "  ", arm,
      "  vel=", (g_velOk ? "OK" : "wait"),
      "  ATR=", DoubleToString(atr, _Digits), "\n",
      "disp=", DoubleToString(pt > 0 ? disp / pt : 0, 0),
      "  rng=", DoubleToString(pt > 0 ? rng / pt : 0, 0), " pkt",
      "  min=", DoubleToString((pt > 0 && atr > 0) ? atr * InpRapidAtrMult / pt : 0, 0),
      "  body=", DoubleToString((rng > 0) ? 100.0 * disp / rng : 0, 0), "%\n",
      g_lastKind, (g_block != "" ? (" | " + g_block) : ""), "\n",
      "Pos ", CountOurs(), "/", g_maxPos,
      "  hold R/N ", ClampHold(), "/", ClampHoldNews(),
      "  CD ", g_cooldown,
      "  spr ", DoubleToString(pt > 0 ? SpreadPx() / pt : 0, 0)
   );
  }

int OnInit()
  {
   if(!InpUseNewsSignal && !InpUseRapidBar)
     {
      Print("Wlacz News i/lub Rapid bar.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!IsValidHour(InpSession1StartHour) || !IsValidHour(InpSession1EndHour) ||
      !IsValidHour(InpSession2StartHour) || !IsValidHour(InpSession2EndHour))
     {
      Print("Session hours must be 0-23.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_maxPos = ClampMaxPos();
   g_atrHandle = iATR(_Symbol, TF(), ATR_PERIOD);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("iATR fail ", GetLastError());
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(SLIPPAGE_POINTS);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   HoldRebuild();
   ResetBarState();
   g_barTime = iTime(_Symbol, TF(), 0);

   g_flipLot = false;
   g_newsReady = false;
   g_newsCutoff = 0;
   g_newsLast = NEWS_NONE;
   g_newsPend = NEWS_NONE;
   g_newsPendRaw = "";
   g_newsPendAge = 0;
   g_newsStatus = InpUseNewsSignal ? "czekam" : "OFF";
   g_m1Warn = false;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("UWAGA: AutoTrading OFF");
   if(InpNewsRequireRapid && InpUseNewsSignal && !InpUseRapidBar)
      Print("UWAGA: NewsRequireRapid ON, ale Rapid OFF — news wejdzie bez potwierdzenia");

   Print("Event_Scalp 2.11 long-bar rng>=ATR*", DoubleToString(InpRapidAtrMult, 2),
         " news=", InpUseNewsSignal, " rapid=", InpUseRapidBar,
         " news&rapid=", NewsNeedsRapid(),
         " SL/TP ATR ", InpUseAtrStops, " ", DoubleToString(InpSlAtrMult, 2), "/",
         DoubleToString(InpTpAtrMult, 2),
         " | session=", (InpUseSessionFilter ? SessionStatusText() : "OFF"));
   Print("Reset Inputow w MT5 (prawy klik na EA -> Reset) jesli widzisz stare Rapid 1.8/M1/pullback.");

   if(InpUseNewsSignal)
     {
      if(InpNewsApiUrl == "") Print("UWAGA: News ON, pusty URL");
      else Print("Allow WebRequest: ", InpNewsApiUrl);
      EventSetTimer(MathMax(InpNewsPollSeconds, 1));
      NewsPoll();
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   Comment("");
  }

void OnTimer()
  {
   NewsPoll();
   Draw();
  }

void OnTick()
  {
   HoldPrune();
   if(NewBar())
     {
      g_openedBar = false;
      g_block = "";
      HoldExpire();
      if(g_cooldown > 0) g_cooldown--;
      AgeNewsPend();
      ResetBarState();
     }
   UpdateVelocity();
   AbortRapidWick();
   ManageStops();
   TryNewsConfirm();
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
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;
   if((ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON) != DEAL_REASON_SL) return;
   if(InpCooldownAfterSL > 0)
      g_cooldown = MathMax(g_cooldown, InpCooldownAfterSL);
  }
//+------------------------------------------------------------------+
