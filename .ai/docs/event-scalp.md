# Event_Scalp

M5 scalper in `Event_Scalp.mq5`. Magic `26091401`. Goal: trade **long impulse candles** (news + rapid range vs ATR), same forming bar (shift 0), not Stoch/MACD trend.

User-facing docs are English. Compile in MetaEditor (F7). After input-default changes: user must **Reset inputs** or old chart/tester values stick.

## Signals

- **News** (`OnTimer`): API JSON `date` + `signal` (`positive`→BUY, `negative`→SELL, `neutral` skip). Flip closes opposite, lot × `InpNewsFlipLotMult`. Needs WebRequest URL allow-list.
- **Rapid** (`OnTick`): forming bar **range (high−low)** vs ATR(14) of **closed** bar (buffer shift 1). Direction = close vs open. One shot per bar (`g_armState` / `g_openedBar`).

News and Rapid can conflict. `InpNewsRequireRapid` waits for same-direction Rapid (`InpNewsConfirmBars`). Pending news must **not** fully disable Rapid (that starved both).

## Why it missed long candles (do not reintroduce blindly)

AND-stack killed M5 impulses:

| Filter | Effect |
|---|---|
| Qualify on `\|close−open\|` not range | Wicky long bars fail |
| `InpRapidAtrMax` as skip | Cap **below** `InpRapidAtrMult` skips almost everything. `0.2` with min `1.0` is invalid — treat max `<` min as **off** |
| Pullback 20–35% | Many long M5 bars never retrace → arm then never enter |
| M1: 2 closed bars same color | Blocks a 1–2 minute spike; missing M1 history used to **block** (should pass) |
| Velocity only in first 90s of the M5 | Spike at minute 2–5 never sets `g_velOk` |
| Spread % of SL | News spikes widen spread → skip |
| Strict body 0.60 + close-in-last-30% | Extra rarity |

v2.11 direction that worked better: range ≥ ATR×mult, enter **immediately** on qualify, M1/velocity off by default, no max-cap skip, doji floor ~25% body.

## Compile

`HistoryDealGetString` / `HistoryDealGetInteger` always need **deal ticket** (unlike `PositionGetString` after `PositionSelect`):

`HistoryDealGetString(deal, DEAL_SYMBOL)` — not `HistoryDealGetString(DEAL_SYMBOL)`.

`#property strict` is present; unused `OnTradeTransaction` `request`/`result` may warn.

## Tester

INI: `Name=value||start||step||stop||Y\|N` — first field is the used value. `InpTimeframe=5` = `PERIOD_M5`.

Profile (optimized, **not** blindly applied as code defaults — user reverted that):

`MQL5/Profiles/Tester/Event_Scalp.EURUSD.pro.M5.20260101_20260915.000.ini`

EURUSD.pro M5, every tick, 2026.01.01–2026.09.15: News off, Rapid on, ATR min 1.0, max 0.2 (broken as cap), 40 pts, body 0.55, closePos 0.10, pullback 0.30–0.55, M1 on/2, SL/TP ATR 1.3/2.0, no struct SL, trail 0.1, no M1 trail, max 4 pos, hold 7, session 8–17+13–21.

Do not load old `Event_Scalp.set` after default changes. Tester needs M1 data if `InpRapidUseM1`.

## Other robots

Leave `MACD_RSI_Cross.mq5` and `Stochastic_Trend.mq5` alone unless asked. See `macd-rsi-cross.md` and `stochastic-trend.md`. Shared idea: session hours on new entries only; SL/TP/hold still run outside session. News JSON is shared with Stochastic.

## Versions (short)

- **2.00–2.02**: news + rapid on forming bar; rapid = range vs 1.8 ATR, SL/TP points, hold 6
- **2.10**: ATR stops, BE/trail, pullback, M1, velocity, news∧rapid — too few trades
- **2.11**: range-based long bar, immediate entry, looser M1/velocity
- **2.12**: EURUSD tester values as defaults — **reverted by user**
