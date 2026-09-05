# MacBud

A keyboard-first macOS utility that lives in the MacBook notch: clipboard history, text snippets, and a screenshot/video browser — Raycast-style, but the notch opens up instead of a floating palette.

- macOS 26 (Tahoe), Apple Silicon. Swift 6, SwiftUI + AppKit, Liquid Glass.
- Handoff notes (state, how to run, pending work): [docs/HANDOFF.md](docs/HANDOFF.md)
- Design spec: [docs/superpowers/specs/2026-09-05-macbud-notch-utility-design.md](docs/superpowers/specs/2026-09-05-macbud-notch-utility-design.md)

## Build

```bash
brew install xcodegen   # once
make run                # generates MacBud.xcodeproj, builds, launches
make test               # unit tests
```
