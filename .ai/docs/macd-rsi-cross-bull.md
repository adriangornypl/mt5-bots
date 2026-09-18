# MACD_RSI_Cross_Bull

Closed-bar multi-signal EA in `MACD_RSI_Cross_Bull.mq5` (renamed from `MACD_RSI_Cross.mq5`). Magic `18300621` (unchanged — live tickets and `MRSW` parks still match). Version **2.04**. Goal: **mid-term trend follow** on M15/H1 (ride EMA/SMA until it flips). `InpTrendFollowMode` default **ON**. OFF restores the v1.90 fade stack.

User-facing docs are English; some input comments in the `.mq5` may still be Polish. Compile in MetaEditor (F7). After input-default changes: user must **Reset inputs** or old chart/tester values stick (especially v1.90 `MaxBarsHold=10` / `TakeProfitPoints=2000`, v2.02 `EMA20/SMA96`, and v2.03 stack/session-off).

`bars` = candles on `InpTimeframe` (e.g. 10 on M15 ≈ 2.5h). Never treat “bars” as wall-clock minutes.

## Trend (EMA vs SMA)

Closed bar `[1]`: Fast EMA(`InpMomEmaPeriod`=21) vs Slow SMA(`InpMomSmaPeriod`=50).

When `InpTrendFollowMode` is ON (default):

- EMA > SMA → **BUY only** (P1/P3). P2 golden cross may open the long.
- EMA < SMA → **SELL only** (P1/P3). P2 death cross may open the short.
- Equal → flat; no P1/P3. Existing tickets stay until a clear side appears.

**Close on clear flip** (no min-distance, no ADX required to close): BUY closed when EMA < SMA; SELL when EMA > SMA. Runs **outside session**. Triple-swap parks of the against side are dropped.

This matches Stochastic_Trend’s “EMA is direction + exit” idea, using EMA 21 / SMA 50 (`macd_rsi_opt1.opt`; was 20/96) instead of Stochastic’s 81/255.

## Signals (closed bar only)

All indicator reads use **shift 1** (last closed) vs **shift 2**. Forming bar `[0]` is display-only.

Tried **in order on each new bar**. One successful open per bar. If a higher prio **detects** but **fails to open** (ADX / session / lock), lower prio may still fire — do not “swallow” EMA/MACD after a blocked RSI.

| Prio | Default | TrendFollow ON (default) | TrendFollow OFF (v1.90) |
|---|---|---|---|
| 1 RSI | ON | **With-trend pullback.** Closed RSI `< OS` (30) → BUY only if trend UP. `> OB` (70) → SELL only if trend DOWN. Zone latch same as before. | Fade: OS → BUY, OB → SELL, no trend filter. |
| 2 EMA/SMA | ON | Closed-bar cross **starts the ride**. Golden → BUY, death → SELL. This is the trend change; it may reverse. | Same cross, treated as a short-term momentum poke. |
| 3 MACD | ON | MACD cross (12/26/9) **only WITH** EMA/SMA. Pending against the trend is cleared. RSI confirm still MACD-only (`InpMacdRequireRsiConfirm` default ON, 5 bars, 30/70). | Same MACD/RSI confirm, any side. |

ADX (`InpUseAdxFilter`, default **ON**) gates **all** priorities at open: ADX ≥ `InpAdxMinLevel` (25) and optional +DI/−DI match (`InpAdxUseDiDirection` default ON). Missing ADX data = block. Flip-close does **not** use ADX.

## Position rules

- **TrendFollow ON:** opposite RSI/MACD does **not** flatten a trend ticket (that is a pullback). Only P2 (EMA/SMA cross) may reverse after the flip-close. **TrendFollow OFF:** opposite signal always flattens, then may open.
- `InpOneTradeOnly` default **true** = 1 position. `false` = add **same** direction up to `InpMaxPositions` (30).
- `InpMaxBarsHold` default **30** (~7.5h on M15). `0` = **off** (ride until flip / SL). `>0` is a hard close after N signal-TF candles from `POSITION_TIME` (+ swap-bonus bars). Survives reattach / recompile. Runs **outside session**.
- Cooldown `InpTradeCooldownBars` (4) after a successful open. Counted down on later bars that did not open.
- Session (`InpUseSessionFilter` default **ON**, 8–16 + 13–21 server, inclusive hours): **new entries only**. SL/TP + MaxBarsHold + **trend-flip** still run. Overnight MACD pending is **cleared** so it cannot fire at session open.
- Daily stop (`InpDailyStopLossPct` default **0** = **off**): **% of window-start `ACCOUNT_BALANCE`** (not points, not % of price — that is `InpStopLossPercent`). This EA’s window P/L = closed deals (profit+swap+commission, our magic/symbol) + floating of our tickets. Loss% = `−PnL / startBalance × 100` when PnL < 0. If loss% ≥ limit, latch halt: **no new entries** (and no triple-swap reopen) until the **next session window** (window id or session-clock day changes). Overlap 13–16 counts as window 1; window 2 starts after window 1 ends. Session filter off → bucket is the session-clock calendar day; resume next day. Existing tickets still have SL/TP/hold/flip — do **not** flatten on the daily halt. Other magics do not count. Renamed from money `InpDailyStopLoss` so a leftover `100` cannot mean 100%.
- Triple swap (`InpAvoidTripleSwap` default **ON**): close 1h before 3-day swap charge (`SYMBOL_SWAP_ROLLOVER3DAYS`, usually Wed 23:00 server → Thu 00:00). Park in GlobalVariables prefix `MRSW{magic}_{symbol}_`. Reopen next day if MaxBarsHold still has remaining bars **and** (when TrendFollow) EMA/SMA still agrees with the parked side. Stale park > 36h dropped. Close-window blocks new entries.

## SL / TP

Default **points** (`InpUsePercentSLTP=false`): SL 400, TP 5000 (0 = none). Percent mode is **% of PRICE**, not account — ≥5% prints a huge-FX warning. Percent TP `0` = none. Lots default **0.10**.

`InpIncludeSpread` default ON: add current spread to distances so Bid-chart SL matches the input (BUY opens at Ask). Distances are also widened to spread + broker stops/freeze + safety buffer. After every open, `EnsurePositionSLTP` + `PositionModify` if the broker stripped stops. Invalid-stops retcode → retry market with 0/0 then attach.

Do **not** go back to “stops_level+1 point, ignore spread” — on indices that SL sits **inside** the spread and the position dies on the open tick.

## CopyBuffer

`CopySeriesBuffer` **re-applies `ArraySetAsSeries` every copy**. `CopyBuffer` can drop AS_SERIES on dynamic arrays. `[0]`=forming, `[1]`=last closed, `[2]`=previous closed.

## Compile / tester

`#property strict`. Unused timer is only set when triple-swap is ON.

Do not assume defaults from chat — read the live `input` block. Chart/tester `.set` overrides compiled defaults until Reset.

Typical: M15 or H1. 21/50 on M15 ≈ 5h vs 12.5h; on H1 ≈ 21h vs 2 days.

## Pitfalls (do not reintroduce)

| Trap | Effect |
|---|---|
| RSI prio 1 fade in a downtrend | Buys the dip against the trend the user wants to ride |
| Opposite MACD/RSI flattening a trend ticket | Cuts the ride on a pullback; only EMA/SMA flip should exit |
| RSI prio 1 only on the exact cross bar | Missed dip if that bar was session/ADX/cooldown locked |
| Failed P1 swallowing P2/P3 | EMA/MACD never fire on the same bar |
| RSI 40/60 confirm on EMA | Starves prio 2; confirm is **MACD only** |
| MACD pending requiring a *fresh* RSI cross only | If RSI was already >40 on MACD cross, pending expired unused |
| Session filter closing SL/TP / MaxBarsHold / **trend-flip** | Positions stuck overnight against the new trend |
| Flattening on daily stop | Daily halt is **new entries only**; ride still has SL/TP/flip |
| Daily stop as money / % of price | It is **% of window-start balance** (0=off). Not `InpStopLossPercent`. |
| MaxBarsHold=10 (v1.90 tester `.set`) | ~2.5h on M15 — kills mid-term holds. Compiled default is **30** |
| TP=2000 (v1.90 tester `.set`) | Cuts winners. Compiled default TP is **5000** |
| Percent SL/TP as “account risk” | 1% of EURUSD price ≈ 100+ pips, not 1% of balance |
| SL without spread on Bid chart | BUY SL tighter by exactly the spread → spread-stop |

## Other robots

Leave `Event_Scalp.mq5`, `Stochastic_Trend.mq5`, and `MACD_RSI_Cross_Bear.mq5` alone unless asked. Shared idea: session hours on new entries only; SL/TP/hold/flip still run outside session. Triple-swap pattern is shared with Stochastic (different GV prefix). Stochastic still uses its own EMA 81/255 + oscillator; do not copy-paste filters. Bear is a **separate** expert (magic 18300622) — do not merge its defaults back into this file unless asked.

## Versions (short)

- **1.90**: triple-swap park/reopen; prio 1 zone retry; failed higher prio does not swallow lower; RSI confirm MACD-only; spread-aware SL/TP + PositionModify verify
- **2.00**: TrendFollow default ON — EMA/SMA is direction + close-on-flip; RSI/MACD only with the trend; MaxBarsHold 0 and TP 0 so a downtrend short rides until the MAs flip. OFF = v1.90 fade + opposite flatten.
- **2.01**: `InpDailyStopLoss` account money, default 0=off. Halt new entries until next session window; do not flatten.
- **2.02**: daily stop is `% of window-start balance` (`InpDailyStopLossPct`). 0=off. Renamed so old money values cannot be read as percent.
- **2.03**: compiled defaults from `macd_rsi_opt1.opt` (EURUSD.pro M15, real ticks, genetic, 2026.06.01–2026.09.18, max balance). EMA 21 / SMA 50, ADX ON 14/25 + DI, RSI confirm 30/70, lots 0.10, SL 400 / TP 5000, hold 30, stack up to 20, session **OFF**, daily stop **0**. In-sample, MaxPositions 10–90 tied at the same profit; 20 is the first best pass and the Jan–Oct confirmation.
- **2.04**: same `macd_rsi_opt1.opt` cache, pass 104 (the Jan–Oct retest at 13:55). OneTradeOnly **ON**, MaxPositions 30, cooldown **4**, session **ON**, daily stop still **0**. N-params unchanged from 2.03. Source file later renamed to `MACD_RSI_Cross_Bull.mq5` (magic `18300621` / GV `MRSW` unchanged).
