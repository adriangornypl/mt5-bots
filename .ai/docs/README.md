# Docs for agents

Human-readable write-ups (English, not a substitute for these files): `docs/README.md`.

Do not assume input defaults from chat memory. Read the live `input` block in the EA you are touching. Tester `.set` / `.ini` and the chart override compiled defaults until the user Resets inputs.

## Event_Scalp

1. `event-scalp.md` — behavior, pitfalls, history
2. Then the live `Event_Scalp.mq5` inputs (source of truth)

## MACD_RSI_Cross

1. `macd-rsi-cross.md`
2. Then the live `MACD_RSI_Cross.mq5` inputs

## Stochastic_Trend

1. `stochastic-trend.md`
2. Then the live `Stochastic_Trend.mq5` inputs

Do not change an EA unless asked. Shared idea across all three: session hours on **new entries** only; SL/TP/hold still run outside session.
