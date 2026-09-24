# Predictive opening section

**Date:** 2026-09-24 · **Status:** approved by the brief; built from this spec.

## Problem

⌥Space reopens the last used section, so the same key lands somewhere different each time. The owner looks,
then reaches for the trackpad. Opening should land on the section the owner most likely wants, and the choice
should get better from the owner's own corrections.

## Shape

1. **Heuristic baseline**, always present and the only fallback. In order: a screenshot saved in the last 60 s →
   Screenshots; a dictation finished in the last 60 s → History (the newer of the two wins); else Clipboard;
   else the first enabled tab. Only enabled sections are ever chosen.
2. **Driver** (`gpt-6-luna`, `medium`) runs in the background when the context changes and caches its pick.
3. **Reviewer** (`gpt-6-sol`, `high`) reads the driver's misses and notes and rewrites `strategies.md`,
   which the driver reads on every later call.

Opening never waits on a model. `open` reads the cache: a fresh entry for the current context key wins;
otherwise the heuristic. Explicit opens (⌥⇧V, menu items) are not predictions and are not scored.
With prediction on, "Reopen the last used section" is ignored (the toggle is greyed out).

**Strategies are free text, not executable rules.** Opening only ever reads a cache, so rules evaluated by
the app would not make opening faster; they would only add a rule format, a parser and a validator.
Free text lets the reviewer say what it sees, and the driver already runs off the main path.

## Signals (metadata only)

Captured from the existing stores when needed, so feature code gets no new hooks:
time, hour, weekday; frontmost app bundle id; latest clipboard item kind, source bundle id and age in
seconds; latest screenshot kind and age; latest dictation age; enabled sections. Never clipboard text,
dictation text, snippet text, file names, paths or window titles. A test guards this seam.

**Context key** = `app | hour | recent flags | clipboard kind`, where a flag is set when that source changed
in the last 120 s. A cached pick is fresh when its key matches and it is under 30 min old. Up to 20 keys are
cached, so switching between a few apps does not cost a call each time.

**Triggers.** A 5 s tick compares the key. When it has held for one tick, the driver runs if the key is not
cached, no call is running, 20 s have passed since the last call (5 min after a failure), and the daily cap is
not reached. Each key change is appended to `events.jsonl`.

## Outcome

A session starts when a plain open uses the prediction and ends when the island closes. **Actual** is the
section of the first action (copy, paste, insert, switch, pin, delete, snippet edit, Quick Look, Finder),
from keys or mouse. With no action, it is the last section the owner switched to. With neither, the session
is written but not scored. **Miss** = actual differs from the section we opened on.
Each session logs the heuristic's pick and the model's pick (if fresh) so both hit rates are comparable.

## Reviewer trigger (defaults, all settings)

Run the reviewer when **10 unreviewed misses** have built up, or when at least one unreviewed miss exists
and **12 hours** have passed since the last review (or since the first session), whichever comes first.
Unreviewed = after the last successful review call. Checked after each miss and on the tick. A failed review
waits 30 min before retrying. It runs in the background like every call.

## Prompts

Both go to `codex exec` on stdin with a one-line instruction file ("Reply with JSON only, matching the
schema. You have no tools.") and `--output-schema`.

- **Driver:** what each section is for; `strategies.md`; the last 15 scored sessions (time, app, opened,
  actual, hit); the heuristic's pick; the current context as JSON. Schema: `section` (enum of enabled
  sections), `confidence` 0–1, `note` (one sentence: why, for the reviewer).
- **Reviewer:** current strategies; 7-day hit rates; unreviewed misses with their context, the model's pick,
  the heuristic's pick, the actual section and the driver's note; the last 20 hits for balance. Instructions:
  at most 40 lines, concrete rules of thumb, keep what still holds, drop what the misses contradict.
  Schema: `strategies` (full new text), `summary` (one line). The app rewrites the file, capped at 40 lines.

## Codex CLI

`codex exec --ephemeral --ignore-user-config --skip-git-repo-check -s read-only -m <model>
-c model_reasoning_effort=<effort> -c model_instructions_file=… -c include_environment_context=false
-c include_permissions_instructions=false -c web_search=disabled -c features.<tool>=false … --output-schema
<file> --json -`. Tokens come from `turn.completed.usage`; the reply is the last `agent_message`.
Timeouts: driver 30 s, reviewer 120 s.

- **Own home (shipped):** `CODEX_HOME=~/Library/Application Support/MacBud/codex`, with a `config.toml`
  that stores the login in a file there. No skills, plugins or sessions of the owner's. The owner signs in
  once: `CODEX_HOME="$HOME/Library/Application Support/MacBud/codex" codex login --device-auth`.
  Until `auth.json` exists there, no call is made.
- **Shared home (QA only):** `MACBUD_CODEX_SHARED_HOME=1` in the environment uses `~/.codex`; `--ephemeral`
  and `--ignore-user-config` mean nothing is saved and none of the owner's config loads (~9k input tokens).
- The `codex` binary is found once per launch through the owner's login shell (`zsh -lic 'command -v codex'`),
  resolved to its real path, and shown in Settings. Homebrew's 0.153 does not know `gpt-6-luna`.

## Files (`~/Library/Application Support/MacBud/predict/`, plain JSONL and Markdown)

- `events.jsonl` — `{t, context}` per context-key change.
- `predictions.jsonl` — per session: `t, context, heuristic, model {section, confidence, note, age},
  opened, source, actual, action, secs, hit`. The driver's note lives here, next to its outcome.
- `strategies.md` — the reviewer's current text.
- `calls.jsonl` — the ledger: `t, purpose, model, effort, home, ms, status, error, tokens {in, cached, out,
  reasoning}, prompt, reply`. It feeds the usage counters, the daily cap and the Activity view.

JSONL files are trimmed to their newer half past 2 MB. **Reset memory** deletes events, predictions and
strategies; the ledger stays, so today's cap and usage stay honest.

## Fallbacks

Setting off, CLI missing, not signed in, auth or model error, timeout, bad reply (unknown or disabled
section) or daily cap reached → heuristics only, with one line in Settings. Never a dialog.

## Settings → Prediction

Toggles "Open on the predicted section" and "Learn with Codex" (kill switch). Status line with the reason
and, when not signed in, the sign-in command with a Copy button. Driver and reviewer model and effort, the
detected `codex` path. Numbers: misses before review, hours between reviews, daily call cap (100). Last 7 days:
hit rate of the model and of the heuristic. Today: calls and tokens per model. The current strategies and
when they were written. **Recent opens** (context, opened, actual, hit). **Activity**: every call with its
full prompt and reply. Buttons: Review now, Open memory folder, Reset memory.

## Evidence

`Trace` logs the time spent picking the section and the whole `open` call, with prediction on and off.
`macbud://dump` gains a `prediction` block (status, cache size, last session) for scripted QA.
