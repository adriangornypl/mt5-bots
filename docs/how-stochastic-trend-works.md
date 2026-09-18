# How Stochastic_Trend works (for investors)

This is for someone who can open a chart in MetaTrader 5 but does not program. **It is not a promise of profit.** Trend-following on indices can give back a large move when the EMAs finally cross, and pyramiding increases both wins and losses.

## What is this robot for?

`Stochastic_Trend` is a **trend-follower**. Two EMAs decide the **allowed side**. An oscillator (Stochastic by default, or RSI) times the **entry**. The EMAs do **not** open trades by themselves.

Typical use: US30 / other indices; it can also run on FX.

- Fast EMA above slow EMA → **buys only**
- Fast EMA below slow EMA → **sells only**
- EMAs equal → no oscillator entry

The aim is to buy pullbacks in an uptrend (or sell rallies in a downtrend), add to the position while the trend lasts, and get out when the trend flips or time runs out.

## What one trade looks like

**Entry (Stochastic, default)**  
On a **closed** candle: %K crossing up through %D in an EMA uptrend → **BUY**; %K crossing down through %D in an EMA downtrend → **SELL**. By default it also wants that cross from **oversold** (buy) or **overbought** (sell). If “require extreme” is off, any K/D cross with the EMA is enough.

The Stochastic on your chart should use the same %K / %D / slowing and the same price field (MetaTrader’s usual Stochastic is Low/High).

**Entry (RSI, if you switch the oscillator)**  
Either RSI leaving oversold/overbought (when require extreme is on) or RSI crossing the 50 line (when it is off), still only in the EMA direction.

**ADX** (on by default here)  
Only asks “is the trend strong enough?”. It does **not** check +DI versus −DI. If ADX is weak, oscillator entries are skipped.

**Adding (pyramid)**  
If you already have a position and the EMA side has not changed, it can open **another** ticket every N candles, up to a maximum. Each add has its own SL, TP, and time limit. At most one new ticket per candle. These adds are **not** blocked by the session clock (the first oscillator entry is).

**Exit** (whichever hits first for that ticket, unless a flatten closes all):

- **Stop loss** and **take profit** in MetaTrader **points** (`SYMBOL_POINT` — not “Dow points”).
- **EMA flip** — longs close when the fast EMA goes below the slow; shorts close when it goes above. No extra strength test.
- **Time** — a hard limit of candles per ticket (`MaxBarsHold`).
- **Opposite extreme** (on by default) — while you are long, if the oscillator reaches overbought and later falls to oversold, it closes **all** of this robot’s positions (and the mirror for shorts).
- Optional **news** (off by default): mild news blocks the opposite side; a sentiment **flip** can close the other side and force an entry for a few candles, even if the EMA disagrees, sometimes with a larger lot.

Outside session hours it **does not open the first oscillator trade**, but SL/TP, EMA-flip, opposite-extreme, and the time limit still run.

On FX, **triple-swap** is on by default: flatten about an hour before the 3-day swap and reopen the next day only if the EMA still agrees and the time-stop still has candles left. On many indices this setting does nothing useful; on FX it will still close.

## What this robot does not do

- It does not scalp the candle that is still printing (that is Event_Scalp).
- It does not fade RSI with no trend filter (that is MACD_RSI_Cross_Bull only when Trend follow is off).
- It does not treat “400 points” as 400 Dow index points. On a US30 chart with 2 decimals, 400 points is 4.00 on the index.
- It does not guarantee that an EMA uptrend continues after you pyramid.
- It does not replace position sizing. Several 0.01 lots stacked is still more risk than one.

## How to use it sanely

1. Tester: same symbol and timeframe as live. Click **Reset** after a compile — MetaTrader often keeps an old oscillator / “require extreme” value.
2. News needs the URL allowed in MT5 (Tools → Options → Expert Advisors → WebRequest) if you turn news on.
3. Enable AutoTrading. Magic `26091211` keeps its positions apart from the other EAs.
4. Check **Digits** and **point** on the Market Watch symbol before you judge SL/TP size.
5. Treat backtests as a hint, not as future profit.

## Glossary

| Term | Meaning |
|---|---|
| **EMA trend** | Fast EMA vs slow EMA on the last closed candle. Sets buy-only or sell-only. |
| **Oscillator** | Stochastic or RSI — times the entry inside that trend. |
| **Require extreme** | Only take crosses from oversold (buy) or overbought (sell). Default on. |
| **Pyramid / add** | Extra tickets in the same direction while the EMA has not flipped. |
| **Point** | Smallest price step in MT5 (`SYMBOL_POINT`). Not a Dow “index point”. |
| **SL / TP** | Automatic close at a loss / profit. |
| **MaxBarsHold** | Forced close after N candles for **that** ticket. |
| **Session** | Hours when the **first** oscillator entry may open. Adds can still appear outside it. |
| **Triple swap** | Extra overnight financing on FX; the robot can flatten to avoid it. |
