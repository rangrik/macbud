# MacBud — a keyboard-first utility that lives in the MacBook notch

**Date:** 2026-09-05 · **Target:** macOS 26 (Tahoe) on Apple Silicon (M4 MacBook Pro 16", notch 220×38 pt) · **Status:** approved by the goal directive; built autonomously from this spec.

## 1. Purpose

Replicate three Raycast features for personal use, but make them live in the display notch instead of a floating palette:

1. **Clipboard history** — everything copied (text, links, images, files) is captured and searchable; pick one to put it back on the clipboard.
2. **Snippets** — saved text macros with a keyword and optional placeholders; pick one to copy/paste it.
3. **Screenshot browser** — browse images and videos from configurable folders; pick one to copy it to the clipboard so it can be pasted anywhere.

Non-goals: extensions, launcher/app search, calculator, cloud sync, iOS.

## 2. How the user actually uses it (scenarios)

| # | Scenario | Flow | Success criterion |
|---|----------|------|-------------------|
| S1 | Paste something copied 10 minutes ago into Slack | `⌥Space` → notch expands, Clipboard section, search focused → type 2–3 chars → `↓` → `↩` → notch collapses, "Copied" pill flashes → `⌘V` in Slack | < 2 s, never leaves the keyboard, Slack keeps focus the whole time |
| S2 | Paste a canned reply while writing an email | `⌥Space` → `⌘2` (Snippets) → type keyword → `⌘↩` → snippet is pasted *directly* into the email (Accessibility granted) | placeholders like `{date}` are expanded at paste time |
| S3 | Share the screenshot just taken | `⌘⇧4` (macOS saves to Desktop) → `⌥Space` → `⌘3` → newest screenshot is already selected → `↩` → `⌘V` in Slack attaches the image | image (not a path) lands in Slack; works for `.mov` screen recordings too (file is attached) |
| S4 | Peek at history without acting | open → browse with `↑↓`, read the full text/image in the preview pane → `esc` | nothing is written to the clipboard |
| S5 | Hygiene | `⌘⌫` deletes an item; `⌘⇧⌫` twice clears history; passwords copied from 1Password never appear (concealed/transient pasteboard types are honoured); `⌘P` pins an item so it survives trimming | |
| S6 | Save something useful as a snippet | in Clipboard, `⌘S` on an item → snippet editor opens pre-filled → name it → `⌘S` | one round trip, no Settings window |
| S7 | First launch | app opens the notch with a short welcome: press the hotkey, allow pasteboard access when macOS asks (15.4+ privacy alert), optionally grant Accessibility for direct paste, Desktop is pre-configured as the screenshot folder | user is productive within 30 s |
| S8 | Mouse fallback | click the notch → opens; click a row → selects, double-click → acts; click outside → closes | keyboard-first, but the mouse is never a dead end |
| S9 | Lid closed / external display only | panel appears top-centre of the main display with a simulated notch | never lands on an invisible screen |

## 3. UX/UI ideation — options considered

### 3.1 Where the content lives
- **A. Drop-down island (chosen).** The black notch grows into a 760×500 pt island anchored to the screen top. Top corners keep the notch's concave fillets, bottom corners are 28 pt radius. Menu bar items under the island are covered only while it is open. Reads as "the notch opened up", exactly the request.
- **B. Wide command strip.** A 120 pt-tall strip across the top with a horizontal carousel. Very Dynamic-Island, but hopeless for long text, snippet editing and a grid of screenshots. Rejected.
- **C. Hybrid compact/expanded.** Compact palette that can be expanded. Two layouts to learn and maintain for no real gain. Rejected.

### 3.2 Screenshot navigation
- **Filmstrip** (large preview, thumbnails in a row): great for recency but only ~8 items visible and inconsistent with the other sections.
- **Thumbnail grid + preview (chosen):** 2-column grid on the left (16 visible), large preview + metadata on the right. `↑↓←→` move through the grid; same list-left/preview-right skeleton as the other two sections, so muscle memory transfers.

### 3.3 Enter semantics
- Raycast pastes on `↩` and copies on `⌘↩`. The request says "it should be copied to the clipboard so I can paste it wherever". Chosen: **`↩` = copy & close**, **`⌘↩` = paste into the previous app** (needs Accessibility; if missing, the footer explains and offers to open System Settings). A setting can swap them.

### 3.4 Visual language
- Pure black (#000) island so it fuses with the physical notch; content in white at 3 opacity levels (0.95 / 0.6 / 0.4).
- Liquid Glass (`glassEffect`) for the section tabs and the selected row, giving depth without colour noise; accent = macOS accent colour for the selection ring and matched search characters.
- SF Pro 13 pt rows, 15 pt search field, SF Mono for code-like clipboard text; SF Symbols for item kinds.
- Motion: spring (0.38 s, bounce 0.18) island growth; content fades in after the shape reaches ~80 %; collapse is faster (0.25 s). After an action, the island briefly grows to a 280×72 pt pill under the notch that says "Copied" / "Pasted into Slack" for 1.2 s.
- The 38 pt menu-bar band beside the notch is used: section tabs sit left of the notch, item count and a status dot sit right of it. Nothing is ever drawn under the physical notch.

## 4. Layout (island local coordinates, 760 wide, 500 tall)

```
y 0–38    [ Clipboard | Snippets | Screenshots ]   ▓▓ notch ▓▓   128 items ●
y 46–82   🔍  Search clipboard…
y 90–458  ┌──────────────┬───────────────────────────┐
          │ list / grid  │ preview + metadata        │
          │ 300 wide     │ 440 wide                  │
y 462–500 └──────────────┴───────────────────────────┘
          ↩ Copy   ⌘↩ Paste to Slack   ⌘⌫ Delete   ⇥ Section   esc Close
```

## 5. Keyboard model

Global (Carbon `RegisterEventHotKey` — still the only public API that both fires system-wide and consumes the chord; no Accessibility needed):
- `⌥Space` toggle island (opens on last-used section). If another app owns the chord the app falls back to `⌃⌥Space` and says so. Optional per-section hotkeys, configurable in Settings with a recorder control.

Island:
- Type → filters (search field always has focus). `↑↓` (also `⌃N/⌃P`) move selection; `←→` move in the screenshot grid. `⇥/⇧⇥` and `⌘1/2/3` switch sections. `esc` closes.
- `↩` copy & close · `⌘↩` paste into previous app · `⌘⌫` delete (screenshots: move to Trash) · `⌘⇧⌫` ×2 clear history · `⌘P` pin · `⌘S` save clipboard item as snippet · `⌘N` new snippet · `⌘E` edit snippet · `⌘R` reveal in Finder · `⌘Y` Quick Look · `⌘,` Settings.
- Snippet editor (replaces the preview pane): `⇥` between Name / Keyword / Content, `⌘S` save, `esc` cancel.

## 6. Architecture

Single Xcode app target generated by **xcodegen** (`project.yml`), Swift 6 language mode, strict concurrency, deployment target macOS 26.0, no sandbox (personal tool needs arbitrary folder access), signed with the local Apple Development identity so TCC grants persist across builds. `LSUIElement = true`; presence in the menu bar via SwiftUI `MenuBarExtra`.

```
Sources/MacBud
├─ App/            MacBudApp (SwiftUI App, MenuBarExtra, Settings scene), AppDelegate, URL scheme handler
├─ Notch/          NotchGeometry, NotchShape, NotchPanel (NSPanel), NotchController (open/close/toast), NotchRootView
├─ Input/          KeyRouter (NSEvent → PanelCommand), HotKeyCenter (Carbon), HotKey model + recorder view
├─ Features/
│  ├─ Clipboard/   ClipboardMonitor (changeCount polling), ClipboardStore (@Observable), ClipboardItem, views
│  ├─ Snippets/    SnippetStore, Snippet, SnippetExpander (placeholders), views + editor
│  └─ Screenshots/ ScreenshotLibrary (scan + FolderWatcher), MediaItem, ThumbnailCache (QLThumbnailGenerator), views
├─ Services/       Paster (pasteboard writes + CGEvent ⌘V), FrontmostTracker, Persistence (atomic JSON), SearchMatcher
├─ Settings/       SettingsView (General, Snippets, Screenshots, Privacy & About), AppSettings (@Observable over UserDefaults)
└─ Shared/         Theme, Formatters, small UI atoms
Tests/MacBudTests  Swift Testing: SearchMatcher, SnippetExpander, ClipboardStore, ScreenshotLibrary scan, NotchShape, HotKey codec
```

Data flow: system pasteboard → `ClipboardMonitor` (0.4 s timer on main) → `ClipboardStore` (dedupe, cap, pin) → `Persistence` actor writes `~/Library/Application Support/MacBud/clipboard/index.json` + `images/<uuid>.png`, debounced 300 ms. Views observe stores via Observation. Search runs in memory through `SearchMatcher` (prefix > word-start > subsequence, returns ranges for highlighting). Screenshot folders are scanned off-main with `FileManager` + `UTType` conformance and re-scanned when a `DispatchSource` folder watcher fires. Thumbnails come from `QLThumbnailGenerator` and live in an `NSCache`.

The island is a borderless, non-activating `NSPanel` at `.statusBar` level joining all Spaces (also over full-screen apps). Its `sendEvent` hands key events to `KeyRouter` first, so navigation never fights the text field. When collapsed the window shrinks to the notch rect so the rest of the screen stays clickable; when expanded it is resized to the island frame before the spring animation starts. Click-outside and key-window loss collapse it.

Automation hooks (only when launched with `MACBUD_AUTOMATION=1`): `macbud://open?section=…`, `macbud://close`, `macbud://key?seq=down,down,return`, `macbud://type?text=…`, `macbud://snapshot?path=…` (renders the island's own view hierarchy to PNG — needs no Screen Recording permission). These make end-to-end verification scriptable and double as a Shortcuts/Raycast integration surface.

## 7. Error handling & privacy
- macOS 15.4+ pasteboard privacy: the first programmatic read triggers the system alert; the UI shows `NSPasteboard.accessBehavior` and, when denied, a one-click path to System Settings.
- Pasteboard items flagged `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` are ignored; a bundle-id ignore list (defaults: 1Password, Keychain Access) is editable.
- Writes are atomic; a corrupt index is renamed `.broken` and the app starts empty rather than crashing.
- Direct paste is attempted only when `AXIsProcessTrusted()`; otherwise the footer explains what to grant.
- Missing screenshot folders are shown greyed in Settings and skipped during scans.

## 8. Testing
- Unit tests (Swift Testing) for every pure component listed above.
- Scripted end-to-end runs: `pbcopy` feeds the clipboard, the URL scheme drives the island, `pbpaste`/a pasteboard-type dump verifies results, snapshots are inspected visually.
- Manual scenario pass over S1–S9 before declaring done.
