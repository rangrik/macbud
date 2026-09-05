# MacBud — handoff (2026-09-05)

MacBud is a keyboard-first macOS 26 utility that lives in the MacBook notch: clipboard history, snippets,
a screenshot/video browser, and (work in progress) on-device dictation. Repo: `git@github.com:rangrik/macbud.git`
(private, user `rangrik`). Design spec: [superpowers/specs/2026-09-05-macbud-notch-utility-design.md](superpowers/specs/2026-09-05-macbud-notch-utility-design.md).

## State at handoff

| Area | State |
|------|-------|
| Build | `make build` succeeds (Xcode 26.6, Swift 6.3, macOS 26.6, signed with the local Apple Development identity, team `797YU4KXW5`). |
| Unit tests | `make test` → 31 tests in 8 suites pass. |
| Commits | `bab8449` spec · `bbb1f78` first full build of the island · **this commit** = the work-in-progress described under "Round 2" plus this document. |
| Running copy | Launched from `build/Build/Products/Debug/MacBud.app`. **Not yet installed to `/Applications`** (`make install` does that); launch-at-login only auto-enables when running from `/Applications`. |
| App data | `~/Library/Application Support/MacBud/` (`clipboard.json`, `snippets.json`, `images/`). Prefs in `com.rangrik.macbud`. Debug trace: `~/Library/Logs/MacBud.log`. |

## What is done and verified end to end (round 1)

Verified by scripted runs (`scripts/e2e.sh` helpers, `build/mbctl` transport) plus snapshot inspection:

- **Island window** anchored to the notch: non-activating `NSPanel` at pop-up-menu level, flush with the screen top,
  centred on the notch (geometry read from `NSScreen.auxiliaryTop*Area`), spring open/close animation, concave top
  fillets so it grows out of the bezel. Ordered out when collapsed so the desktop stays clickable.
- **Clipboard history**: change-count polling, text/link/image/file capture, de-dup by content hash, pin, trim to limit,
  concealed/transient pasteboard types and ignored apps skipped, atomic JSON persistence with a fixed save race
  (a launch-time save could previously wipe history — fixed by saving only after load and reading items after the debounce).
- **Search**: Raycast-style matcher (prefix > word start > substring > subsequence, multi-token AND, diacritic-insensitive)
  with highlighted matches.
- **Actions**: `↩` copy & collapse with a "Copied" pill under the notch; `⌘↩` paste into the previous app via ⌘V
  (needs Accessibility; otherwise copies and prompts); `⌘⌫` delete, `⌘⇧⌫` two-step clear, `⌘P` pin, `⌘S` save as snippet.
- **Snippets**: store with starter items, keyword/name/content search, in-island editor (`⌘N`/`⌘E`, `⌘S` save, `esc` cancel),
  placeholders `{clipboard} {date} {time} {datetime} {date:FORMAT} {uuid} {cursor}` (cursor moves the caret back after pasting).
- **Screenshots**: folder scanning by UTType, folder watchers, QuickLook thumbnails, copy puts file URL + image data on one
  pasteboard item (Slack gets the file, image apps get pixels; videos carry the URL), `⌘⌫` moves to Trash, `⌘R` Finder, `⌘Y` Quick Look.
- **Global hotkey** via Carbon `RegisterEventHotKey` (default `⌥Space`, automatic fallback to `⌃⌥Space` if taken),
  optional per-section hotkeys, hotkey recorder in Settings.
- **Welcome screen** on first run, menu bar item (`MenuBarExtra`), Settings window, URL scheme `macbud://open|toggle|close`.

## Round 2 (uncommitted until this commit) — implemented, compiles, unit-tested, **not yet re-verified in the running app**

My context was reset partway through this round, so treat each item as "code present, needs a visual/e2e pass":

1. **Halo removed**: the island no longer draws a drop shadow; it uses a hairline edge (`NotchRootView.swift`, `IslandSilhouette`).
2. **Persistent notch tab**: the always-on base window widens the notch by `tabExtension` (30 pt) on each side and draws an
   icon; clicking it toggles the island, hover state included. Setting `showNotchTab` (default on); a pause glyph shows
   when clipboard capture is paused (`NotchBaseView`, `NotchTabContent`, `NotchMetrics.collapsedWindowFrame(tab:)`).
3. **Editable island shortcuts**: `KeyBindings` (up to two chords per command, JSON in UserDefaults, conflict detection)
   replaces the hard-coded `KeyRouter` table; footer hints reflect the user's chords and are clickable buttons.
   Settings › **Shortcuts** tab lists global shortcuts (open, per-section, dictation) and every island command by group,
   with "Reset to defaults" (`Input/KeyBindings.swift`, `Settings/ShortcutsSettings.swift`).
4. **Global per-section shortcuts** were already supported; they now live in the Shortcuts tab.
5. **Screenshot view re-laid out** as a filmstrip: large preview on top with filename, dimensions/duration, "n of m",
   folder; horizontal thumbnail strip below, `←/→` (and `↑/↓`) move linearly, strip auto-centres the selection.
6. **Launch at login from the get-go**: `AppDelegate.configureLaunchAtLoginIfNeeded()` registers `SMAppService.mainApp`
   once, the first time the app runs from `/Applications` (a build-directory copy would leave a dangling login item).
   `make install` copies the app there. A General-settings toggle also exists.
7. **Dictation (new, beyond the original scope)**: `Features/Dictation/` uses the macOS 26 Speech framework
   (`SpeechAnalyzer` + `DictationTranscriber`, on-device, model downloaded on first use). Global hotkey (default `⌥⇧D`)
   opens a compact pill under the notch with live transcript and level meter; pressing the hotkey again or `↩` delivers
   the text (copy or paste per the Return-key setting), `esc` cancels; result is also added to clipboard history.
   Settings › **Dictation** tab: language picker, model download, microphone status. `Info.plist` gained microphone and
   speech-recognition usage strings. Automation commands `dictate`, `dictate-file?path=…`, `dictate-finish`, `dictate-cancel`.
8. Menu bar menu gained "Start Dictation" and "Pause Clipboard Capture".

## How to work on it

```bash
make run        # xcodegen → build → launch with MACBUD_AUTOMATION=1
make test       # unit tests (Swift Testing)
make install    # copy to /Applications and launch (enables launch at login on first run)
make log        # os_log stream (has been unreliable; prefer ~/Library/Logs/MacBud.log)
```

End-to-end driving (app must run with `MACBUD_AUTOMATION=1`):

```bash
source scripts/e2e.sh          # mb, snap, dump, typetext, keys helpers (uses build/mbctl)
mb open section=clipboard; typetext hel; keys down,return; dump
```

- `build/mbctl` posts a distributed notification — it does **not** activate the app, unlike `open macbud://…`, which made
  the island lose key status in tests. Keep using `mbctl` for automation; the URL scheme is for Shortcuts/Raycast.
- `scripts/e2e-run.sh` is a full scripted pass (welcome → clipboard → pin/delete → snippets → screenshots → dictation file).
  **It deletes the app's preferences and data** (`defaults delete com.rangrik.macbud`, removes Application Support) — run it
  only when that is acceptable. It expects test media in `$OUT/shots` (see `scripts/` history: generated PNG/JPG plus an
  ffmpeg test `.mov`) and an optional `speech.wav`. Its current pass/fail status is unknown after the context reset.
- Snapshots (`snap name [panel|base]`) render through `ImageRenderer`; the AppKit-backed search field renders empty and
  Liquid Glass is not captured — verify typed text through `dump` instead.

## Permissions the user must grant once (signing is stable, so grants persist across builds)

- **Paste from other apps** (macOS 15.4+ pasteboard alert): choose "Always Allow" the first time history is captured.
- **Desktop folder** access prompt on first screenshot scan (default folder is the system screenshot location, else `~/Desktop`).
- **Accessibility** only for `⌘↩` paste-into-app (prompted on first use; button in Settings › General).
- **Microphone** (and speech model download) for dictation.

## Known issues / rough edges

- Default `⌥Space` may collide with Raycast; the fallback `⌃⌥Space` is used automatically and the welcome/Settings say so.
- `Section` (app enum) shadows SwiftUI's `Section`; use `SwiftUI.Section` in forms.
- Project uses Swift default main-actor isolation; pure data types are marked `nonisolated` (needed for Codable across actors).
- `SnippetsSectionController.expand` now reads `NSPasteboard.general` directly for `{clipboard}` (may trigger the pasteboard alert once).
- Quick Look (`⌘Y`) from a non-activating panel has not been exercised end to end.
- Screenshot strip: `ScreenshotsSectionController.columns` was removed; page keys move by 5.
- Wording: the code and docs contain no "cyber"; the only "security" strings are macOS System Settings URLs and the
  "Privacy & Security" pane name in permission hints.

## Suggested next steps (in order)

1. `make install`, grant the permissions above, and do the manual pass over scenarios S1–S9 in the spec plus round-2 items 1–7;
   fix whatever the visual pass shows (notch tab size/icon, filmstrip proportions, halo edge).
2. Run `scripts/e2e-run.sh` on a throwaway data state (or point `OUT`/`SHOTS` at temp folders) and make every check pass.
3. Decide whether dictation stays in scope; if yes, test model download UX and `{cursor}`-style caret handling for inserted text.
4. Commit in smaller pieces going forward (this handoff commit bundles the whole round 2).
