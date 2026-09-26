# MacBud

![MacBud — Your Mac essentials. Right in the notch.](Resources/Brand/MacBud-Social-Preview.png)

A keyboard-first macOS utility in the MacBook notch: clipboard history, text snippets, screenshots, on-device dictation, a clock, and a Keep Alive switch.

- macOS 26 (Tahoe), Apple Silicon. Swift 6, SwiftUI + AppKit.
- [Handoff notes](docs/HANDOFF.md)
- [Design spec](docs/superpowers/specs/2026-09-05-macbud-notch-utility-design.md)

## Controls

- **The shelf:** rest the pointer on the notch, click it, or press **⌥Space**. The notch grows into a row of your six newest items: copied text, links, images and files, screenshots, and dictations, newest on the left. **← →** move the ring, **↩** copies (or pastes; Settings → General picks which) and **⌘↩** does the other, a click on a card does what ↩ does, **⎋** closes. A shelf opened by hovering leaves the keyboard with your app and closes when the pointer moves away; press ⌥Space to give it the keys. Hold ⌥Space and let go to peek. Turn hovering off with "Open the shelf on hover" in Settings → General.
- **Search everything:** press **↓**, click **Search everything**, or just start typing on the shelf. The island adds a search field, filters, the Recent cards and an Earlier list with a preview. Under All a search also finds open windows and apps; ↩ switches to one. **↑ ↓** move, **← →** move along Recent.
- **Filters:** All · Text · Links · Images · Screenshots · Dictations · Snippets · Apps. **⇥ / ⇧⇥** cycle them, **⌘1–⌘8** jump to one; they keep one order, so the numbers never move. A filter keeps your search. Apps shows open windows and recent apps; ↩ switches. Item keys stay: ⌘P pin, ⌘⌫ delete (screenshots go to the Trash), ⌘S save as snippet, ⌘Y Quick Look, ⌘R Finder, ⌘N new snippet, ⌘E edit snippet.
- **Global shortcuts:** ⌥⇧V opens Search everything, ⌥⇧4 Screenshots, ⌥⇧S Snippets, ⌥⇧A Apps; any filter can have one in Settings → Shortcuts. Shortcuts saved for the old tabs carry over.
- **Features:** Settings → Features turns Clipboard, Screenshots, History, Snippets, Apps, Dictation, Keep Alive and the Clock on or off. A feature that is off hides its filters and its items and stops its shortcuts and background work; saved data is kept.
- **Every display:** each screen gets its own notch — a real one on the MacBook, a drawn one on external displays. The shortcut opens on the display you are working on, chosen by the focused window and falling back to the pointer. Turn the drawn notch off with "Show a clickable notch tab on every display" in Settings.
- **Clock:** a 24-hour clock sits on the left of the notch tab and stays there when the notch opens. Turn it off in Settings → Features. With the clock on, the MacBud logo moves to the right of the notch.
- **Prediction:** opening puts the ring on what you most likely want: a screenshot or dictation from the last minute, else the newest text. If you most likely want another app, the shelf puts that window first with the ring, or opens the Apps filter when it cannot tell which. With Codex installed, a small model predicts from metadata only and a bigger one learns from misses. **Prediction Activity** (menu bar, Settings → Prediction, or **⌘L** in the island) is a live timeline of every model call, prediction, outcome and review, each with the full prompt and reply; filter, search, and export it as Markdown. Settings → Prediction keeps the switches and hit rates; turn Codex off there. Files live in `~/Library/Application Support/MacBud/predict/` ([spec](docs/superpowers/specs/2026-09-24-predictive-opening-section.md), [shelf spec](docs/superpowers/specs/2026-09-24-notch-shelf.md)).
- **Keep Alive:** turn on the switch beside “Keep Alive” at the right edge of the shelf or expanded island’s band (no sun badge) to keep the Mac and display awake until you turn it off. Closing the notch leaves it on; quitting MacBud releases it. macOS still controls explicit Sleep and lid closure. The logo on the closed notch is in color while Keep Alive is on and white while it is off.
- **Dictation:** press your configured dictation shortcut (default **⌥⇧D**) to start; press it again to stop and insert. The transcript follows its newest words automatically. **Escape** cancels. Return and Command-Return remain with the active app. You can also click **Insert**, **Copy**, or **Cancel** in the bottom action strip.
- **Hold to talk:** hold **⌃⌥D**, speak, and release to stop and insert. Both dictation shortcuts are editable in Settings → Shortcuts. If no editable input is focused, the transcript is copied. Dictation never sends Return.
- **After dictating:** text that lands in an input is *not* added to clipboard history — the notch offers a **Copy transcript** button instead, for 15 seconds by default (up to 60 in Settings → Dictation). Click it to put the transcript in clipboard history yourself. Text that could not be inserted is always copied.
- **Dictation history:** your dictations are on the shelf and under the **Dictations** filter (⌘6), to copy, insert, delete, or **Save as snippet**. Completed transcripts are stored locally, including older MacBud dictations still in clipboard history. Cancelled recordings are not added.
- **Retry:** transcribes the saved recording without recording again. Temporary audio stays on this Mac and is removed when delivered or discarded.
- Insertion requires macOS Accessibility access; otherwise the transcript is copied. Microphone access is requested when starting a live recording. Speech models download once per language.

## Build

```bash
brew install xcodegen   # once
make run               # generate, build, launch Debug with test automation
make test              # Swift Testing suite
make install           # build Release, update /Applications/MacBud.app, launch normally
make package           # build Release, create a versioned ZIP and SHA-256 in dist/
```

## Updating

Settings → About has a **Check for updates** button. When a newer release exists the same button
installs it: MacBud downloads the ZIP, checks it against the release's SHA-256, refuses anything not
signed by the same identity as the copy you are running, then swaps `/Applications/MacBud.app` and
relaunches. A MacBud running from somewhere other than Applications links to the release page instead.

## Releases

Download the ZIP from [GitHub Releases](https://github.com/rangrik/macbud/releases), extract it, and move MacBud.app into Applications. Releases require macOS 26 or later. Release builds contain both Apple Silicon and Intel executables; on-device dictation depends on the speech capabilities available on your Mac.

The current release uses the available Apple Development signing certificate and is **not notarized**. macOS may block a downloaded copy. Developer ID signing and Apple notarization are needed for a release that passes Gatekeeper on other Macs without an override. Local installation uses the same app identity and retains settings and saved data.

`make install` stages and verifies the Release app before replacing the installed copy. It launches without test automation and removes its temporary backup after a successful launch. `make clean` removes local Debug and Release build products; it does not touch the installed app, release ZIPs, or saved data.

The app, notch, welcome screen, and About screen use the supplied sunrise logo with a transparent background in [Resources/Brand](Resources/Brand). Its gold and terracotta colors remain visible on the black notch; the menu bar uses a separate adaptive monochrome template. Regenerate the asset catalog sizes with `swift scripts/make_icon.swift`. Kind badges are vector SwiftUI views.

With Microphone access and a speech model installed, `python3 scripts/check-dictation-startup.py` checks the real microphone callback and dictation window. It restarts `/Applications/MacBud.app`, records briefly, then cancels without delivering text. Run `make install` first when checking a new build.
