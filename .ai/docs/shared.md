# Shared (this folder)

Docs in this repo are **English**. Chat with the user is often Polish. Compile: MetaEditor F7. After changing defaults: **Reset inputs** or tester `.set`/`.ini` keeps old values.

**Bars** = candles on `InpTimeframe` (`PERIOD_CURRENT` = chart TF). Session filter gates **new entries only**; SL/TP/`MaxBarsHold`/trend-flip still run.

**Point** = `SYMBOL_POINT` (5-digit FX: 10 points ≈ 1 pip). Not Dow “index points”.

**Session clocks:** server / GMT / local. Typical windows London ~08 + NY overlap ~13 (hours inclusive).

**Triple swap** (MACD Bull, MACD Bear, Stochastic, default ON): close ~1h before 3-day FX rollover (often Wed ~23:00 server), reopen next day if hold still valid. Bear can **skip parking shorts** when H1 is still down. Irrelevant for many indices; still closes FX if left ON.

News JSON (Stochastic only): `{date: "dd-mm-YYYY HH:MM:SS", signal: positive|neutral|negative}`. Allow URL in WebRequest. Empty URL = dead news. Event_Scalp has no news path.

Do not “fix” one robot by copying filters from another. Scalp = impulse + light closed-bar ADX/ATR (H1 optional), never tick-burst/z-score; MACD Bull = EMA/SMA trend + RSI/MACD entries (fade stack only if TrendFollow is off); MACD Bear = same family plus H1 gate, no MA-cross entry, split long/short, hysteresis flip; Stoch = EMA 81/255 + oscillator.
