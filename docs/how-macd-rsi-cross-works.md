# How MACD_RSI_Cross works (for investors)

This is for someone who can open a chart in MetaTrader 5 but does not program. **It is not a promise of profit.** Indicator crosses and RSI extremes fail often: you will have losing streaks, and a hard time-stop can close a trade that later would have recovered.

## What is this robot for?

`MACD_RSI_Cross` waits for a **candle to close**, then tries **up to three ideas**, in order. It is not a news scalper and it does not trade the still-forming bar.

Typical use: a slower chart than M5 (M15, H1, and similar), FX or CFDs.

1. **RSI stretched** — fade an oversold / overbought close.
2. **Moving-average cross** — a faster EMA crossing a slower SMA.
3. **MACD cross** — MACD line crossing its signal line, usually with RSI on the matching side of 40 / 60.

Only **one successful new trade per candle**. If idea 1 *wants* to trade but cannot (outside session, ADX filter, already in a position), idea 2 or 3 may still open. That is intentional.

## What one trade looks like

**Entry (priority 1 — RSI)**  
If the **closed** RSI is below the oversold level (default 30) → try **BUY**. If it is above overbought (default 70) → try **SELL**. It can keep trying on later candles while RSI stays in that zone. After a fill it waits until RSI leaves the zone before using the same idea again.

**Entry (priority 2 — EMA / SMA)**  
On the closed candle: faster EMA crossing up through the slower SMA → **BUY**; crossing down → **SELL**. RSI confirmation is **not** used here.

**Entry (priority 3 — MACD)**  
MACD crossing up → **BUY**; crossing down → **SELL**. By default it then waits a few candles for RSI to be above 40 (buy) or below 60 (sell). If MACD turns the other way first, that wait is cancelled. A wait that is still open when the session ends is dropped, so it cannot fire at the next session open.

**Optional ADX gate** (off by default)  
If you turn it on, none of the three ideas may open unless ADX says the market is trending strongly enough, and optionally +DI / −DI agrees with the side.

**Exit** (whichever hits first):

- **Stop loss** and **take profit** (points by default; there is a percent-of-**price** mode — that is not percent of your account).
- **Time** — a hard limit of signal-timeframe candles from the open (`MaxBarsHold`), so a stuck trade does not sit for days.
- An **opposite** signal from any priority closes everything this robot has on the symbol, then it may reverse.

Outside session hours (London and New York by default) it **does not open new** positions, but existing ones still have SL/TP and the time limit.

On FX, **triple-swap** is on by default: it closes about an hour before the broker’s expensive 3-day swap (often Wednesday night) and can reopen the next day if the time-stop still has candles left.

## What this robot does not do

- It does not scalp the candle that is still printing (that is Event_Scalp).
- It does not require EMA trend agreement like Stochastic_Trend.
- It does not read the news API.
- It does not guarantee that “RSI is extreme” means price will snap back.
- It does not replace position sizing. Lot 0.50 on EURUSD is a different stake than on an index.

## How to use it sanely

1. Tester: same symbol and timeframe as live; remember **Reset** after a new compile if you want the values from the source.
2. Magic `18300621` keeps its positions apart from the other EAs.
3. Enable AutoTrading. One robot per chart is the usual setup.
4. Prefer **points** for SL/TP unless you are sure you want a percent of **price**.
5. Treat backtests as a hint, not as future profit.

## Glossary

| Term | Meaning |
|---|---|
| **Closed candle** | The last finished bar. This robot ignores the still-forming one for entries. |
| **Priority** | Order of ideas: RSI first, then EMA/SMA, then MACD. |
| **ADX** | Trend-strength filter. Optional here; off by default. |
| **Point** | Smallest price step in MT5 (`SYMBOL_POINT`); not the same as a pip on every pair. |
| **SL / TP** | Automatic close at a loss / profit. |
| **MaxBarsHold** | Forced close after N candles on the signal timeframe. |
| **Session** | Hours when **new** trades may be opened. |
| **Triple swap** | Extra overnight financing on FX, often Wednesday; the robot can flatten to avoid it. |
