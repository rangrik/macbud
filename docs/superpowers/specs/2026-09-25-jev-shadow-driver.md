# Jev in the shadow of the driver (2026-09-25)

Question: can TypeSafe's Jev (`jev-1.13.0`, a "System One" model that returns a typed choice with
probabilities and a confidence, never text) replace `gpt-6-luna` as the prediction driver?

## Offline replay

`scripts/jev-replay.py` sends the 10 scored opens on disk (history = the scored opens before each)
and 6 hand-written probes with an obvious answer through Jev. Two choice questions: the kind, and
newest / older / either. The hint becomes `any` on `either` or a confidence under 0.5.

| Variant | Probes (6) | Scored opens (10) | Kind only (10) |
|---|---|---|---|
| With the reviewer's rules | 2 | 9 | 9 |
| Without the rules | 5 | 2 | 6 |
| Recorded pick (Luna or rules) | – | 6 | 7 |
| Rules alone | – | 7 | 7 |

Read with care. The reviewer wrote its rules from these same 10 opens, so "with rules" is leaky, and
the rules literally say "default to text/any", which is why they flatten the probes. Cold, Jev reads a
fresh link or image copy at 0.9 confidence, a screenshot 5 s old at only 0.5, and over-commits to
"newest" when the owner reached for older text. Ten points decide nothing.

What is not in doubt: a call is about 150 ms and 1,000 to 1,600 input tokens ($0.00005) against Luna's
4.4 s median and about 12,000 tokens.

## Decision

Run Jev in the shadow. It gets the same moments, rules and history as the driver; its pick is stored
on each open (`SessionRecord.shadow`, `shadowHit`) and never lands. Settings → Prediction shows its
7-day rate next to the landing's on the same opens. The key lives in
`~/Library/Application Support/MacBud/typesafe-api-key`; no file, no calls. Shadow calls stay outside
the daily cap. The reviewer stays on Codex: Jev cannot write strategies.

Decide after 50 or more scored opens. If Jev leads by a clear margin, make it the driver; if it trails,
remove the shadow.
