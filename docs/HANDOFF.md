# Latest update — windows and apps in All, and an app card on the shelf (2026-09-25, 0.8.3)

A search under All now ranks open windows and installed apps with the Apps chip's scoring (`AppsSectionController.rank`) and merges them into the results as `ShelfItem.app`; ↩ switches or opens, and the preview is the Apps window preview. Windows are read once per open, on the first search (`loadAppsForSearch`). An `app` intent that names a bundle id, or says `newest`, puts that app's front window first on the shelf with the ring (`AppsSectionController.suggestion`, `Shelf.recents(lead:)`); any other `app` intent still opens Apps. The driver context gains `previousApp` and `runningApps` (bundle ids, at most 8), its reply an `app` field, and outcomes record the app used, so a named app scores a hit only when that app is used.

Gotcha: selecting a window row asks for Screen Recording the first time a preview is wanted, as the Apps chip always has; in QA that system prompt took focus and closed the island once. A plain open with an `app` intent reads every window, about 45–80 ms against a few ms otherwise.

Verification: **135 tests in 25 suites passed**. Live QA on the Debug build through `mbctl`: "30 notes" under All put the Notes window first with its icon and a live preview, and ↩ switched to it (`actedIn: all`, a correct miss against a Finder pick); the driver, told by a temporary strategy to name `previousApp`, answered `app: sh.paseo.desktop`, the shelf showed Paseo's front window first with the ring, and ↩ switched to it (`actedIn: shelf`, hit). QA sessions, the temporary strategy and the driver thread that saw it were removed afterwards.

---

# Latest update — one Codex thread for the driver (2026-09-25)

The driver no longer starts a new `--ephemeral` Codex session per call ([spec](superpowers/specs/2026-09-25-persistent-driver-session.md)). It keeps one thread in MacBud's own Codex home (`~/Library/Application Support/MacBud/codex`, signed in once with `CODEX_HOME=… codex login --device-auth`): the first turn sends the whole instruction, later turns (`codex exec resume <id>`) send only `PredictionPrompts.delta`: opens scored since the last turn, items added since (from `events.jsonl`, which now also logs a newer item under the same key), new strategies if the reviewer rewrote them, and the context. `DriverThread` in `driver.jsonl` survives relaunch; `DriverThread.resumable` starts over past 40 turns or 30k input tokens (settings), on a model change, a lost thread (no `thread.started` on resume) or Reset memory. Without MacBud's sign-in, calls stay ephemeral on the owner's login. The reviewer stays ephemeral.

Gotchas: on resume, `turn.completed.usage` is the thread's running total, so `DriverThread.total` is subtracted to log per-turn tokens. Raw input stays ~9.4k a call; the saving is that a kept thread hits the prompt cache every time, where half the old ephemeral calls missed it (mean uncached 4,704 → ~770 a resumed turn). `rtk` filters `cat`/`grep` output and hides comments; read files with the Read tool. Another agent's unit tests write "Nothing was focused" to the pasteboard, which a running MacBud files into the owner's history.

Prediction Activity shows each call's tokens (input, cached, new, output) and its Codex thread and turn; today's usage counts cached tokens apart.

Verification: **135 tests in 25 suites passed** (new seams: delta builder, rotation rule plus old-settings decoding, resume/relaunch/lost thread through the fake runner). Live QA on the Debug app with the real CLI: one thread across calls and a relaunch (turns 1→6, 8,952 → ~9.1–10k input with 7,936–8,960 cached), Review now sent the new strategies into the same thread, a turn limit of 5 started a new thread with the full instruction, Reset memory and a bogus thread id each led to a new thread. The owner's memory folder and settings were restored afterwards; the call ledger was kept.

---

# Previous update — Prediction Activity window (2026-09-25, 0.8.1)

The owner could not find the call list at the bottom of Settings → Prediction. **Prediction Activity** is now its own window, opened from the menu bar, a button at the top of Settings → Prediction, or ⌘L in the island (`BindableCommand.openPredictionActivity`). `PredictionActivity.timeline` merges the predictor's `calls` and `sessions` into rows (driver, reviewer, open, hit, miss, cap, error), newest first; an open links to the driver call behind its pick by `madeAt`. `details` builds each row's sections, the reviewer diff and the Markdown export from the same data. The window reads the observable predictor, so new calls appear live. Settings → Prediction lost Strategies, Recent opens and Activity; the numbers stay and use the same `usageToday`.

Gotchas: AppKit's frame autosave put the window on the main display after a relaunch, because the saved screen rect no longer matched once the menu bar had moved to the other display; the window keeps its own frame (`predictionActivityFrame`) and restores it when it is on a connected screen. `PanelCoordinator.settingsWindow` skips this window, or ⌘, from the island would not bring Settings front while it is open. Copy goes through `Paster`, so a copied prompt does not enter clipboard history as MacBud's own (dictation) copy.

Verification: **132 tests in 25 suites passed** (new seams: timeline order and pick linking, reviewer diff from the real prompt, Markdown export fencing; the linking test fails when linked by open time). Release build with warnings as errors passed. QA on the real Debug app with the owner's memory files (read only; predictions.jsonl stayed at 66 lines, the running app added its usual background driver calls): opened from the menu bar, Settings and a real ⌘L in the island, each time frontmost; expanded a driver call (note, context, opens that used it, prompt, reply) and the 2026-09-24 reviewer run (summary, 4 added strategy lines, prompt, reply); Misses (3 rows) and Show jumping to the driver call; search "Chrome" (5 rows, matching the files); Export to Markdown (338 lines); a new driver call appeared live; the header matched Settings; the frame came back after close and after a relaunch. **Not seen:** error and cap rows (none in the owner's files; covered by tests), a reviewer diff with removed lines (covered by tests), keyboard focus in the window after opening from the island (activation is cooperative).

---

# Previous update — the notch as a shelf (2026-09-24, 0.8.0)

The five tabs are gone ([spec](superpowers/specs/2026-09-24-notch-shelf.md), [mockup](mockups/option-e-notch-shelf.html)). A plain open (hotkey, tab click, 150 ms hover) shows the **shelf**: the 6 newest clips, screenshots and dictations as cards (`Shelf.merge`/`recents`). ↓, the Search everything chip or typing opens the **island**: search, chips (`Chip`, fixed order, ⌘1…⌘8), Recent cards and an Earlier list with the old previews (`Shelf.layout`). `ShelfController` owns selection and item keys; the feature controllers only act on a given item now. `Shelf.landing` replaced `IntentKind.section`: an app intent opens the island on Apps, anything else puts the ring on that kind's card. `NotchPhase.shelf` has its own size; `canvasPhase` replaces `panelUsesDictationSize`. Saved tab shortcuts decode to chips (`Chip.init(from:)`, `KeyBindings.renamed`); `sectionOrder`, `lastSection` and `rememberLastSection` are no longer read.

Gotchas: a hover-opened shelf is not key (`focus: false`), and only it closes when the pointer leaves (polled, because a fast exit can skip a tracking area's enter). The search field selects all when it takes focus, so `NotchPanel.makeFirstResponder` moves the caret to the end or typing on the shelf loses its first letter (QA caught it). The unit tests write to the real pasteboard (`DictationWorkflowTests`), so a running MacBud files "Nothing was focused" into the owner's history; QA removed those entries.

Verification: **129 tests in 24 suites passed** (new seams: merged recents, chip scoping, intent → landing, key routing in both states with outcome logging, hover dwell, the 0.7.0 settings migration). Release build with warnings as errors and strict signature passed. The screen was locked for the whole QA, so the real Debug app was driven through `mbctl` and the new `mouse` automation command (synthetic clicks through the window's own dispatch, moves handed to the tab view) plus `ImageRenderer` snapshots: hover opened a non-key shelf after the dwell; a click on a card of that shelf copied it and showed the toast; tab click, ↓, typing, chips (click, ⇥ wrap, ⌘6/⌘8), scoped search, Apps grid, ⌘S from the shelf into the snippet editor, dictation start/cancel and the Keep Alive logo all behaved. Prediction logged `actedIn: shelf` (hit) and `actedIn: all` (miss) and did not score a per-chip open. Plain open took 7.7 ms median against 9.5 ms for the 0.7.0 island (20 opens each, same method). **Not seen on a real screen:** keyboard focus while unlocked, ⌘Space tap and hold with real keys, the pointer leaving a hover shelf, paste into a text field, switching to a window (no windows are listed while locked), the reopen-after-close guard, single-click row selection (double-click works), and the Settings panes. QA sessions were removed from `predictions.jsonl` afterwards; the call ledger was kept.

---

# Previous update — predicted opening section (2026-09-24)

⌥Space and the notch tab no longer reopen the last section. `NotchController.sectionForOpen` asks `PanelCoordinator.openingSection()`, which reads a cached **landing intent** (kind + newest/older hint) from `SectionPredictor`, else the rules (screenshot or dictation in the last 60 s, else text). `IntentKind.section` is the only place intents meet tabs, so the planned shelf UI is one edit there. A background `codex exec` driver (gpt-6-luna, medium) fills the cache; a reviewer (gpt-6-sol, high) rewrites `strategies.md` after 10 misses or 12 h with a miss. Outcomes are the kind of item used and whether it was the newest. Everything is in `~/Library/Application Support/MacBud/predict/` and in Settings → Prediction, including every prompt and reply. Codex runs on the owner's own login with `--ephemeral --ignore-user-config`; about 9k input tokens a call.

Gotcha: never call `Process.waitUntilExit()` from async code. QA caught it hanging forever on a concurrency thread after `codex` had exited, which left the predictor busy and silently on rules; `CodexRunner.execute` polls `isRunning` instead.

Verification: **134 tests in 24 suites passed** (new: prompt redaction, failing runner → rules, `codex --json` parsing, misses → reviewer → next driver prompt). Live QA in the Debug app through `mbctl`: a new screenshot opened on Screenshots and copying it scored a hit; a file dictation opened on History and deleting it scored a hit; deleting MacBud's own clipboard copy after a `text` prediction scored a miss; with the threshold at 1 the reviewer ran (15 s) and the next driver prompt carried its strategies. Open took 21.1 ms median with prediction on and 22.8 ms off (same section, 20 opens each); the pick itself 0.55 ms. The Settings pane was checked in an AppKit render, not on screen, because the screen was locked. QA memory was deleted afterwards; the call ledger was kept.

---

# Previous update — section shortcuts follow the tab order (2026-09-05)

⌘1…⌘4 used to name a fixed section (`selectClipboard`, `selectSnippets`, …), so reordering tabs in Settings → Features left Screenshots at position 2 answering to ⌘3. The bindable commands are now tab positions (`selectSection1`…`selectSection4` → `PanelCommand.selectSectionAt(index)`), resolved against `settings.enabledSections` when the key is pressed. Hiding a feature closes the gap rather than skipping a number, and a position with no tab does nothing. Settings written before this keep their chords: decoding moves each retired per-section command to the slot its section held in the default order, and drops commands that no longer exist. Settings → Shortcuts names the current occupant of each slot ("Go to section 2 — Screenshots"), disables slots with no tab, and says the shortcuts follow the tab order; each island tab's tooltip shows the chord that opens it.

Verification: **79 tests in 15 suites passed** (new: slot/section coverage, the legacy-binding migration, and ⌘2 following a reordered and then hidden tab). Checked in the running Debug app against the user's own order (Clipboard, Screenshots, Snippets, History) with real key events through `mbctl`: ⌘1 → Clipboard, ⌘2 → Screenshots, ⌘3 → Snippets, ⌘4 → History. Their saved preferences were left untouched. The new Settings → Shortcuts rows were not visually inspected — the pane's section group sits below the fold and the shell has no Accessibility trust to scroll it.

---

# Previous update — feature preferences, tab order, and full-notch scrolling (2026-09-05)

Settings → Features now has native checkboxes for Clipboard, Snippets, Screenshots, History, Dictation, and Keep Alive, plus accessible arrows to reorder the four section tabs. Ordered IDs and disabled features persist in UserDefaults. Disabled sections are removed from the notch, menu, and dedicated Settings pages; navigation skips them, global shortcuts are unregistered, and cross-feature Save as snippet is gated. Clipboard polling and screenshot watchers/scans stop when disabled. Turning off active Dictation cancels it; turning off Keep Alive releases its assertions. History can be disabled independently of Dictation and stops saving new transcripts. Existing data and shortcut preferences are retained. With all sections off, the notch offers Open Settings.

The 6:56 PM recording revealed that the previous standalone scrolling test did not cover the production masked notch. The replacement test uses NotchController, NotchRootView, the passive panel, wrapped paragraphs, and volume/timer updates. It reproduced the failure with the newest words up to 564 points below the viewport. Wrapping the transcript and end marker in one explicit VStack fixed it. The test now grows through 80 sentences and verifies the actual NSScrollView, with an AppKit-rendered image showing sentences 75–80 at `/private/tmp/macbud-live-transcript-check.png`.

Verification: **76 tests in 15 suites passed**, including persisted/normalized order, selection fallback, all-disabled state, disabled global shortcut release, retained history, Keep Alive shutdown, background-service guards, and production-notch scrolling. Release build, strict signatures, and `git diff --check` passed. The Features settings page was visually inspected in the installed app. The user's new order (Clipboard, Screenshots, Snippets, History) was observed in both the running configuration and notch, and preserved across the final installation. Checkbox preference behavior was covered by tests; interactive attempts were stopped when the user navigated away from Settings, without changing their preferences.

Installed app: `/Applications/MacBud.app`. Previous final app: `/private/tmp/macbud-feature-controls-final.T7wSgL/MacBud.app`; app before this feature work: `/private/tmp/macbud-feature-controls.DvU9oj/MacBud.app`. Evidence: `/private/tmp/macbud-live-scroll-red.log`, `/private/tmp/macbud-live-scroll-layout.log`, `/private/tmp/macbud-feature-controls-tests.log`, `/private/tmp/macbud-feature-controls-release.log`.

---

# Previous update — keep the latest dictation text visible (2026-09-05)

The live transcript now scrolls to its end when its measured scroll range changes, in addition to following transcript callbacks. This catches wrapped text and viewport changes after layout, while short transcripts keep their top alignment. History browsing is unaffected.

The regression hosts the real `DictationView` with a fake speech engine, grows the transcript through 1, 12, 40, and 80 lines, then changes the available space. Before the fix, the newest line ended 28 points below the viewport after reflow; afterward it remained visible. **68 tests in 14 suites**, the Release build, strict signatures, and `git diff --check` passed. Installed in normal mode at `/Applications/MacBud.app`; previous app: `/private/tmp/macbud-transcript-scroll.2JtR36/MacBud.app`. Logs: `/private/tmp/macbud-transcript-scroll-red.log`, `/private/tmp/macbud-transcript-scroll-tests.log`, `/private/tmp/macbud-transcript-scroll-release.log`.

---

# Previous update — synchronized notch reveal and collapse (2026-09-05)

The user's 6:22 PM recording showed controls fading over the wallpaper before the growing black background reached them, and remaining visible outside the shrinking background on close. `NotchSurface` now composes the black background and controls on the existing fixed canvas and clips them with one animated `NotchShape`. Both the full island and dictation use this surface, so content cannot appear beyond the current silhouette. Window geometry, keyboard focus, and existing animation durations are preserved.

A rendering regression freezes intermediate sizes and checks that controls outside the silhouette are transparent while visible controls have an opaque black backing. It failed with five alpha assertions before the fix and passed afterward. **67 tests in 14 suites**, the Release build, strict signatures, and `git diff --check` passed. Closing frames were inspected in the installed app, and the real-microphone startup regression passed with the shared surface. Evidence: `/private/tmp/macbud-animation-red.log`, `/private/tmp/macbud-animation-tests.log`, `/private/tmp/macbud-animation-release.log`. Previous installed app: `/private/tmp/macbud-animation.KKPPx3/MacBud.app`.

---

# Previous update — History and Copy icons (2026-09-05)

History now uses the purple dictation badge as the final tab, with its title shown when selected. Copy has a `doc.on.doc` symbol in both the dictation controls and main-panel footer; empty shortcut chips are no longer rendered. The Release build and strict signature checks passed, and both icons were visually checked in the installed app. The brief dictation check was cancelled with Escape. Previous app: `/private/tmp/macbud-history-copy-icons.cwJ2uW/MacBud.app`.

---

# Previous update — dictation workflow and history (2026-09-05)

Installed the signed Release build at `/Applications/MacBud.app`. Dictation now opens at its final anchored size without taking keyboard focus. A full-width waveform sits above the transcript, with Copy, Insert, and Cancel in the bottom-right action strip. Explicit hosting-view canvas sizes and disabled automatic sizing on the base window prevent the AppKit constraint loops reproduced while opening dictation during a toast.

- Press the configured dictation chord again to stop and insert into the currently focused editable input, or copy when there is no eligible target. This user's existing chord remains **Command-Shift-D**. Return and Command-Return are not dictation commands, and Insert & Send has been removed.
- **Control-Option-D** is the new editable hold-to-talk default. Press starts; release stops and inserts or copies. Release during model preparation is remembered, and repeated key-down events do not restart a session.
- Escape cancels while dictation is active. Carbon handles the global shortcut; scoped AppKit monitors also cover events delivered directly to an application. Command-Option-Escape stays with macOS.
- Dictation keeps the target app focused. Insert waits for shortcut modifiers to be released, checks the current editable Accessibility element and clipboard contents, and posts ordinary Command-V. Direct AXSelectedText writes were rejected after Chromium/Electron reported success without actually inserting.
- The text-only **History** tab persists completed dictations locally, supports search/copy/insert/delete, and opens an exact transcript as a snippet draft through **Save as snippet**. Existing MacBud dictation entries are imported once from clipboard history; saved user data and preferences are preserved.

Verification: **66 tests in 14 suites passed**, the universal Release build passed with warnings treated as errors, strict signatures passed before and after installation, and `git diff --check` passed. Live checks confirmed real microphone recording stays visible and non-key, Escape cancels, Cancel works on its first click, ordinary paste changes a disposable native text field, and History opens the exact transcript in the snippet editor. Four generated test transcripts were removed through the filtered History UI and the disposable snippet draft was cancelled. Press/release dispatch and early release are covered by automated tests; a physical held-key duration was not driven by the UI automation tool.

Evidence: `/private/tmp/macbud-workflow-escape-tests.log`, `/private/tmp/macbud-workflow-complete-release.log`, and `scripts/check-dictation-startup.py` (now starts a toast immediately before recording to cover the base-window regression). Latest previous app: `/private/tmp/macbud-workflow-complete.71W0u5/MacBud.app`; app before this workflow: `/private/tmp/macbud-workflow-update.prizWK/MacBud.app`.

---

# Previous update — transparent sunrise icons (2026-09-05)

Installed the verified Release build at `/Applications/MacBud.app`. The supplied sunrise now has no background or enclosing box. `Resources/Brand/MacBud-Sunrise-Cutout.af` is the native Affinity source, and its transparent PNG export drives all icon sizes. The original attachment remains preserved unchanged. The gold sun and terracotta base were visually checked on the actual black collapsed notch.

The menu bar now uses a separate `MacBudStatusIcon` image set with template rendering in both the asset catalog and SwiftUI, so macOS supplies the appropriate monochrome foreground. AppIcon and MacBudMark retain the artwork's colors. Removed the notch mark's rounded-rectangle clipping.

Verification: Release build and strict signature checks passed; generated PNGs have transparent background pixels; compiled status-bar assets report template mode at both scales; built and installed asset catalogs have matching SHA-256 hashes. Opened and collapsed the installed notch to verify the icon and existing compact Keep Alive switch. No dictation or sleep behavior changed in this follow-up, so the previous functional test results below remain the latest run. Previous installed app: `/private/tmp/macbud-transparent-icons.ZWEDhj/MacBud.app`.

---

# Previous update — sunrise logo and dictation startup (2026-09-05)

Implemented on `codex/dictation-awake-artwork` and installed as a verified Release build at `/Applications/MacBud.app`.

- The app icon, notch, menu bar, welcome screen, and About screen use the user's supplied sunrise logo. `Resources/Brand/MacBud-Sunrise.png` is byte-identical to the attachment, including its cream background. `scripts/make_icon.swift` generates all catalog sizes. Previous Affinity designs remain in the source folder but are unused.
- Removed the dictation icon/button from the tab bar. Dictation remains available through its configured global shortcut (default ⌥⇧D), island bindings, and the menu-bar menu.
- Fixed the startup crash: AVFAudio delivers microphone buffers on an audio queue, but the tap closure inherited MainActor isolation. Marking the closure `@Sendable` prevents the executor assertion while UI callbacks still explicitly hop to MainActor.
- Fixed a second disappearance path: focus changes now leave dictation open instead of cancelling its session. Ordinary expanded tabs still dismiss on focus loss.
- Keep Alive remains a compact native switch after its label, with the sun icon before it. It holds system and display idle-sleep assertions until switched off or the app quits.
- Section headers, search results, and screenshot previews no longer show total counts.
- Dictation retains clickable Insert, Insert & Send, Copy, Cancel, Retry recording, and Discard actions. Saved audio supports retry; cancellation and delivery clean it up. The existing startup/finalization deadlines and paste-target checks remain in place.

Verification: 55 tests in 13 suites passed, including the two new focus-loss tests. The dictation focus test first failed with a collapsed panel and an unwanted cancellation, then passed after the fix. The live startup regression first failed against the old installed app with `MacBud exited after starting dictation`, then passed against the final Release app with real microphone recording visible for three seconds. The check cancelled without delivering text. Release build, strict code-signature verification, asset inspection, original-logo hash comparison, and `git diff --check` passed. Cross-app paste/send was not exercised in this follow-up.

Run `python3 scripts/check-dictation-startup.py` to repeat the live microphone regression. It needs Microphone permission and an installed speech model, waits for app readiness, verifies recording/window state, and cancels without insertion or sending.

The app preceding this follow-up is preserved at `/private/tmp/macbud-sunrise-update.sX3vA1/MacBud.app`. An intermediate build is preserved at `/private/tmp/macbud-sunrise-final.vWk5VR/MacBud.app`. The historical handoff below describes earlier state.

---

# MacBud — handoff (2026-09-05, round 3)

MacBud is a keyboard-first macOS 26 utility that lives in the MacBook notch: clipboard history, snippets,
a screenshot/video browser, and on-device dictation. Repo: `git@github.com:rangrik/macbud.git`
(private, user `rangrik`). Design spec: [superpowers/specs/2026-09-05-macbud-notch-utility-design.md](superpowers/specs/2026-09-05-macbud-notch-utility-design.md).

## State at handoff

| Area | State |
|------|-------|
| Build | `make build` succeeds (Xcode 26.6, Swift 6.3, macOS 26.6, signed with the local Apple Development identity, team `797YU4KXW5`). |
| Unit tests | `make test` → 31 tests in 8 suites pass. |
| Installed copy | `/Applications/MacBud.app` (copied from the Debug build), left running normally (without `MACBUD_AUTOMATION`). Launch at login is registered: the app reports `launchAtLogin: true` and Settings › General shows the toggle on. |
| App data | `~/Library/Application Support/MacBud/` (`clipboard.json`, `snippets.json`, `images/`). Prefs in `com.rangrik.macbud`; `screenshotFolders` is `~/Desktop` only (a scratch e2e folder was removed). Debug trace: `~/Library/Logs/MacBud.log` (written only when launched with `MACBUD_AUTOMATION=1`). |
| Dictation | Present (macOS 26 `SpeechAnalyzer`/`DictationTranscriber`, model installed for en-US) but **deliberately not worked on this round** by the owner's decision. Alignment with the Paseo runbook is listed under next steps. |

## Verified this round, on the installed app with real input events

Everything below was checked on screen (`screencapture -R`) and by driving real mouse/keyboard events
through `CGEventPost` (JXA one-liners, see "How to verify"), not by the `ImageRenderer` snapshots.

1. **Halo gone.** The island silhouette is pure black with no shadow and no edge stroke (`IslandSilhouette`).
2. **Notch tab clicks work.** They did not before: the always-on base window can never become key, and AppKit
   only delivers the first click to a view that accepts first mouse, which SwiftUI's gesture views do not.
   `ClickableHostingView` (in `NotchController.swift`) now owns hit-testing, click and hover in AppKit. The
   duplicate window-level `mouseUp` handler was removed (it made a click open and immediately close).
3. **Tab padding and hover growth.** Wings are 42 pt each (`NotchMetrics.tabExtension`), the icons sit centred
   with room on both sides, and on hover the whole tab grows by 6 pt per side and 4 pt downwards
   (`tabHoverGrowth`) while the icons brighten and move outward. The base window is padded by that growth
   so the tab can animate without resizing the window; the padding is transparent and not clickable
   (`ClickableHostingView.hitInsets`).
4. **Screenshots use the real Desktop.** 16 real items indexed. The filmstrip had a layout bug: a
   fill-mode `Image` sized its cell and spilled across neighbours. Cells are now fixed 150×94 and clipped;
   the large preview shows the strip thumbnail while the full-size render arrives (videos take a moment).
5. **Editable island shortcuts.** Settings › Shortcuts lists every island command with two chord slots.
   Recording was exercised with real input: clicking `＋` on "Move left" shows "Press…", pressing ⌃B shows
   `^B` in the row and the `keyBindings` default then holds `{keyCode: 11, modifiers: control}` next to `←`.
   Routing of custom chords inside the island is covered by `KeyRouterTests`; an on-screen check of ⌃B was
   abandoned because the owner was typing at the time. The test chord was removed by deleting the
   `keyBindings` default with the app stopped (only that one chord had been customised).
6. **Global per-section shortcuts.** ⌥⇧V / ⌥⇧S / ⌥⇧4 open a section directly, ⌥Space toggles, ⌥⇧D dictates.
   ⌥⇧V was verified with a real keystroke. All are editable in Settings › Shortcuts.
7. **Settings opens in front.** ⌘, in the island is handled by the app menu (the main menu sees the key
   before the panel does), and macOS may refuse to activate a background app, so the window used to open
   behind the app the user was in. `PanelCoordinator.didClose()` now orders a newly appeared Settings
   window front regardless of activation; verified with a synthetic ⌘, (the worst case for activation).
8. **Launch at login from the get-go.** `AppDelegate.configureLaunchAtLoginIfNeeded()` registers
   `SMAppService.mainApp` the first time the app runs from `/Applications`; `make install` puts it there.

## How to work on it

```bash
make run        # xcodegen → build → launch from the build dir with MACBUD_AUTOMATION=1
make test       # unit tests (Swift Testing)
make install    # copy to /Applications and launch (enables launch at login on first run)
```

To iterate on the installed copy with automation enabled (what this round used):

```bash
make build && pkill -x MacBud; rm -rf /Applications/MacBud.app && cp -R build/Build/Products/Debug/MacBud.app /Applications/ && MACBUD_AUTOMATION=1 open -a /Applications/MacBud.app
```

## How to verify

- `source scripts/e2e.sh` gives `mb`, `dump`, `typetext`, `keys`, `snap` (uses `build/mbctl`, which posts a
  distributed notification and does not activate the app). `dump` now also reports `launchAtLogin`,
  `installedInApplications`, `bundlePath` and `showsTab`.
- Key sequences: `keys cmd+2`, `keys right,right`; `,` and `+` are reserved by the syntax, so use the
  tokens `comma` and `plus` (e.g. `keys cmd+comma`).
- **Real input events** (the only reliable way to test the tab and ⌘,). Screen coordinates are logical
  points; this Mac runs at 2056×1329 with the notch centred at x≈1028:

  ```bash
  # click
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); var p=$.CGPointMake(895,18); var d=$.CGEventCreateMouseEvent(null,$.kCGEventLeftMouseDown,p,$.kCGMouseButtonLeft); var u=$.CGEventCreateMouseEvent(null,$.kCGEventLeftMouseUp,p,$.kCGMouseButtonLeft); $.CGEventPost($.kCGHIDEventTap,d); delay(0.05); $.CGEventPost($.kCGHIDEventTap,u);'
  # ⌘, (key code 43)
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); var d=$.CGEventCreateKeyboardEvent(null,43,true); $.CGEventSetFlags(d,$.kCGEventFlagMaskCommand); var u=$.CGEventCreateKeyboardEvent(null,43,false); $.CGEventSetFlags(u,$.kCGEventFlagMaskCommand); $.CGEventPost($.kCGHIDEventTap,d); delay(0.03); $.CGEventPost($.kCGHIDEventTap,u);'
  # look at the result
  screencapture -x -R 620,0,820,520 island.png
  ```

  `System Events`' `click at {x, y}` is **not** a real click (it performs an accessibility press) and did not
  reach the tab; use it only for real buttons (Settings toolbar tabs, close buttons). Hover needs a few small
  mouse moves, not one jump, before the tracking area reports it.
- Only send keystrokes after `dump` confirms `"phase": "expanded"`; otherwise they land in whatever app is
  frontmost.
- `scripts/e2e-run.sh` is the older scripted pass. **It deletes the app's preferences and data** — do not run it
  against the owner's real history.
- The SwiftUI `ImageRenderer` snapshots (`snap`) still render the AppKit search field empty and skip Liquid
  Glass; prefer `screencapture`.

## Permissions the user must grant once (signing is stable, so grants persist across builds)

- **Paste from other apps** (macOS 15.4+ pasteboard alert): already "Always Allow" on this Mac.
- **Desktop folder** access: granted (Desktop is being indexed).
- **Accessibility** only for `⌘↩` paste-into-app: not yet granted (Settings › General shows the button).
- **Microphone** for live dictation: not yet granted (Settings › Dictation shows "macOS will ask the first time").

## Known issues / rough edges

- Default `⌥Space` may collide with Raycast; the fallback `⌃⌥Space` is used automatically and the welcome/Settings say so.
- `NSApp.activate()` is cooperative on macOS 14+: a background app may not get activated when Settings opens.
  The window is ordered front regardless, so it is visible, but keyboard focus may stay in the previous app
  until the user clicks it. Real key presses (unlike synthetic ones) usually count as user interaction and
  activation succeeds.
- The transparent 6 pt / 4 pt margin around the notch tab belongs to the base window; it does not take clicks
  (hit-testing returns nil there) but, like any window, it does not pass clicks through to windows underneath.
  Nothing clickable normally lives in that strip.
- `Section` (app enum) shadows SwiftUI's `Section`; use `SwiftUI.Section` in forms.
- Project uses Swift default main-actor isolation; pure data types are marked `nonisolated`.
- `DictationEngine` has four Swift 6 concurrency warnings in the audio tap; Debug builds allow them, the Release
  flags (`-warnings-as-errors`) would not.
- Quick Look (`⌘Y`) from a non-activating panel has not been exercised end to end.
- Wording: the code and docs contain no "cyber"; the only "security" strings are macOS System Settings URLs and the
  "Privacy & Security" pane name in permission hints.

## Suggested next steps (in order)

1. Grant Accessibility and Microphone once, then try `⌘↩` paste and a live dictation.
2. Dictation alignment with the Paseo runbook (`/private/tmp/.../scratchpad/dictation-runbook.md` in the owner's
   notes): a clickable pill with Insert / Insert-and-send (paste, then Return) / Cancel; Retry that re-transcribes
   the captured audio instead of re-recording (write the converted PCM to a temp file during capture); treat
   `AVAudioEngineConfigurationChange` as a failure; fix the tap's concurrency warnings.
3. Commit in small pieces (this round did: `3cb4897` tab clicks/halo/filmstrip, then the tab growth + Settings
   front + shortcut recorder verification).
