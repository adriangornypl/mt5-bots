# How the robots work

A plain-language guide to the Expert Advisors in this folder. It describes **what each robot is trying to do**, not every input. Compiled defaults can differ from what you see on a chart or in the tester until you click **Reset**.

Longer beginner write-ups:

- [Event_Scalp](how-event-scalp-works.md)
- [MACD_RSI_Cross_Bull](how-macd-rsi-cross-bull-works.md)
- [MACD_RSI_Cross_Bear](how-macd-rsi-cross-bear-works.md)
- [Stochastic_Trend](how-stochastic-trend-works.md)

All of them:

- Trade only the chart symbol, and only positions with **their own magic number** (they can run side by side).
- Use a **signal timeframe** (`InpTimeframe`). If that is “current”, they use the chart’s timeframe. When docs say “bars”, they mean **candles on that timeframe**, not minutes on the clock.
- Limit **new entries** to session hours when that filter is on (London + New York windows by default). Stops, take-profit, and time-based exits still work after the session.
- Need **Algo Trading** enabled. Stochastic news (if you turn it on) also needs the API URL on MetaTrader’s WebRequest allow-list.

---

## Event_Scalp — catch a sudden large candle

**File:** `Event_Scalp.mq5` · **Magic:** 26091401 · **Typical chart:** M15 FX (e.g. EURUSD)

This is a **short-hold impulse** robot (it started as an M5 scalper). It does **not** wait for a Stochastic or MACD trend, and it does **not** read a news calendar. It looks for an **unusually long candle** on the bar that is still forming: range vs ATR plus a minimum size in points.

### When it buys or sells

**Rapid bar** (every tick): the **range** of the current candle (high−low) compared with ATR of the **last closed** bar. Direction is close versus open. Default: wait for a **pullback** on that same candle (set pullback to 0 to chase immediately). At most one new Rapid shot per candle; default max is **three** open positions. Closed-bar ADX/ATR skip dead chop; hourly EMA is optional and off by default. A **daily loss cap** (default 2%) blocks new entries for the rest of the server day. It does **not** chase tick bursts.

### When it exits

ATR (or point) stop and take-profit, optional breakeven and trailing (trail only after spread is covered, never below break-even), a wick abort if the rapid bar fails and stays failed for a few seconds, and a hard **max bars** hold.

### Mental model

“Something violent is happening **right now** on this M15, and ATR/ADX are not dead. Wait for a dip inside that candle, get out quickly.”

It is the odd one out: the other two wait for a **closed** candle and a slower trend/oscillator story.

---

## MACD_RSI_Cross_Bull — ride the EMA/SMA trend until it flips

**File:** `MACD_RSI_Cross_Bull.mq5` · **Magic:** 18300621 · **Typical use:** M15 / H1 mid-term, closed candles

This robot uses a **fast EMA vs a slower SMA** as the **allowed side**, then tries **three ways in** on each **new closed bar**. Only **one successful open per bar**. If the first idea *wants* to trade but cannot (outside session, ADX filter, already in a trade), the next idea is still allowed to try.

**Trend follow is on by default.** If the averages say **down**, it only sells, and it **holds that short until the averages flip** (or the stop is hit). It will not buy “cheap RSI” against that downtrend, and a brief MACD uptick will not flatten the short.

You can turn Trend follow **off** to get the older fade / short-hold stack. After a compile, **Reset** inputs — old tester sets still have a 10-bar time-stop and a take-profit that cut trends short.

### The trend (EMA vs SMA)

Fast EMA above slow SMA → **buys only**. Fast EMA below slow SMA → **sells only**. When they flip, open tickets on the old side are closed. That close still runs **outside** session hours.

### Priority 1 — RSI pullback *with* the trend

In an uptrend, closed RSI below oversold → **buy the dip**. In a downtrend, closed RSI above overbought → **sell the rally**. After a fill it will not spam the same zone; it waits until RSI leaves the zone and comes back.

(If Trend follow is off, this idea **fades** extremes instead: oversold → buy even in a downtrend.)

### Priority 2 — fast EMA vs slow SMA cross

A classic cross on the **closed** bar. Up-cross → buy (uptrend start), down-cross → sell (downtrend start). RSI confirmation is **not** applied here. This is how a new ride often begins.

### Priority 3 — MACD cross (optional RSI confirm)

MACD line crossing its signal line, **only in the EMA/SMA direction**. By default it then waits a few bars for RSI to be on the right side of 30 (buy) or 70 (sell). If MACD turns the other way first, or the averages disagree, the wait is cancelled. Pending MACD waits are also dropped if the session closes.

### Shared gates

- **ADX** (on by default): only **open** if the market is trending hard enough, and optionally if +DI/−DI agrees. The flip-close does not wait for ADX.
- Default is **one position**. You can allow stacking in the **same** direction (max 30).
- **Take profit** default is 5000 points. Set 0 for no target.
- **Time-stop** default is 30 candles (`MaxBarsHold`). Set 0 to ride until flip / SL.
- **Session filter is on by default** (London + New York windows).
- **Daily stop** (off by default, **0**): **% of balance**. If this robot is down that percent in the current session window, it opens nothing until the next window. Open trades are not force-closed.
- On FX, **triple-swap** is on by default: flatten about an hour before the broker’s 3-day swap (often Wednesday night) and reopen the next day if the time-stop (when used) and the averages still agree.

Stops are in **points** by default (recommended). There is a percent mode, but it is percent of **price**, not of your account — easy to misread.

### Mental model

“Are the averages down? Stay short until they aren’t. Enter on the death cross, or on a rally (RSI overbought) / MACD continuation while still down. Do not fade the trend.”

---

## MACD_RSI_Cross_Bear — same family, built for the down-leg

**File:** `MACD_RSI_Cross_Bear.mq5` · **Magic:** 18300622 · **Typical use:** EURUSD M15 when you want the original idea **without death-cross entries**

A **separate** expert. Do not mix its inputs with `MACD_RSI_Cross_Bull`. It still only trades **with** EMA vs SMA, but:

- The **hourly** averages must agree before a new trade.
- It does **not** open on the M15 MA cross (that is only direction + a delayed flip-close).
- Shorts use a **wider stop**, **no time cap**, RSI rally at **60**, and MACD shorts need RSI **under 50**.
- A short that bounces the wrong way for many candles can be closed; a short in profit can move to break-even.

Use this on its own chart if the original made money in a rise and gave it back when the market turned down.

---

## Stochastic_Trend — only with the EMA trend

**File:** `Stochastic_Trend.mq5` · **Magic:** 26091211 · **Typical use:** US30 / indices, but it can run on FX

This is a **trend-following oscillator**. The two EMAs (fast 81 / slow 255 by default) decide the **allowed side**:

- Fast EMA above slow → **buys only**
- Fast EMA below slow → **sells only**

The EMAs do **not** open trades by themselves. They also **close** trades when they flip, with no extra “strength” test. Each ticket also dies after a max number of bars if the trend has not flipped.

### When it opens

On a **closed** bar, using either:

- **Stochastic** (default): %K crossing %D, optionally only from oversold (buy) or overbought (sell). The price field should match the Stochastic on your chart (MT5 default is Low/High).
- **RSI**: either leaving oversold/overbought (when “require extreme” is on) or crossing the 50 line (when it is off).

**Require extreme** applies to **both** oscillators and defaults **on**, so many mid-range crosses are ignored. The Strategy Tester often keeps an old saved set — use Reset if behaviour looks wrong.

Optional **ADX** (on by default here) only asks “is there enough trend strength?”. It does **not** check +DI vs −DI (that is a MACD_RSI_Cross_Bull feature).

### Adding to a winner (pyramid)

If the EMA side has not changed and you already have a position, it can add another ticket every N bars, up to a max count. Each add is a **separate** position with its own stop, target, and hold timer. At most one new ticket per bar.

Those adds are **not** blocked by the session clock (the first oscillator entry is). Spacing is the “add every N bars” setting.

### Extra exits

Besides EMA flip, max bars, SL, and TP:

- **Opposite extreme** (on by default): while you are long, if the oscillator reaches overbought and later falls to oversold, flatten everything (and the mirror for shorts). This can fire even when entries were forced to start at the “right” extreme.
- **News** (off by default): optional calendar API. Mild news blocks the opposite side. A **flip** closes the other side and can force an entry for a few bars, even if the EMA disagrees, with a larger lot.

### Mental model

“Only trade pullbacks **in the EMA direction**. Scale in while that trend lasts. Get out when the EMAs cross, time runs out, or the oscillator makes a full round trip against you.”

Stops are in MetaTrader **points** (`SYMBOL_POINT`). On a US30 chart with 2 decimal places, “400 points” is 4.00 index points, not 400 Dow points.

---

## How to tell them apart

| | Event_Scalp | MACD_RSI_Cross_Bull | MACD_RSI_Cross_Bear | Stochastic_Trend |
|---|---|---|---|---|
| Idea | Impulse on the **current** candle | EMA/SMA trend + closed-bar RSI/MACD (fade only if Trend follow off) | Same family; **H1 gate**; **no MA-cross entry** | Oscillator **with** EMA trend |
| Typical market | FX M15 large candles | FX or CFDs, **M15 / H1** | FX M15 when the original leaks on the down-leg | Indices (US30), also FX |
| News | None | None | None | Optional override |
| Extra skip | Chop / dead ATR (H1 EMA optional, off) | Against EMA/SMA; ADX; session | HTF disagree; thin MA gap; ADX strength | Weak ADX, news opposite |
| Adds extra positions | Default: up to three Rapid tickets | Optional same-direction stack (one ticket by default) | One ticket by default | Pyramid every N bars in the same EMA trend |
| Main “get out” besides SL/TP | Short hold, trail, wick abort | **EMA/SMA flip**; 30-bar hold; TP 5000 | **Delayed** MA flip; short bounce-hold / BE | EMA flip, bar-count, opposite oscillator extreme |
| Triple-swap flatten (FX) | No | Yes (reopen if averages agree) | Yes; **keep shorts** if H1 still down | Yes (default on) |

---

## Practical notes for running them

- **Do not share magic numbers.** They are already different.
- **One robot per chart** is the usual setup. Several charts / symbols is fine.
- Changing defaults in the source does nothing on a chart that already has saved inputs until **Reset**.
- Session hours are **inclusive** (8–16 means 08:00 through 16:59). If end is before start, the window wraps midnight.
- If Stochastic news is on, add the exact URL under Tools → Options → Expert Advisors → Allow WebRequest.
