# One Codex session for the driver

**Date:** 2026-09-25 · **Status:** approved by the owner in chat; built from this spec.

## Problem

Every driver call starts a new `--ephemeral` Codex session and sends the whole instruction on top of Codex's own
~8.9k-token floor. The ledger shows ~9.4k input a call. Half of those calls miss the model's prompt cache
entirely (29 of 62, even 30 s apart) and pay all of it uncached.

## CLI mechanism (checked on codex-cli 0.156.0)

- `codex exec --json` prints `{"type":"thread.started","thread_id":…}`. `codex exec resume [options] <id> -`
  continues that thread with the prompt on stdin. It has no `-s`, so both use `-c sandbox_mode="read-only"`.
- `--ephemeral` threads cannot be resumed: exit 1, `thread/resume failed: no rollout found for thread id …`,
  and no `thread.started`. So MacBud must store its sessions.
- The thread keeps its base instructions and sandbox. A resumed turn stores only the new message. Codex still
  sends the whole thread to the model, but under one cache key, so most of it is cached.
- On resume, `turn.completed.usage` is the thread's running total. MacBud subtracts the previous total.

Measured on gpt-6-luna medium, per turn. Script: the real driver prompt, then short deltas (session file).
App: the owner's ledger, old calls against this build's QA calls.

| driver call | n | cache misses | uncached input, mean (range) |
|---|---|---|---|
| script, turn 1 (new thread) | 1 | 1 | 8,934 |
| script, turns 2–11 (resumed) | 10 | 0 | 783 (282–1,230) |
| app, old ephemeral call | 62 | 29 | 4,704 (254–9,591) |
| app, new kept thread | 4 | 1 | 6,808 (5,938–8,952) |
| app, resumed turn | 7 | 0 | 768 (290–1,168) |

Raw input stays ~9.4k a call either way; what changes is that a kept thread hits the cache every time.
Each turn adds ~115 tokens; the cache fills in blocks, so uncached input saw-tooths between ~300 and ~1,200.

## Where sessions live

MacBud's own Codex home, `~/Library/Application Support/MacBud/codex`, signed in once with
`CODEX_HOME=<that folder> codex login --device-auth`. Its threads, logs and usage never mix with `~/.codex`.
The owner's home was the other option, but `codex exec` cannot name a thread (only the app-server's
`thread/name/set` can), so MacBud threads could not be told apart there. Without MacBud's sign-in, calls stay
what they are today: a new ephemeral session on the owner's login. Settings shows the command.
The reviewer also runs in MacBud's home when signed in, still ephemeral: it runs rarely and its prompt changes
wholesale every time, so a thread would save little.

## Delta format

The first turn is today's driver prompt (task, kinds, hints, strategies, last 15 scored opens, the rule's
pick, the context) plus one line: later messages carry only what changed. Later turns send:

- **Since your last pick:** each open scored since the last turn, in the same line format as the history;
  each item added since then, from the event log, one line each (`10:41 copied text from com.google.Chrome`,
  `saved a screenshot`, `dictated`), deduplicated by the item's own time. An event is logged on each key change
  and also whenever a newer item arrives, because a second text copy leaves the key unchanged.
- **New strategies from the reviewer**, only when they were rewritten after the last turn.
- **Now:** the rule's pick and the context JSON (app, hour, weekday, kinds, ages of the newest items).

Metadata only, as before: kinds, bundle ids, times and ages. A test guards it.

## Rotation

Resume unless there is no thread, the driver model changed, the thread has 40 turns, or its last turn's input
reached 30k tokens (both settings). New strategies go into the same thread as a message. A lost thread
(resume gives no `thread.started`) is dropped, and the next call 20 s later starts fresh. Reset memory drops it.

Why 40 and 30k: cached input is billed at about a tenth of uncached (OpenAI's rate for its current models;
assumed for gpt-6-luna). With F ≈ 6.8k uncached for a new thread and ~115 tokens added per turn, the mean cost
per call over N turns is about F/N + 0.05·115·N + ~1.7k, lowest near N ≈ 34 and flat around it. At 40 that is
~920 uncached a call against 4,704 for the old calls, about 5× less. A resumed turn would cost more than a new
thread only past ~60k tokens; 30k covers large deltas with room. The cache held across a 10-minute idle gap.

## State

`driver.jsonl` in the memory folder: one line per turn `{id, model, turns, size, total, lastCall}`. The last
line is the current thread, so a relaunch resumes it. The ledger gains `thread` and `turn`, and its `tokens`
are per turn (uncached = input − cached). Old session files in MacBud's Codex home are not pruned yet
(~200 KB per 20-turn thread).

## Fallbacks

Unchanged: any failure leaves the rules in charge. No sign-in → ephemeral new sessions. Lost thread → a new
one on the next call.
