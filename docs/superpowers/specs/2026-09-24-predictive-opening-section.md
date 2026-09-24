# Predictive opening section

**Date:** 2026-09-24 · **Status:** approved by the brief; built from this spec.

## Problem

⌥Space reopens the last used section, so the same key lands somewhere different each time. The owner looks,
then reaches for the trackpad. Opening should land where the owner most likely wants to be, and the choice
should get better from the owner's own corrections.

## Shape

The predictor answers with a **landing intent**, not a tab: a kind from
`text · link · image · screenshot · dictation · snippet · app`, a hint (`newest`, `older` or `any`) and a
confidence. `newest` means the most recent item of that kind; for `app`, the window of the app the owner just
left. One function, `IntentKind.section`, maps an intent to today's tab: screenshot → Screenshots,
dictation → History, snippet → Snippets, app → Apps, text/link/image → Clipboard.

1. **Heuristic baseline**, always present and the only fallback: a screenshot saved in the last 60 s →
   `screenshot/newest`; a dictation finished in the last 60 s → `dictation/newest` (the newer wins); else
   `text/any`. Only kinds whose feature is enabled are ever chosen.
2. **Driver** (`gpt-6-luna`, `medium`) runs in the background when the context changes and caches its intent.
3. **Reviewer** (`gpt-6-sol`, `high`) reads the driver's misses and notes and rewrites `strategies.md`,
   which the driver reads on every later call.

Opening never waits on a model. `open` reads the cache: a fresh intent for the current context key wins;
otherwise the heuristic's. Explicit opens (⌥⇧V, menu items) are not predictions and are not scored.
With prediction on, "Reopen the last used section" is ignored (the toggle is greyed out).

**Strategies are free text, not executable rules.** Opening only ever reads a cache, so rules evaluated by
the app would not make opening faster; they would only add a rule format, a parser and a validator.

## Signals (metadata only)

Captured from the existing stores when needed, so feature code gets no new hooks: hour, weekday; frontmost
app bundle id; latest clipboard item kind, source bundle id and age in seconds; latest screenshot kind and
age; latest dictation age; the kinds the owner can reach. Never clipboard text, dictation text, snippet text,
file names, paths or window titles. A test guards this seam, and that prompts never name today's tabs.

**Context key** = `app | hour | recent flags | clipboard kind`; a flag is set when that source changed in the
last 120 s. A cached intent is fresh when its key matches and it is under 30 min old. Up to 20 keys are cached.

**Triggers.** A 5 s tick compares the key. When it has held for one tick, the driver runs if the key is not
cached, no call is running, 20 s have passed since the last call (5 min after a failure), and the daily cap is
not reached. Each key change is appended to `events.jsonl`.

## Outcome

A session starts when a plain open uses the prediction and ends when the island closes. The **outcome** is the
first item the owner uses (copy, paste, insert, switch, or pin, delete, Quick Look, Finder, snippet edit on
the selected item), by key or mouse: its kind, and whether it was the newest of its kind. MacBud's own
clipboard copies are dictation output and count as `dictation`; copied files count as `text`. No use means
the session is written but not scored. **Miss** = a different kind than predicted, or a wrong `newest`/`older`
hint. The tab acted in is logged too. Both the model's and the heuristic's intents are logged per session,
so both hit rates are comparable.

## Reviewer trigger (defaults, all settings)

Run the reviewer when **10 unreviewed misses** have built up, or when at least one unreviewed miss exists
and **12 hours** have passed since the last review (or since the first session), whichever comes first.
Unreviewed = after `strategies.md` was last written. Checked after each miss and on the tick. A failed review
waits 30 min. It runs in the background like every call.

## Prompts

Both describe the intent vocabulary, never tabs, and go to `codex exec` on stdin with a one-line instruction
file ("Reply with JSON only, matching the schema. You have no tools.") and `--output-schema`.

- **Driver:** what each reachable kind means and the hints; `strategies.md`; the last 15 scored sessions
  (time, app, predicted, the rule's intent, what was used, hit); the heuristic's intent; the context as JSON.
  Schema: `kind` (enum of reachable kinds), `hint`, `confidence` 0–1, `note` (one sentence: why).
- **Reviewer:** the vocabulary and what a miss means; current strategies; 7-day hit rates; unreviewed misses
  with their context and the driver's note; the last 20 hits. At most 40 lines of concrete rules of thumb;
  keep what holds, drop what the misses contradict. Schema: `strategies`, `summary`. Capped at 40 lines.

## Codex CLI

`codex exec --ephemeral --ignore-user-config --skip-git-repo-check -s read-only -m <model>
-c model_reasoning_effort=<effort> -c model_instructions_file=… -c include_environment_context=false
-c include_permissions_instructions=false -c web_search=disabled -c features.<tool>=false … --output-schema
<file> --json -`, with the prompt, schema and instructions in a temp folder per call.

It runs on the owner's existing Codex login: no separate sign-in (the app-server would use the same login and
adds nothing needed here). `--ephemeral` keeps runs out of their Codex history; `--ignore-user-config` keeps
their MCP servers and settings out. Usage stays separate in MacBud's own ledger. About 9k input tokens per
call is Codex's own floor with tools off. Tokens come from `turn.completed.usage`; the reply is the last
`agent_message`. Timeouts: driver 30 s, reviewer 120 s. The `codex` binary is found once through the owner's
login shell (`zsh -lic 'command -v codex'`) and shown in Settings; Homebrew's 0.153 lacks `gpt-6-luna`.

## Files (`~/Library/Application Support/MacBud/predict/`, plain JSONL and Markdown)

- `events.jsonl` — `{t, context}` per context-key change.
- `predictions.jsonl` — per session: `t, context, heuristic, model {intent, note, key, madeAt}, landed,
  source, opened, actedIn, outcome {kind, newest}, action, secs, hit`. The driver's note sits next to its outcome.
- `strategies.md` — the reviewer's current text.
- `calls.jsonl` — the ledger: `t, purpose, model, effort, ms, status, error, tokens {input, cached, output,
  reasoning}, prompt, reply`. It feeds the usage counters, the daily cap and the Activity view.

JSONL files are trimmed to their newer half past 2 MB. **Reset memory** deletes events, predictions and
strategies; the ledger stays, so today's cap and usage stay honest.

## Fallbacks

Setting off, CLI missing, auth or model error, timeout, bad reply (unknown or unreachable kind) or daily cap
reached → heuristics only, with one line in Settings. Never a dialog.

## Settings → Prediction

Toggles "Open on the predicted section" and "Learn with Codex" (kill switch); a status line with the reason.
Driver and reviewer model and effort, the `codex` path. Numbers: misses before review, hours between reviews,
daily call cap (100). Last 7 days: hit rate of the model and of the rules. Today: calls and tokens per model.
The current strategies and when they were written. **Recent opens** (intent, what was used, hit).
**Activity**: every call with its full prompt and reply. Buttons: Review now, Open memory folder, Reset memory.

## Future UI

The owner chose the notch as a shelf (last ~6 items of every kind as cards) with a "Search everything" field
and kind chips (All · Text · Links · Images · Screenshots · Dictations · Snippets · Apps). Tabs go away. Only
`IntentKind.section` changes then: an intent picks the preselected chip, which shelf card gets the ring (the
hint), and whether to open straight into expanded (for example `app`). Signals, memory, prompts, the review
loop and Settings already speak in kinds and items, so the data stays valid.

## Evidence

`Trace` logs the time spent picking and the whole `open`, with prediction on and off.
`macbud://dump` gains a `prediction` block (status, cache size, last session) for scripted QA.
