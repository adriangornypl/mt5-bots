# How the robots work

A plain-language guide to the three Expert Advisors in this folder. It describes **what each robot is trying to do**, not every input. Compiled defaults can differ from what you see on a chart or in the tester until you click **Reset**.

Longer beginner write-ups:

- [Event_Scalp](how-event-scalp-works.md)
- [MACD_RSI_Cross](how-macd-rsi-cross-works.md)
- [Stochastic_Trend](how-stochastic-trend-works.md)

All three:

- Trade only the chart symbol, and only positions with **their own magic number** (they can run side by side).
- Use a **signal timeframe** (`InpTimeframe`). If that is “current”, they use the chart’s timeframe. When docs say “bars”, they mean **candles on that timeframe**, not minutes on the clock.
- Limit **new entries** to session hours when that filter is on (London + New York windows by default). Stops, take-profit, and time-based exits still work after the session.
- Need **Algo Trading** enabled. News features also need the API URL on MetaTrader’s WebRequest allow-list.

---

## Event_Scalp — catch a sudden M5 spike

**File:** `Event_Scalp.mq5` · **Magic:** 26091401 · **Typical chart:** M5 FX (e.g. EURUSD)

This is a **scalper**. It does **not** wait for a Stochastic or MACD trend. It looks for a **long impulse candle** on the bar that is still forming (the current M5), from news and/or from a “rapid” range explosion versus ATR.

### When it buys or sells

1. **News** (timer): the API sends `positive` → buy, `negative` → sell, `neutral` → ignore. A flip can close the other side and open larger (lot multiplier).
2. **Rapid bar** (every tick): the **range** of the current candle (high−low) compared with ATR of the **last closed** bar. Direction is close versus open. At most one rapid shot per candle.

You can require news and rapid to agree, or run them independently. They can fight each other if both are on.

### When it exits

ATR (or point) stop and take-profit, optional breakeven and trailing, a wick abort on a failed rapid bar, and a hard **max bars** hold (separate limits for rapid vs news).

### Mental model

“Something violent is happening **right now** on this M5. Get in on that same candle, get out quickly.”

It is the odd one out: the other two wait for a **closed** candle and a slower trend/oscillator story.

---

## MACD_RSI_Cross — three ways in, first one that actually opens

**File:** `MACD_RSI_Cross.mq5` · **Magic:** 18300621 · **Typical use:** swing / intraday on closed candles

This robot stacks **three independent entry ideas** and tries them in order on each **new closed bar**. Only **one successful open per bar**. If the first idea *wants* to trade but cannot (outside session, ADX off, already in a trade), the next idea is still allowed to try. That is intentional.

### Priority 1 — RSI stretched

If the **closed** RSI is below the oversold line, it wants a **buy**. If it is above overbought, it wants a **sell**. It is not limited to the exact bar RSI first crossed the line. After a fill it will not spam the same zone; it waits until RSI leaves the zone and comes back.

This is a mean-reversion poke: “RSI is extreme, fade it.”

### Priority 2 — fast EMA vs slow SMA

A classic cross of a faster EMA through a slower SMA on the **closed** bar. Up-cross → buy, down-cross → sell. RSI confirmation is **not** applied here.

This is a short-term momentum poke.

### Priority 3 — MACD cross (optional RSI confirm)

MACD line crossing its signal line. By default it then waits a few bars for RSI to be on the right side of 40 (buy) or 60 (sell). If MACD turns the other way first, the wait is cancelled. Pending MACD waits are also dropped if the session closes, so they cannot fire at the next open.

### Shared gates

- Optional **ADX** (off by default): only trade if the market is trending hard enough, and optionally if +DI/−DI agrees with the side.
- An **opposite** signal always closes everything this robot has on the symbol, then may reverse.
- Default is **one position**. You can allow stacking in the **same** direction.
- Every position has a **hard time stop** (N candles from open). That counter is based on open time, so it survives restarting the EA.
- On FX, **triple-swap** is on by default: flatten about an hour before the broker’s 3-day swap (often Wednesday night) and reopen the next day if the time-stop still has bars left.

Stops are in **points** by default (recommended). There is a percent mode, but it is percent of **price**, not of your account — easy to misread.

### Mental model

“On this closed candle, is RSI extreme? If not (or that trade could not open), did the moving averages just cross? If not, did MACD just cross with RSI agreeing?” Then ride SL/TP or the bar-count limit.

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

Optional **ADX** (on by default here) only asks “is there enough trend strength?”. It does **not** check +DI vs −DI (that is a MACD_RSI_Cross feature).

### Adding to a winner (pyramid)

If the EMA side has not changed and you already have a position, it can add another ticket every N bars, up to a max count. Each add is a **separate** position with its own stop, target, and hold timer. At most one new ticket per bar.

Those adds are **not** blocked by the session clock (the first oscillator entry is). Spacing is the “add every N bars” setting.

### Extra exits

Besides EMA flip, max bars, SL, and TP:

- **Opposite extreme** (on by default): while you are long, if the oscillator reaches overbought and later falls to oversold, flatten everything (and the mirror for shorts). This can fire even when entries were forced to start at the “right” extreme.
- **News** (off by default): same kind of calendar API as Event_Scalp. Mild news blocks the opposite side. A **flip** closes the other side and can force an entry for a few bars, even if the EMA disagrees, with a larger lot.

### Mental model

“Only trade pullbacks **in the EMA direction**. Scale in while that trend lasts. Get out when the EMAs cross, time runs out, or the oscillator makes a full round trip against you.”

Stops are in MetaTrader **points** (`SYMBOL_POINT`). On a US30 chart with 2 decimal places, “400 points” is 4.00 index points, not 400 Dow points.

---

## How to tell them apart

| | Event_Scalp | MACD_RSI_Cross | Stochastic_Trend |
|---|---|---|---|
| Idea | Impulse on the **current** candle | Three closed-bar recipes, first fill wins | Oscillator **with** EMA trend |
| Typical market | FX M5 news/spikes | FX or CFDs, slower TF | Indices (US30), also FX |
| News | Core signal | None | Optional override |
| Adds extra positions | Up to max, both signals | Optional same-direction stack | Pyramid every N bars in the same EMA trend |
| Main “get out” besides SL/TP | Short hold, trail, wick abort | Bar-count hold; opposite signal flattens | EMA flip, bar-count, opposite oscillator extreme |
| Triple-swap flatten (FX) | No | Yes (default on) | Yes (default on) |

---

## Practical notes for running them

- **Do not share magic numbers.** They are already different.
- **One robot per chart** is the usual setup. Several charts / symbols is fine.
- Changing defaults in the source does nothing on a chart that already has saved inputs until **Reset**.
- Session hours are **inclusive** (8–16 means 08:00 through 16:59). If end is before start, the window wraps midnight.
- For news robots, add the exact URL under Tools → Options → Expert Advisors → Allow WebRequest.
