# How Event_Scalp works (for investors)

This is for someone who can open a chart in MetaTrader 5 but does not program. **It is not a promise of profit.** Scalping sudden candles is risky: spread, slippage, and fake spikes can wipe a run of wins.

## What is this robot for?

`Event_Scalp` does not “ride the trend” like moving averages. It looks for **short, violent moves** — by default on an **M15** chart: a **long candle**, clearly larger than usual compared with ATR (typical range of recent candles), plus a minimum size in points so quiet days do not count.

The aim is to enter **during the same candle** that is still expanding, not wait for it to close (by then the impulse is often over). By default it does **not** buy the spike itself: it waits for a **pullback** inside that candle. It does **not** trade calendar news headlines. Direction comes from the candle itself (close versus open).

## What one trade looks like

**Entry**  
On every tick the robot looks at the **current**, still-open candle (M15 by default). If its range (high to low) is large enough versus ATR **and** a point floor, the body is solid (not a doji), and the close is near the high or low, it **arms** that direction:

- **BUY** — price is above the bar’s open (up impulse),
- **SELL** — price is below (down impulse).

Then, by default, it waits for price to retrace about 50–60% of that impulse before opening. If the candle is already too extended, or the pullback goes too deep, it skips this bar. M1 confirmation is off by default on M15. It may hold up to **three** positions at once.

It also skips **dead markets** on **last completed** candles (not the one still printing, and not raw tick bursts): ADX too weak = chop, ATR much smaller than recently = quiet, take-profit too small versus the current spread = not worth the cost. Hourly EMA bias is available but **off** by default so countertrend spikes can still fill. A pullback that is already armed will wait through chop; if you turn H1 on and it is against the impulse, that shot is cancelled.

Set pullback to `0` if you want an immediate fill on qualify (that chases the spike; it looked good without real ticks and usually fails with them). After compiling, click **Reset** if you want the values from the source, not leftover tester settings.

**Exit** (whichever hits first):

- **Stop loss** — loss cap (often a multiple of ATR).
- **Take profit** — profit target.
- **Time** — a hard limit of signal-timeframe candles (`MaxBarsHold`, 3 × M15 by default) so a dead impulse is not held for hours.
- Sometimes a **wick reversal** on the same candle (the body collapses and price stays the wrong side of the open for a few seconds).
- Optional move of SL to break-even and trailing (trail only after the move has covered the spread, and never below break-even).

Outside session hours (London and New York by default) it **does not open new** positions, but existing ones still have SL/TP and the time limit. The same for a **daily loss cap** (default 2% of account equity at the start of the server day, this robot only): no new trades, open ones still exit on their own.

## What this robot does not do

- It does not read news or an external calendar API.
- It is not a buy-and-hold system.
- It does not chase tick-by-tick “bursts” (that class of idea looks clean in theory and usually loses on real ticks).
- It does not guarantee catching **every** long candle — too many filters ≈ almost no trades; too few ≈ noise.
- It does not replace position sizing. A 0.10 lot on EURUSD is a different stake than on an index.

## How to use it sanely

1. Tester: **Every tick based on real ticks**, same symbol and **M15** as live. Results without real ticks are not trustworthy for this scalper.
2. Enable AutoTrading. Magic `26091401` keeps its positions apart from other EAs.
3. Do not load an old `.set` file right after the robot version changed. Use **Reset** after 2.27 (new daily-loss input). The tester needs **H1** data only if you turn the hourly EMA filter on.
4. Treat backtests as a hint, not as future profit.

## Glossary

| Term | Meaning |
|---|---|
| **Candle / bar** | A time slice on the chart (here usually 15 minutes). |
| **ATR** | Average candle range — “how large a typical move is”. |
| **Point** | Smallest price step in MT5 (`SYMBOL_POINT`); not the same as a pip on every pair. |
| **SL / TP** | Automatic close at a loss / profit. |
| **Lot** | Position size. |
| **Session** | Hours when **new** trades may be opened. |
