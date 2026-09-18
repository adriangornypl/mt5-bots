# Event_Scalp

M15 impulse trader in `Event_Scalp.mq5` (same forming-bar Rapid logic as the old M5 scalp). Magic `26091401`. Goal: trade **unusually large candles** (range vs ATR + point floor) on the forming bar (shift 0), not Stoch/MACD trend and **not** calendar news.

User-facing docs are English. Compile in MetaEditor (F7). After input-default changes: user must **Reset inputs** or old chart/tester values stick.

## Signals

- **Rapid** (`OnTick`): forming bar **range (high−low)** vs ATR(14) of **closed** bar (buffer shift 1). Direction = close vs open. One shot per bar (`g_armState` / `g_openedBar`).
- Qualify: body ratio + close near extreme (plus a 25% doji floor).
- Default entry is **pullback** (`InpRapidPullbackMin` > 0 → `ArmImpulse` / `TryPullback`). `0` = immediate on qualify. Default window **0.50–0.60** (`scalp3.opt`).
- Skip if range already ≥ `InpRapidAtrMax` × ATR (`0` or **max < min** = off).
- **Regime** (closed bars only, shift 1): ADX chop (min 18, rise/DI **off**), ATR vs 50-bar avg (min ratio 0.55), TP ≥ spread × 5. **H1 EMA off** by default. Chop/compressed ATR → wait (stay armed). H1 or DI against → abort arm. Missing ADX/H1 data → one-shot warn and pass (same idea as M1).
- **Daily loss** (`InpMaxDailyLossPct` default **2.0**, `0`=off): server-day halt of **new entries** when this EA’s closed deals (profit+swap+commission) plus floating of our tickets reach −% of start-of-day equity with our tickets marked to market (equity − our floating at midnight / attach). Existing tickets still run SL/TP/hold. Other magics do not count. Resets next server day.

Do **not** reintroduce a news API / timer entry. Scalp is per-candle market structure only. News JSON lives on Stochastic_Trend.

Do **not** add PulseStrike-style `CopyTicks` / z-score / tick-burst (looks good in theory, loses on real ticks). Do **not** AND-stack RSI/Stoch/MACD onto Rapid. Do **not** use forming-bar volume (incomplete).

## Real ticks (do not chase)

Modeled “every tick” (no real ticks) interpolates OHLC and a stable spread. Immediate entry on range ≥ ATR looks good there and **dies** on real ticks.

v2.21+ is built for **Every tick based on real ticks**. Do not re-optimize on modeled ticks and then “verify” on real ticks.

v2.22 defaults were M15 big-bar starting points. **v2.23** = EURUSD.pro M15 real-tick pass from `Tester/cache/scalp2.opt` (back RF ~1.91, forward ~1.6): ATR min 1.4 / max 3.4, closePos 0.20, pullback 0.40–0.45, spread 0.15 of SL. `InpTimeframe=15` = `PERIOD_M15`.

**v2.24** kept 2.23 Rapid numbers and AND-stacked H1 EMA + ADX-must-rise + ATR 0.70 + TP×8. That is a swing filter, not a scalper: ~17 trades / 3 months, ~1% — skip it.

**v2.25** restores frequency: ATR min 1.2, 70 pts, body 0.50, closePos 0.30, pullback 0.25–0.50, ADX 18 no-rise, H1 **off**, ATR ratio 0.55, TP×5. Keep pullback (do not chase). Tester needs **H1** history only when `InpUseH1Ema` is on. Turn a gate off in inputs rather than deleting it.

**v2.26** = `scalp3.opt` EURUSD.pro M15 real-tick genetic (back 2026.06.01–06.16 / forward 06.16–07.01). Optimized Rapid/stops: ATR max 4.0, body 0.60, pullback 0.50–0.60, SL/TP ATR 1.4/1.3, max 3 positions. Session stays **ON** (the Jun–Sep retest with session OFF is a tester override, not the compiled default).

## Why it missed long candles (do not reintroduce blindly)

AND-stack killed M5 impulses:

| Filter | Effect |
|---|---|
| Qualify on `\|close−open\|` not range | Wicky long bars fail |
| `InpRapidAtrMax` as skip | Cap **below** `InpRapidAtrMult` skips almost everything. `0.2` with min `1.0` is invalid — treat max `<` min as **off** |
| Pullback 20–35% | Many long M5 bars never retrace → arm then never enter |
| M1: 2 closed bars same color | Blocks a 1–2 minute spike; missing M1 history used to **block** (should pass). M1 is **off** on M15 |
| Velocity only in first 90s of the M5 | Spike at minute 2–5 never sets `g_velOk` |
| Spread % of SL | Spikes widen spread → skip |
| Strict body 0.60 + close-in-last-30% | Extra rarity |

v2.11 immediate entry “worked” on **modeled** ticks. That is not live edge.

## Compile

`HistoryDealGetString` / `HistoryDealGetInteger` always need **deal ticket** (unlike `PositionGetString` after `PositionSelect`):

`HistoryDealGetString(deal, DEAL_SYMBOL)` — not `HistoryDealGetString(DEAL_SYMBOL)`.

`#property strict` is present; unused `OnTradeTransaction` `request`/`result` may warn.

## Tester

INI: `Name=value||start||step||stop||Y\|N` — first field is the used value. `InpTimeframe=15` = `PERIOD_M15`.

Use **Every tick based on real ticks**, same symbol as live, tester period **M15**. Modeled ticks overfit this EA.

Do not load old M5 `Event_Scalp.set` after 2.23. Tester needs M1 data only if `InpRapidUseM1`. After 2.27, **Reset** or you will not see `InpMaxDailyLossPct`. H1 is required only when the H1 EMA filter is on.

Keep **max > min** on ATR cap. Optimize big-bar filters and exits in **two passes** (not all Y at once).

## Other robots

Leave `MACD_RSI_Cross_Bull.mq5` and `Stochastic_Trend.mq5` alone unless asked. See `macd-rsi-cross-bull.md` and `stochastic-trend.md`. Shared idea: session hours on new entries only; SL/TP/hold still run outside session.

## Versions (short)

- **2.00–2.02**: news + rapid on forming bar; rapid = range vs 1.8 ATR, SL/TP points, hold 6
- **2.10**: ATR stops, BE/trail, pullback, M1, velocity, news∧rapid — too few trades
- **2.11**: range-based long bar, immediate entry, looser M1/velocity (modeled-tick edge)
- **2.12**: EURUSD tester values as defaults — **reverted by user**
- **2.20**: news API / timer / flip / NEWS hold **removed**. Rapid-only per-candle impulse. Pullback still dead (`OpenDir` on qualify).
- **2.21**: wire pullback; strict qualify; spread filter 0.25; trail 0.60 only after spread covered and SL ≥ BE; wick abort 5s hold; M1 = last closed bar; max 1 pos; ATR max 2.0 (max `<` min still off).
- **2.22**: compiled defaults for **M15 big-bar** (ATR 1.6/3.0, 100 pts, body 0.55, pullback 0.25–0.45, M1/wick/trail off, session on, hold 3, SL/TP 1.2).
- **2.23**: defaults from `scalp2.opt` EURUSD.pro M15 (ATR 1.4/3.4, closePos 0.20, pullback 0.40–0.45, spread 0.15). Modest RF ~1.9 back / ~1.6 forward.
- **2.24**: closed-bar ADX / H1 EMA / ATR-ratio / TP-vs-spread on top of 2.23 Rapid. Too rare (~17 trades / 3 months).
- **2.25**: wider Rapid window, H1 off, ADX 18 without must-rise. Still no tick-burst / no immediate chase.
- **2.26**: defaults from `scalp3.opt` (ATR max 4.0, body 0.60, pullback 0.50–0.60, SL/TP 1.4/1.3, max 3 pos). Session still ON.
- **2.27**: `InpMaxDailyLossPct` (2% of start-of-day equity, this EA only) blocks new entries. `0`=off.
