# Stochastic_Trend

US30 / index-oriented trend EA in `Stochastic_Trend.mq5`. Magic `26091211`. Version **1.93**. Goal: trade **oscillator signals only with EMA trend** (optional ADX). EMA is **direction + exit**, never an entry by itself.

User-facing docs are English; some input comments in the `.mq5` may still be Polish. Compile in MetaEditor (F7). After input-default changes: user must **Reset inputs** or old chart/tester values stick (especially `InpOscillator` and `InpStochRequireExtreme`).

`bars` = candles on `InpTimeframe` (e.g. 12 on M15 = 3h). SL/TP **points** = `SYMBOL_POINT`, **not** Dow index points. Digits=2 US30: 5000 pts ≈ 50.00 index; Digits=1: 500; Digits=0: 50.

## Trend (EMA)

Closed bar `[1]`: Fast EMA(`InpEmaFast`=81) vs Slow EMA(`InpEmaSlow`=255).

- Fast > Slow → **BUY only**
- Fast < Slow → **SELL only**
- Equal → flat, no osc entry

**Close on clear flip** (no min-distance, no ADX≥25 required to close): BUY closed when fast < slow; SELL when fast > slow. Each ticket also has `InpMaxBarsHold` (20) hard cap.

## Oscillator entry (closed bar `[1]` vs `[2]`, never forming `[0]`)

`InpOscillator`: `OSC_STOCH` (default) or `OSC_RSI`. `InpStochRequireExtreme` applies to **both** (default **true** — OnInit warns; tester often keeps an old set).

| Mode | Extreme ON | Extreme OFF |
|---|---|---|
| Stoch | K/D cross `[2]→[1]` **and** %K at/through OS (20) for BUY / OB (80) for SELL. Price field `STO_LOWHIGH` to match MT5 chart. | Same K/D cross, any zone |
| RSI | Leave OS/OB: zone on closed `[2]` **or** `[3]`, `[1]` already outside and still rising (BUY) / falling (SELL). Copy 4 RSI bars. | Mid-50 cross only |

ADX (`InpUseAdxFilter` default **ON**, min 15): **strength only** — no +DI/−DI direction gate (unlike MACD_RSI_Cross_Bull). Weak ADX blocks osc opens in an EMA trend. News-forced entries skip ADX.

At most **one new entry per bar**. Never add on the same bar as the last open.

## Pyramid (v1.50)

While EMA trend unchanged and at least one position exists: add 1 ticket every `InpAddEveryBars` (6; `0`=off) up to `InpMaxPositions` (capped 20). Same direction as trend. Each ticket = own SL/TP and hold counter.

Pyramid `OpenBuy`/`OpenSell` **bypass session + cooldown** (by design: spacing is `AddEveryBars`). Still blocked by `g_tradedThisBar`, max positions, news opposite-bias.

## Opposite extreme flatten (default ON)

Independent of RequireExtreme/ADX (those only gate **entries**). While BUY(s) open, if osc hits OB then later OS → flatten **all**. SELL: OS then later OB. Latch is updated **while holding**, not only at fill — Extreme+ADX never opens BUY at OB, so fill-time flags alone would never fire.

## News (default OFF)

Paginated `{date d-m-Y H:i:s, signal}`. Needs WebRequest URL allow-list. Event_Scalp does **not** share this path.

- API OFF → no news block.
- Backfill: remember last actionable for later flips; **do not** arm live bias.
- Live mild: block opposite osc/pyramid opens.
- Live **flip**: close against, 5-bar strong window (`NEWS_STRONG_BARS`), next open lot × `InpNewsFlipLotMult` (1.5). Strong news **may override EMA** (explicit Print). Neutral does not change last actionable.

## Session / swap / hold

- Session (default ON, 8–16 + 13–21): **new osc entries** via `IsTradeLocked`. SL/TP, MaxBarsHold, EMA-flip, opposite-extreme still run. **Pyramid and news-forced opens skip the session lock.**
- Triple swap (default ON): close 1h before 3-day rollover. GV prefix `STSW{magic}_{symbol}_`. Reopen next day only if MaxBarsHold remaining **and** EMA still with the parked side **and** news/opposite-extreme would not flatten. Stale > 36h dropped.
- Hold tracking array increments on each new signal-TF bar; `RebuildHoldTracking` on init uses `iBarShift` from `POSITION_TIME`. Cap 20 tickets.

## SL / TP

Points only (no percent mode). Widened to broker min stop distance. Invalid stops → retry 0/0 then `PositionModify`. Hardcoded slippage 30.

## CopyBuffer pitfall

Unlike MACD_RSI_Cross_Bull, this EA **does not** re-apply `ArraySetAsSeries` after every `CopyBuffer`. Arrays are series-flagged in `OnInit`. If a future change sees inverted `[1]`/`[2]`, re-apply series after copy (MACD pattern). RSI extreme **requires 4** copied values (`g_rsi[3]`).

## Pitfalls (do not reintroduce)

| Trap | Effect |
|---|---|
| EMA as an entry | Doubles signals; EMA is filter + close-on-flip only |
| ADX +DI/−DI like MACD_RSI | This EA has **no** DI direction filter |
| Opposite-extreme only at fill | Never fires when Extreme+ADX force OS entries in an uptrend |
| RequireExtreme ON in tester after you turned it OFF | MT5 remembers `.set`; OnInit already warns |
| SL/TP as “Dow points” | `SYMBOL_POINT` on Digits=2 is 0.01 index, not 1.00 |
| Session closing EMA-flip / hold | Positions ride against the new trend overnight |
| Hidden Stoch↔RSI period swap | Inputs are the source of truth — no silent oscillator period remap |
| News backfill executing trades | Backfill is memory-only; live poll arms bias |

## Other robots

Leave `Event_Scalp.mq5` and `MACD_RSI_Cross_Bull.mq5` alone unless asked. News JSON is Stochastic-only (not Scalp). Triple-swap / session “entries only” idea is shared with MACD_RSI_Cross_Bull.

## Versions (short)

- **1.50**: pyramid same-trend adds
- **1.81**: closed-bar osc in EMA; news pagination; no hidden period swaps
- **1.82**: RSI leave-OS/OB using `[3]`/`[2]` + `[1]` slope
- **1.90**: close on EMA flip or MaxBarsHold; opposite-extreme flatten
- **1.93**: triple-swap park/reopen if EMA + hold still valid
