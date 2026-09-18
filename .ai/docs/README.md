# Docs for agents

Human-readable write-ups (English, not a substitute for these files): `docs/README.md`.

Do not assume input defaults from chat memory. Read the live `input` block in the EA you are touching. Tester `.set` / `.ini` and the chart override compiled defaults until the user Resets inputs.

## Event_Scalp

1. `event-scalp.md` — behavior, pitfalls, history
2. Then the live `Event_Scalp.mq5` inputs (source of truth)

## MACD_RSI_Cross_Bull

1. `macd-rsi-cross-bull.md`
2. Then the live `MACD_RSI_Cross_Bull.mq5` inputs

## MACD_RSI_Cross_Bear

1. `macd-rsi-cross-bear.md`
2. Then the live `MACD_RSI_Cross_Bear.mq5` inputs

Do not change `MACD_RSI_Cross_Bull.mq5` when working on Bear.

## Stochastic_Trend

1. `stochastic-trend.md`
2. Then the live `Stochastic_Trend.mq5` inputs

Do not change an EA unless asked. Shared idea across all of them: session hours on **new entries** only; SL/TP/hold/flip still run outside session.
