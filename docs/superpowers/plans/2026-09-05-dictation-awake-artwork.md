# Dictation, Keep Awake, and Artwork Implementation Plan

> **For agentic workers:** Implement task-by-task with independent engine/service work and an integration review. Use the available executing-plans workflow; this checkout has no superpowers subagent workflow package.

**Goal:** Finish native dictation, add one indefinite Keep Awake checkbox at the right of the notch, remove total counts, and refresh the app and section artwork.

**Architecture:** Keep the existing macOS 26 SpeechAnalyzer pipeline. Retain captured audio in a session-owned temporary file for retry, isolate asynchronous sessions, and route explicit insert/send actions through the existing paste service. Own sleep assertions in an observable service independent of the notch's visibility.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Speech, AVFoundation, IOKit, XcodeGen, Swift Testing.

**Spec:** The user-provided Paseo dictation runbook at `/private/tmp/claude-501/-Users-pranavkanade-dev-paseo/ad7f7e6b-491c-4eff-9c21-c0688f66bca4/scratchpad/dictation-runbook.md` and `docs/HANDOFF.md`.

## Global Constraints

- macOS 26.0+, Apple Silicon, default MainActor isolation.
- Adapt the runbook's interaction and failure semantics to native on-device speech; no daemon, WebSocket, ONNX runtime, or cloud account is needed for this app.
- Keep clipboard history, preferences, and installed signing identity intact.
- Never send Return unless the user selects Insert & Send and the paste target is still frontmost.
- Keep-awake prevents idle sleep; explicit Sleep, lid closure, shutdown, and critical battery behavior remain controlled by macOS. Do not persist an active assertion across launches.

### Task 1: Reliable dictation engine

**Files:** `Features/Dictation/DictationEngine.swift`, new session audio helper, dictation tests.

**Interface:** Preserve `start(locale:) async throws`, `stop() async throws -> String`, `transcribe(file:locale:) async throws -> String`, `cancel() async`; add retained-recording retry availability and `retry() async throws -> String`. Cancellation discards audio; failure stops capture while retaining audio.

- [x] Capture a replayable temporary audio file, stop input before finalization, retain on failure, delete on cancel/success.
- [x] Guard every asynchronous session by identity; report microphone configuration changes; bound finalization with a timeout.
- [x] Eliminate audio-tap Swift concurrency warnings and verify Release compilation.
- [x] Test audio retention/cleanup and stale-session behavior with deterministic seams where feasible.

### Task 2: Keep-awake checkbox

**Files:** new `Features/KeepAwake/KeepAwakeController.swift`, `Tests/MacBudTests/KeepAwakeTests.swift`, notch header.

**Interface:** `KeepAwakeController` exposes `isActive`, `errorMessage`, `setEnabled(_:)`, `start()`, `stop()`. Native assertion creation/release is injectable for lifecycle tests.

- [x] Acquire system and display idle-sleep assertions while checked; release on uncheck and app termination.
- [x] Use one checkbox on the right of the notch. Always run until stopped, with no duration options or separate panel.
- [x] Test on/off, repeated enable/stop, initial failure and partial acquisition rollback.

### Task 3: Integrate actions and artwork

**Files:** dictation controller/view, `PanelCoordinator.swift`, `ActionContext.swift`, `Paster.swift`, notch views, `AppDelegate.swift`, settings, `scripts/make_icon.swift`, asset catalog, new shared artwork view.

- [x] Add clickable Insert, Insert & Send, Copy, Cancel, Retry, and Discard actions; Enter and the dictation shortcut confirm/send, Command-Enter inserts.
- [x] Retry saved audio rather than starting a new recording; guard cancellation and rapid actions with per-attempt engines.
- [x] Make dictation and the Keep Awake checkbox discoverable in the notch header; show awake status on the collapsed notch and stop assertions on app termination.
- [x] Remove total counts from the header, search row, and screenshot preview.
- [x] Extend the existing native icon generator with a colorful MacBud mark and matching scalable section badges. Inspect exported art at small and large sizes.

### Task 4: Verification and handoff

- [x] Run the full Swift Testing suite, Debug build, and Release build.
- [x] Launch the built app, inspect notch controls and visuals, verify native assertions with `pmset -g assertions`, and stop the test session.
- [x] Exercise real file transcription with local synthesized speech and deterministic cancel/retry tests. Review paste destination guards; live microphone and paste/send remain permission-dependent and are documented in the handoff.
- [x] Update README and handoff with controls, verification results, and any permissions needed for live microphone use.
