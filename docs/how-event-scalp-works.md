# How Event_Scalp works (for investors)

This is for someone who can open a chart in MetaTrader 5 but does not program. **It is not a promise of profit.** Scalping news and sudden candles is risky: spread, slippage, and fake spikes can wipe a run of wins.

## What is this robot for?

`Event_Scalp` does not “ride the trend” like moving averages. It looks for **short, violent moves** — typically on an **M5** chart (5-minute candle):

1. **News** from an external API (if you set a URL) — sentiment `positive` / `negative`.
2. **A long candle** — a bar clearly larger than usual (compared with ATR, typical range of recent candles).

The aim is to enter **during the same candle** that is still expanding, not wait for it to close (by then the impulse is often over).

## What one trade looks like

**Entry (Rapid)**  
On every tick the robot looks at the **current**, still-open M5 candle. If its range (high to low) is large enough versus ATR and the candle has a direction (close above or below open), it may open:

- **BUY** — price is above the bar’s open (up impulse),
- **SELL** — price is below (down impulse).

Sometimes it also waits for a pullback inside that candle, an M1 confirmation, or it skips a “doji” (wide range, almost no body). That depends on the inputs on the chart — after compiling, click **Reset** if you want the values from the source, not leftover tester settings.

**Entry (News)**  
If the API is live: `positive` → try BUY, `negative` → SELL. Neutral does nothing. A sudden sentiment flip can close the opposite position and open a new one (sometimes with a larger lot).

**Exit** (whichever hits first):

- **Stop loss** — loss cap (often a multiple of ATR).
- **Take profit** — profit target.
- **Time** — a hard limit of M5 candles (`MaxBarsHold`) so a dead impulse is not held for hours.
- Sometimes a **wick reversal** on the same candle (the body collapses and price crosses back through the open).
- Optional move of SL to break-even and trailing.

Outside session hours (London and New York by default) it **does not open new** positions, but existing ones still have SL/TP and the time limit.

## What this robot does not do

- It does not judge whether a headline is “true”.
- It is not a buy-and-hold system.
- It does not guarantee catching **every** long candle — too many filters ≈ almost no trades; too few ≈ noise.
- It does not replace position sizing. A 0.10 lot on EURUSD is a different stake than on an index.

## How to use it sanely

1. Tester: **every tick** model, same symbol and M5 as live, realistic spread.
2. News needs the URL allowed in MT5 (Tools → Options → Expert Advisors → WebRequest).
3. Enable AutoTrading. Magic `26091401` keeps its positions apart from other EAs.
4. Do not load an old `.set` file right after the robot version changed.
5. Treat backtests as a hint, not as future profit.

## Glossary

| Term | Meaning |
|---|---|
| **Candle / bar** | A time slice on the chart (here usually 5 minutes). |
| **ATR** | Average candle range — “how large a typical move is”. |
| **Point** | Smallest price step in MT5 (`SYMBOL_POINT`); not the same as a pip on every pair. |
| **SL / TP** | Automatic close at a loss / profit. |
| **Lot** | Position size. |
| **Session** | Hours when **new** trades may be opened. |
