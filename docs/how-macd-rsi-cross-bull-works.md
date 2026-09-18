# How MACD_RSI_Cross_Bull works (for investors)

This is for someone who can open a chart in MetaTrader 5 but does not program. **It is not a promise of profit.** Trends reverse, and a stop-loss can close a trade that later would have recovered. Riding a trend until the moving averages flip also means giving back some of the move at the end.

## What is this robot for?

`MACD_RSI_Cross_Bull` waits for a **candle to close**, then trades **with** the moving-average trend. It is not a news scalper and it does not trade the still-forming bar.

Typical use: **M15 or H1** (slower than a scalper), FX or CFDs. File: `MACD_RSI_Cross_Bull.mq5` (compile with F7). Magic stays **18300621**, so existing tickets from the old `MACD_RSI_Cross` name still belong to this robot.

The two averages (fast EMA vs slower SMA) decide the **allowed side**:

- Fast EMA above slow SMA → **buys only**
- Fast EMA below slow SMA → **sells only**

If the market is in a **down** trend, the robot wants to **stay short until that trend changes** (the fast EMA crossing back above the slow SMA). It will not buy just because RSI looks “cheap” in that downtrend.

It still has **three ways in**, tried in order. Only **one successful new trade per candle**. If idea 1 *wants* to trade but cannot (outside session, ADX filter, already in a position), idea 2 or 3 may still open.

You can turn **Trend follow** off in the inputs to get the older “fade RSI / take profit quickly” behaviour. After a new compile, click **Reset** on the inputs — MetaTrader often keeps old periods, session, lot, hold, and take-profit.

## What one trade looks like

**The trend (always on when Trend follow is on)**  
On the last **closed** candle: EMA vs SMA. That side is both the filter for new trades and the main exit.

**Entry (priority 1 — RSI pullback with the trend)**  
In an **up** trend, if closed RSI is below the oversold level (default 30) → try **BUY** (buy the dip). In a **down** trend, if RSI is above overbought (default 70) → try **SELL** (sell the rally). It can keep trying on later candles while RSI stays in that zone. After a fill it waits until RSI leaves the zone before using the same idea again.

**Entry (priority 2 — EMA / SMA cross)**  
On the closed candle: faster EMA crossing up through the slower SMA → **BUY** (uptrend start). Crossing down → **SELL** (downtrend start). This is how a new trend ride begins.

**Entry (priority 3 — MACD cross, optional RSI confirm)**  
MACD crossing up → **BUY** only if the EMA trend is already up; crossing down → **SELL** only if the trend is down. By default it then waits a few candles for RSI to be above 30 (buy) or below 70 (sell). If MACD turns the other way first, or the averages disagree, that wait is cancelled. A wait that is still open when the session ends is dropped.

**ADX gate** (on by default)  
None of the three ideas may **open** unless ADX says the market is trending strongly enough, and optionally +DI / −DI agrees with the side. Averages flipping still **close** without asking ADX.

**Exit** (whichever hits first):

- **Trend change** — longs close when the fast EMA goes below the slow SMA; shorts close when it goes above. This is the main “follow until it changes” rule.
- **Stop loss** (points by default, 400). **Take profit** default is 5000 points (about 500 pips on 5-digit FX). Set TP to 0 if you want no target.
- **Time** — default **30** signal-timeframe candles from the open (about 7.5 hours on M15). Set `MaxBarsHold` to 0 to ride until the averages flip or the stop hits.
- An **EMA/SMA cross** the other way may then open the new side. A lone MACD or RSI signal against the still-valid trend does **not** flatten the position (that is usually a pullback).

Session hours (London and New York by default) **block new entries** outside those windows. Existing ones still have SL, TP, the time limit, and the trend-flip close.

**Daily stop** (off by default: set to **0**). This is a **percent of account balance** at the start of the current session window, not points and not percent of price. If this robot’s trades for that window are down by that much (closed results plus any still-open tickets), it **stops opening** until the next session window. Example: balance 10,000 and daily stop 2 → halt after this EA is down about 200. It does **not** close what is already open — those still use stop-loss and the trend-flip. Other robots on the same account do not count.

On FX, **triple-swap** is on by default: it closes about an hour before the broker’s expensive 3-day swap (often Wednesday night) and can reopen the next day if the time-stop still has candles left **and** the averages still point the same way. A daily-stop halt also blocks that reopen.

## What this robot does not do

- It does not scalp the candle that is still printing (that is Event_Scalp).
- It does not buy oversold RSI in a downtrend when Trend follow is on (that was the old fade).
- It does not close a good short just because MACD ticked up for a few candles while the averages are still down.
- It does not read the news API.
- It does not guarantee that “EMA is below SMA” means price will keep falling.
- It does not replace position sizing. Lot 0.10 on EURUSD is a different stake than on an index.

## How to use it sanely

1. Tester: same symbol and timeframe as live; remember **Reset** after a new compile if you want the values from the source (EMA 21 / SMA 50, ADX on, hold 30, TP 5000, session on, one trade).
2. Magic `18300621` keeps its positions apart from the other EAs.
3. Enable AutoTrading. One robot per chart is the usual setup.
4. Prefer **points** for the stop unless you are sure you want a percent of **price**.
5. Treat backtests as a hint, not as future profit.

## Glossary

| Term | Meaning |
|---|---|
| **Closed candle** | The last finished bar. This robot ignores the still-forming one for entries. |
| **Trend follow** | Only trade with EMA vs SMA; hold until that cross flips. |
| **Priority** | Order of ideas: RSI pullback first, then the MA cross, then MACD. |
| **ADX** | Trend-strength filter. On by default. Gates **opens**, not the flip-close. |
| **Point** | Smallest price step in MT5 (`SYMBOL_POINT`); not the same as a pip on every pair. |
| **SL / TP** | Automatic close at a loss / profit. TP 0 means “no target — ride the trend”. Default TP is 5000 points. |
| **MaxBarsHold** | Forced close after N candles on the signal timeframe. 0 means off. Default is 30. |
| **Daily stop** | Max loss as **% of balance** for the current session window. 0 means off. After it hits, no new trades until the next window. |
| **Session** | Hours when **new** trades may be opened. |
| **Triple swap** | Extra overnight financing on FX, often Wednesday; the robot can flatten to avoid it. |
