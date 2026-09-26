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

Four roles, each on the model in `agents.json`, spawned by provider + model + effort + mode (no
profiles):

| role        | model       | provider | effort | mode        |
|-------------|-------------|----------|--------|-------------|
| manager     | fable-5.1   | claude   | high   | auto        |
| wayfinder   | fable-5.1   | claude   | high   | auto        |
| implementor | gpt-6-astra | codex    | high   | auto-review |
| qa          | opus-5.5    | claude   | xhigh  | auto        |

- Every agent is started with this one-line prompt and nothing else:
  `You are the <role>. Read config instructions from /Users/pranavkanade/macbud/agents.json.`
  In a worktree, the path is that worktree's `agents.json`.
- Delegation goes only through Paseo `create_agent`, never the harness's in-process subagent tool
  (Claude Code `Agent`/`Task`; Codex Subagents). The user must be able to open and steer any agent.
  Paseo lists such children under a track named "Subagents"; that is not the banned tool.
- The wayfinder is each workspace's inbox. The implementor and QA never ask the user; they write
  `Q<n>` to `questions.md` and ring the wayfinder, which asks the user with `AskUserQuestion` so
  Paseo flags the session "needs you". The manager is the inbox for intake. The Codex implementor
  cannot flag "needs you" at all, which is why it never asks directly.
- Agent-to-agent prompts start with `[from <role>]`; a message without that tag is the user. The
  wayfinder writes each child's role file to `workspace_management/roles/<role>.md` at spawn, so the
  Codex sandbox (no network) can still start on the latest text.
- `workspace_management/` at the worktree root is the handoff dir (`brief.md`, `plan.md`,
  `implementation.md`, `qa-report.md`, `delivery.md`). It is excluded through `.git/info/exclude`
  and never committed. Before any merge it is copied to `.git/agent-handoff/<slug>/` in the main
  checkout, because Paseo has archived a worktree seconds after its PR merged (with
  `autoArchiveAfterMerge: false` set, so treat it as possible any time).
- Never answer another agent's permission prompts. The user approves what their agents do.

## Working with the user

- The user has severe ADHD and is accountable for everything you do. Clarity over volume.
- Every message: a one-line headline, then `N of M done · next: <step>` counted from the role's
  fixed step list (Paseo sessions have no task-list tool), then only what they need.
- One question per message, through `AskUserQuestion` (Claude roles), never plain text: the question
  in one line plus `If you pick nothing: <what waits>` as the question text; 2 to 4 options with a
  one-line implication each; the recommended option first, labelled `(Recommended)`, with its
  reason. Picking it is the user's "your call".
- Silence is never a decision. Only an explicit pick or "your call" decides. Scope, product
  behavior, UX, architecture, risk, cost, time, priorities and anything irreversible are the
  user's calls, never taken alone.
- Restate what was asked and what will be delivered, in your own words, before building.
- Surface every shortcut, guess, skipped test and scope change in one line, when it happens.
  Found-but-unrelated issues go in a follow-ups note, not in this change.
- Say in one line what a long step is before starting it. Text inside an agent's thinking is
  invisible to the user; progress goes in a visible line.
- One shippable unit per workspace, worktree and PR. Independent fixes get their own workspace.
- When a change ships, the wayfinder tells the user in three lines how it works now and where the
  manual test guide is, then asks once whether to archive the workspace.

## Testing on this Mac

The Mac is the user's live desktop, with their own MacBud installed in `/Applications` and running.
Three workspaces have collided here; these are the facts every live check must respect.

- `make stop` runs `pkill -x MacBud`, and `make run` and `make install` call it: they kill every
  MacBud on the machine, including the user's installed app and other worktrees' test copies. Never
  run them during a live check. Launch the Debug build directly:
  `CFFIXED_USER_HOME=/tmp/<slug>-home MACBUD_AUTOMATION=1 open -n -a "$PWD/build/Build/Products/Debug/MacBud.app" --args -clipboardPaused YES -hasSeenWelcome YES`
  and stop only your own copy by path: `pkill -f "$PWD/build/Build/Products/Debug/MacBud.app"`.
- `build/mbctl` posts a distributed notification that every running MacBud receives. Only one test
  copy runs at a time, and the user's installed app must not be the one that receives your command:
  check `pgrep -fl MacBud` before each `mbctl` call and stop if the installed app is the only one up.
- The test suite writes the shared pasteboard, and a running MacBud files it into clipboard history.
  Hold the live-test lock (`.git/agent-live.lock` in the main checkout: one live pass per repo at a
  time, queue on it, never ask the user who goes first) for `make test` as well as for live checks,
  and save and restore the pasteboard around the run.
- `CFFIXED_USER_HOME` isolates `~/Library/Application Support/MacBud` and logs, not preferences:
  `com.rangrik.macbud` prefs are shared with the user's app, and a Settings click in a test copy
  changed the user's real Clock setting once. For Settings checks use a re-signed copy with its own
  bundle id (`ditto` the Debug app to `/tmp`, `PlistBuddy` the `CFBundleIdentifier` to
  `com.rangrik.macbud.<slug>-qa`, re-sign); it loses Accessibility and Screen Recording grants, so
  paste and screenshot checks stay on the signed Debug identity with launch-argument overrides and no
  Settings clicks. Read `defaults read com.rangrik.macbud` before and after every live pass and put
  back anything that changed.
- Pointer, keyboard, focus and mic actions run in bursts under ten seconds, each after the Mac has
  been idle five seconds, with pointer, clipboard and front app put back after every burst; never a
  key press into an app that is not the test copy; mic only for dictation criteria. The user's
  installed MacBud is never quit, replaced or reconfigured by a test; only `make install` in
  delivery replaces it, and that relaunches it.
- `mbctl snapshot` does not render selectable text; use `screencapture -x -R` of the notch region for
  proof, and the throwaway QA hooks under `workspace_management/qa-evidence/scripts/` from earlier
  rounds. Never leave a probe in product source; `git status` must be clean when you finish.
- Dates come from the Mac's clock (`date`), never from memory.

## Conventions and boundaries

- Branches are `claude/<slug>`. Merges to main are squash merges titled as a plain sentence, with
  the version in parentheses when a release ships, e.g.
  `Jev in the shadow of the prediction driver (0.8.4)`.
- Every change adds a "Latest update" entry at the top of `docs/HANDOFF.md`: what changed, the
  gotchas, and the verification (test count, what live QA did and saw). Two workspaces in flight
  will conflict here; when rebasing, keep every entry, yours on top. Design records go in
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
- The implementor builds, runs the tests, and does one short smoke; QA is the only full live pass.
- Delivery in this repo: QA's verdict decides, not the user.
  - QA clean: the wayfinder rings the implementor with `[from wayfinder] QA clean — deliver per
    AGENTS.md`, and the implementor runs the `deliver` skill: PR, merge to main, rebuild Release
    from main, install into /Applications, publish the GitHub release. Stop only where the skill
    says to: failing tests, a dirty tree, a failed signature check, or a `gh` account that cannot
    open the PR. Two adjustments to the skill: copy `workspace_management/` to
    `.git/agent-handoff/<slug>/` before the merge, and use `git switch --detach origin/main` where
    the skill says `git reset --hard` (same tree, no destructive git). Skip the skill's clean-up
    step: the wayfinder asks the user once, about this workspace only.
  - QA fix first (any blocker or major issue, any failing criterion, any UX issue): the wayfinder
    sends the implementor back on its own; QA runs again on the new revision.
  - QA says the user should test it as a user: stop with the branch pushed and wait for the user to
    say "ship" or "deliver" in the wayfinder's session (they mean the same thing).
