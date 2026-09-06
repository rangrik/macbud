# Sunrise Artwork and Dictation Startup Implementation Plan

> **For agentic workers:** Execute these steps inline; the user has authorized implementation and installation in this task.

**Goal:** Use the supplied sunrise logo throughout MacBud, remove the dictation button from the tab bar, and prevent starting dictation from crashing the app.

**Architecture:** Preserve the existing SwiftUI assets and dictation lifecycle. Package the supplied original logo for AppIcon and the same original for MacBudMark. Correct the audio callback's concurrency boundary and keep dictation visible on focus loss while preserving ordinary tab dismissal.

**Tech Stack:** macOS 26, Swift 6, SwiftUI, AVFAudio, SpeechAnalyzer, Xcode.

**Spec:** User's three requirements in this task and attached `codex-clipboard-38f91cd2-f054-491e-9123-1d89cfb08c43.png`.

## Constraints

- Preserve the user's supplied sunrise shape and colors.
- Keep the Keep Alive switch after its label and retain its sun icon.
- Dictation remains available through the configured keyboard shortcuts.
- Verification must not insert or send recorded speech to another app.
- Preserve all existing uncommitted work and back up the installed application.

## Task 1: Reproduce and fix dictation startup

Files: `Sources/MacBud/Features/Dictation/DictationEngine.swift`, `Sources/MacBud/Notch/NotchController.swift`, `Tests/MacBudTests/NotchFocusTests.swift`, `scripts/check-dictation-startup.py`.

- [x] Run the installed app's real `dictate` command and assert the process survives in recording with a visible dictation notch. Initial `/private/tmp/macbud-dictation-repro.py` result: `FAIL: MacBud exited 1s after starting dictation`.
- [x] Inspect the crash stack. It fails in `_dispatch_assert_queue_fail` inside the AVAudioNode tap closure in `DictationEngine.start(locale:)`.
- [x] Explicitly mark the tap closure `@Sendable` so it runs on AVFAudio's delivery queue; retain explicit `Task { @MainActor ... }` hops for UI callbacks.
- [x] Retain a live regression script that starts recording, verifies the app and dictation window remain visible, and cancels without delivery.
- [x] Run existing tests and the live regression against the installed fix.

## Task 2: Sunrise artwork and tab bar

Files: `Resources/Brand`, `scripts/make_icon.swift`, `Resources/Assets.xcassets`, `Sources/MacBud/Shared/FeatureBadge.swift`, `Sources/MacBud/App/MacBudApp.swift`, `Sources/MacBud/Notch/IslandContentView.swift`.

- [x] Save the supplied original in the repository unchanged. Retain its cream background; discard the cutout experiment because it added effects.
- [x] Point the asset sizing script at the new sunrise masters and regenerate all app and notch sizes.
- [x] Remove the `Button { coordinator.startDictation() }` and its dictation badge from `HeaderStatus`.
- [x] Inspect the exported assets and running notch to confirm the logo and simplified header.

## Task 3: Package and verify

Files: `README.md`, `Resources/Brand/README.md`, `docs/HANDOFF.md`.

- [x] Run `xcodebuild ... test`, and build the Release application without test injection.
- [x] Verify the bundle signature, preserve the old installed app, and install the updated build.
- [x] Run `python3 scripts/check-dictation-startup.py`, visually inspect the UIand cancel the test recording without interrupting subsequent user interaction.
- [x] Update artwork and validation documentation with the evidence actually observed.

- [x] Add focus-loss regression tests, observe the dictation test fail, then limit automatic dismissal to expanded tabs. Final verification: 55 tests in 13 suites, Release build, and live microphone startup check passed.
