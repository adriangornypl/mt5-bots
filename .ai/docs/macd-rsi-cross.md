# MACD_RSI_Cross

Closed-bar multi-signal EA in `MACD_RSI_Cross.mq5`. Magic `18300621`. Version **1.90**. Goal: open from **three priorities** (RSI extremes → EMA/SMA cross → MACD), not news/impulse scalp.

User-facing docs are English; some input comments in the `.mq5` may still be Polish. Compile in MetaEditor (F7). After input-default changes: user must **Reset inputs** or old chart/tester values stick.

`bars` = candles on `InpTimeframe` (e.g. 10 on M15 ≈ 2.5h). Never treat “bars” as wall-clock minutes.

## Signals (closed bar only)

All indicator reads use **shift 1** (last closed) vs **shift 2**. Forming bar `[0]` is display-only.

Tried **in order on each new bar**. One successful open per bar. If a higher prio **detects** but **fails to open** (ADX / session / lock), lower prio may still fire — do not “swallow” EMA/MACD after a blocked RSI.

| Prio | Default | Entry |
|---|---|---|
| 1 RSI Min/Max | ON | Closed RSI `< InpRsiOversold` (30) → BUY; `> InpRsiOverbought` (70) → SELL. **Zone, not only the cross bar.** Latch `g_extBuyArmed` / `g_extSellArmed` disarms **only after a successful open**; re-arms when RSI leaves the zone. |
| 2 EMA/SMA | ON | Closed-bar cross: EMA(`InpMomEmaPeriod`=20) vs SMA(`InpMomSmaPeriod`=96). Golden → BUY, death → SELL. **No RSI 40/60 confirm.** |
| 3 MACD | ON | MACD main vs signal cross (12/26/9). If `InpMacdRequireRsiConfirm` (default ON): wait up to `InpRsiConfirmBars` (5) for RSI already `>40` (BUY) / `<60` (SELL) **or** a fresh cross through that level, while MACD stays on that side. Pending dies if MACD flips or session filter drops it at bar open. |

ADX (`InpUseAdxFilter`, default **OFF**) gates **all** priorities at open: ADX ≥ `InpAdxMinLevel` (25) and optional +DI/−DI match (`InpAdxUseDiDirection` default ON). Missing ADX data = block.

## Position rules

- Opposite signal **always flattens all** our magic/symbol tickets, then may open. Reverse ignores cooldown.
- `InpOneTradeOnly` default **true** = 1 position. `false` = add **same** direction up to `InpMaxPositions` (10).
- `InpMaxBarsHold` (10): **hard** close after N signal-TF candles from `POSITION_TIME` (+ swap-bonus bars). Survives reattach / recompile. Runs **outside session**.
- Cooldown `InpTradeCooldownBars` (3) after a successful open. Counted down on later bars that did not open.
- Session (`InpUseSessionFilter` default ON, 8–16 + 13–21 server, inclusive hours): **new entries only**. SL/TP + MaxBarsHold still run. Overnight MACD pending is **cleared** so it cannot fire at session open.
- Triple swap (`InpAvoidTripleSwap` default **ON**): close 1h before 3-day swap charge (`SYMBOL_SWAP_ROLLOVER3DAY`, usually Wed 23:00 server → Thu 00:00). Park in GlobalVariables prefix `MRSW{magic}_{symbol}_`. Reopen next day if MaxBarsHold still has remaining bars. Stale park > 36h dropped. Close-window blocks new entries.

## SL / TP

Default **points** (`InpUsePercentSLTP=false`): 500 / 2000. Percent mode is **% of PRICE**, not account — ≥5% prints a huge-FX warning.

`InpIncludeSpread` default ON: add current spread to distances so Bid-chart SL matches the input (BUY opens at Ask). Distances are also widened to spread + broker stops/freeze + safety buffer. After every open, `EnsurePositionSLTP` + `PositionModify` if the broker stripped stops. Invalid-stops retcode → retry market with 0/0 then attach.

Do **not** go back to “stops_level+1 point, ignore spread” — on indices that SL sits **inside** the spread and the position dies on the open tick.

## CopyBuffer

`CopySeriesBuffer` **re-applies `ArraySetAsSeries` every copy**. `CopyBuffer` can drop AS_SERIES on dynamic arrays. `[0]`=forming, `[1]`=last closed, `[2]`=previous closed.

## Compile / tester

`#property strict`. Unused timer is only set when triple-swap is ON.

Do not assume defaults from chat — read the live `input` block. Chart/tester `.set` overrides compiled defaults until Reset.

## Pitfalls (do not reintroduce)

| Trap | Effect |
|---|---|
| RSI prio 1 only on the exact cross bar | Missed dip if that bar was session/ADX/cooldown locked |
| Failed P1 swallowing P2/P3 | EMA/MACD never fire on the same bar |
| RSI 40/60 confirm on EMA | Starves prio 2; confirm is **MACD only** |
| MACD pending requiring a *fresh* RSI cross only | If RSI was already >40 on MACD cross, pending expired unused |
| Session filter closing SL/TP / MaxBarsHold | Positions stuck overnight with no management |
| Percent SL/TP as “account risk” | 1% of EURUSD price ≈ 100+ pips, not 1% of balance |
| SL without spread on Bid chart | BUY SL tighter by exactly the spread → spread-stop |

## Other robots

Leave `Event_Scalp.mq5` and `Stochastic_Trend.mq5` alone unless asked. Shared idea: session hours on new entries only; SL/TP/hold still run outside session. Triple-swap pattern is shared with Stochastic (different GV prefix).

## Versions (short)

- **1.90**: triple-swap park/reopen; prio 1 zone retry; failed higher prio does not swallow lower; RSI confirm MACD-only; spread-aware SL/TP + PositionModify verify
