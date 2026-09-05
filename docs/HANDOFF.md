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
