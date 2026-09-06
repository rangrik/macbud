# Feature Controls and Live Scrolling Implementation Plan

> **For agentic workers:** Execute inline using the executing-plans workflow, verifying each task before installation.

**Goal:** Let users order the section tabs and individually disable every feature, and keep the actual live dictation notch at the newest text.

**Architecture:** Persist ordered section IDs and disabled feature IDs in AppSettings. All tabs, menu entries, shortcuts, feature actions, and background services use these preferences. Reproduce scrolling through the production NotchController and NotchRootView with a synthetic speech engine before changing the scrolling implementation.

**Tech Stack:** macOS 26, Swift 6, SwiftUI, AppKit, Swift Testing.

**Spec:** Current user request and the 6:56 PM screen recording in this task.

## Constraints

- All six features default to enabled: Clipboard, Snippets, Screenshots, Dictation, History, Keep Alive.
- Disabling features preserves stored data and shortcut preferences; disabling Clipboard stops capture, Screenshots stops indexing, Dictation cancels recording, Keep Alive releases sleep assertions, and History stops saving transcripts.
- History and Dictation can be enabled independently. Saved snippets do not disappear when disabled.
- All sections can be disabled; Settings must remain reachable.
- Tab order affects keyboard cycling and menu order, and persists across restarts.
- Verify long streaming paragraphs in the complete passive notch; do not deliver synthetic text into user apps.

## Tasks

- [x] Reproduce scrolling using the full production notch, a fake DictationEngineSession, wrapped paragraphs, and volume/timer updates. Inspect actual scroll geometry and the final visible text; fix the failed seam and rerun the same check. Files: DictationView.swift, NotchRootView.swift, DictationControllerTests.swift.
- [x] Add AppFeature and persisted configuration in AppSettings with normalized section order, enabledSections, isEnabled, setEnabled, and moveSection. Add FeaturesSettings with checkboxes and accessible up/down tab ordering. Verify persistence, duplicate/unknown ID recovery, and all-disabled state in FeatureSettingsTests.
- [x] Apply configuration throughout AppDelegate, PanelCoordinator, HotKeyBinder, MenuBarMenu, IslandContentView, ClipboardMonitor, ScreenshotLibrary, and history/snippet actions. Test selection fallback, cycling, disabled shortcuts/actions, and retained data. Stop background work for disabled features.
- [x] Run full tests and Release build: 76 tests passed. Inspect the installed Features page and reordered notch. Verify disabled/re-enabled behavior, persistence, and shortcuts in tests. Verify wrapped transcripts in the complete production notch and inspect the AppKit-rendered final frame. Preserve the user's changed tab order; no interactive test preference changes were applied. Update README/HANDOFF and leave the signed app running normally.
