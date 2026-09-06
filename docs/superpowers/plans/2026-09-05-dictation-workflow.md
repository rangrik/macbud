# Dictation Workflow Implementation Plan

> **For agentic workers:** Execute this plan task by task with regression tests and runtime checks.

**Goal:** Keep dictation anchored to the notch, preserve the target app's keyboard focus, support toggle and hold-to-talk insertion, and save completed transcripts in a searchable history with snippet creation.

**Architecture:** Keep the existing on-device engine and cancellation boundary. Give dictation a non-key panel, temporary Escape handling, and explicit stop/release events. Deliver only into the currently focused editable element, with clipboard fallback. Add a persisted history section using the existing list, search, footer, and snippet editor patterns.

**Tech Stack:** macOS 26, Swift 6, SwiftUI, AppKit, Carbon hotkeys, Accessibility, Swift Testing.

**Spec:** User request and attached 8.7-second recording in the current task.

## Global Constraints

- No Insert & Send or synthetic Return in dictation.
- Return and Command-Return remain with the external app while recording.
- Escape always cancels an active dictation; repeated trigger finishes and inserts.
- Hold-to-talk uses a separate editable global chord; release finishes, including release during preparation.
- Without a focused editable input or Accessibility access, copy the transcript.
- Keep the sunrise artwork and compact Keep Alive switch unchanged; no dictation trigger icon in the tabs.
- Preserve existing preferences, snippets, clipboard history, and saved-audio retry.

## Tasks

- [x] **1. Reproduce focus, geometry, and early-stop bugs.** Extend `NotchFocusTests` to assert `openDictation()` immediately uses `dictationWindowFrame` and cannot become key. Extend `DictationControllerTests` to finish during suspended preparation and assert one stop and one delivery after startup resumes. Add coordinator routing tests asserting `.primaryAction` and `.secondaryAction` return false during dictation. Run the focused Xcode test suites and record failures before implementation.
- [x] **2. Implement input and delivery.** In `HotKeyCenter`, register both Carbon pressed/released events, suppress repeats, and dispatch release once. Add editable `holdToTalkHotKey` (default Control-Option-D), persisted independently. In `DictationController`, remember a requested finish while preparing and remove `insertAndSend`. In `PanelCoordinator`, use the trigger again to insert and hold-release to finish; temporarily register Escape only while dictation is active. In `NotchPanel`/`NotchController`, disable key focus for dictation. In `Paster`/`ActionContext`, resolve the current focused editable element at delivery, retain clipboard fallback, avoid stale target activation, and deliver without Return. Cover missing focus, app switches, held modifiers, and quick release.
- [x] **3. Stabilize and simplify the panel.** In `NotchRootView`, constrain layout to the active phase's canvas so invisible expanded content cannot move the dictation silhouette. Set the final dictation window frame before opening. In `DictationView`, use a full-width waveform above a scrollable transcript and a bottom action strip with Copy, Insert, and Cancel. Display the configured global shortcut next to Insert and the hold-release hint for hold-to-talk. Use actual window/frame inspection and a screenshot to verify alignment and long transcripts.
- [x] **4. Add history and snippet reuse.** Add `DictationHistoryItem`, `DictationHistoryStore`, and `DictationHistorySectionController/View`. Persist `dictation-history.json` locally, newest first, cap at the existing history limit, skip empty/cancelled recordings, and retain failed-session retry behavior. Add a text-only History tab and menu entry. Support search, copy, insert, delete, and Save as snippet, opening the existing snippet draft with the exact transcript. Test persistence, search, pruning, and snippet contents.
- [x] **5. Verify and install.** 66 tests in 14 suites, Release build, strict signatures, and `git diff --check` passed. Installed while idle with the previous app preserved. Live microphone visibility/focus, Escape, first-click Cancel, native text insertion, and History-to-snippet checks passed. Carbon press/release and release during preparation are covered by automated tests; physical hold duration was not driven by UI automation. README and handoff record behavior and verification limits.
