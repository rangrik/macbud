# MacBud

A keyboard-first macOS utility in the MacBook notch: clipboard history, snippets, screenshots,
on-device dictation, a clock, Keep Alive, and a prediction layer that guesses what you want when
the notch opens. Swift 6, SwiftUI + AppKit, macOS 26, Apple Silicon. `CLAUDE.md` is a symlink to
this file; Claude Code and Codex read the same text.

## Run, build, test

- `make build` regenerates `MacBud.xcodeproj` from `project.yml` (xcodegen), then builds Debug.
  A new source file is invisible to tests until xcodegen has run, so build before you test.
- `make run` builds and launches Debug with `MACBUD_AUTOMATION=1`; `build/mbctl` drives the app.
- `make test` runs the Swift Testing suite through `scripts/xcfilter.sh`, which hides the failure
  summary. For the real result run the same xcodebuild unfiltered and grep for `Failing tests:`
  and `Test run with`:
  `rtk proxy "xcodebuild -project MacBud.xcodeproj -scheme MacBud -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64' test"`
- No lint step and no CI. Release builds with `-warnings-as-errors`, Debug does not, so a warning
  left behind fails delivery. Build Release (`make release`) before calling a change done.
- `make log` streams the app log (subsystem `com.rangrik.macbud`).
- The `rtk` hook filters `cat`, `grep` and `curl` output and can truncate what a redirect writes
  to a file. Read files with the Read tool; edit data files with Python or the Edit tool.

## Agents in this repo

Four roles, each on the model in `agents.json`, spawned by provider + model (no profiles):

| role        | model       | provider | thinking |
|-------------|-------------|----------|----------|
| manager     | fable-5.1   | claude   | high     |
| wayfinder   | fable-5.1   | claude   | high     |
| implementor | gpt-6-astra | codex    | high     |
| qa          | opus-5.5    | claude   | xhigh    |

- Every agent is started with this one-line prompt and nothing else:
  `You are the <role>. Read config instructions from /Users/pranavkanade/macbud/agents.json.`
  In a worktree, the path is that worktree's `agents.json`.
- Delegation goes only through Paseo `create_agent`, never the harness's in-process subagent tool
  (Claude Code `Agent`/`Task`; Codex Subagents). The user must be able to open and steer any agent.
- `workspace_management/` at the worktree root is the handoff dir (`brief.md`, `plan.md`,
  `implementation.md`). It is excluded through `.git/info/exclude` and never committed.
- Never answer another agent's permission prompts. The user approves what their agents do.

## Working with the user

- The user has severe ADHD and is accountable for everything you do. Clarity over volume.
- Every message: a one-line headline, then `N of M done · next: <step>`, then only what they need.
- One question per message, in four parts: the question in one line; 2 to 4 options with a
  one-line implication each; `Recommendation: <n> — <reason>`; `If you pick nothing: <what waits>`
  and, as the last line, `Say "your call" and I take the recommendation.`
- Silence is never a decision. Only an explicit pick or "your call" decides. Scope, product
  behavior, UX, architecture, risk, cost, time, priorities and anything irreversible are the
  user's calls, never taken alone.
- Restate what was asked and what will be delivered, in your own words, before building.
- Surface every shortcut, guess, skipped test and scope change in one line, when it happens.
  Found-but-unrelated issues go in a follow-ups note, not in this change.
- Progress lives in the harness task list (Claude Code `TaskCreate`/`TaskUpdate`; Codex
  `update_plan`), kept current. Say in one line what a long step is before starting it.
- One shippable unit per workspace, worktree and PR. Independent fixes get their own workspace.

## Conventions and boundaries

- Branches are `claude/<slug>`. Merges to main are squash merges titled as a plain sentence, with
  the version in parentheses when a release ships, e.g.
  `Jev in the shadow of the prediction driver (0.8.4)`.
- Every change adds a "Latest update" entry at the top of `docs/HANDOFF.md`: what changed, the
  gotchas, and the verification (test count, what live QA did and saw). Design records go in
  `docs/superpowers/specs/`, dated. Use the newest HANDOFF entries to learn the prediction layer
  before touching it.
- The version bump in `project.yml` and the note in `docs/releases/vX.Y.Z.md` happen only in
  delivery, never inside the feature change.
- Tests live in `Tests/MacBudTests`, at critical seams only. Before adding one, name the seam it
  guards and the failure it catches. A test must not dwarf what it tests. Never add a test for
  coverage alone.
- Comments and docstrings: under two lines, plain words, only the "why".
- Removing code is the goal; every added line needs a reason.
- Never touch the owner's live data under `~/Library/Application Support/MacBud/` (prediction
  memory, the Codex home, the API key, clipboard history). A running MacBud files test pasteboard
  writes into the owner's history; if QA leaves sessions or strategies behind, remove them and say
  so in the HANDOFF entry.
- Local tests and the Debug app are disposable: run them, fix failures and rerun without asking.
- No force-push, no destructive git, no edits to the tracked `.gitignore` for agent files.

## Done means

- The unfiltered xcodebuild test run shows no `Failing tests:` line, and `make release` builds
  with no warnings.
- The `plan.md` criteria are met, and a UX QA pass drove the real app (`make run` plus `mbctl`)
  looking for what was not intended, not to confirm what was meant. What was seen is in the
  HANDOFF entry.
- Delivery in this repo overrides the draft-PR-only default in the user's preferences:
  - QA clean: run the `deliver` skill without being asked. PR, merge to main, rebuild Release from
    main, install into /Applications, publish the GitHub release. Stop only where the skill says
    to: failing tests, a dirty tree, a failed signature check, or a `gh` account that cannot open
    the PR.
  - QA fails and decides the user should test it as a user: stop with the branch pushed and wait
    for the user to say "ship" or "deliver" (they mean the same thing).
