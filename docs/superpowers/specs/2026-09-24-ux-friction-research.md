# MacBud UX friction: research and options (2026-09-24)

Problem as reported: the island was meant to be fast, but the owner keeps forgetting the keys,
reaches for the trackpad, and feels friction switching tabs (Clipboard, Apps, Screenshots, ...).

## What the code and the data say

1. **Mode first, search second.** You must pick a section before you can type. Five sections,
   three different layouts (list + preview, filmstrip, grid + preview), each with its own key set.
2. **The island opens on the last-used tab.** `rememberLastSection` is on; today `lastSection`
   is Screenshots. So the same key lands somewhere different each time, and you have to look
   before you type. That is a classic mode error.
3. **About twenty chords, no cheat sheet.** Toggle, four direct-section chords, ⌘1 to ⌘5 that
   move when tabs are reordered, ⇥, ↩ vs ⌘↩, ⌘S/P/N/E/R/Y/⌫, two dictation chords. Footer hints
   show only the current section; the ⌘-number lives in a tooltip.
4. **The notch splits the tab bar.** With the owner's order plus the auto-appended Apps tab,
   `SectionTabLayout` puts four tabs left of the notch and Apps alone on the right, beside the
   clock and the Keep Alive switch. Tabs do not read as one group.
5. **Usage is lopsided.** Clipboard 500 items (about 20 a day), dictation 169 (about 7 a day),
   snippets 2, pinned 0, images 12. 146 of 500 clipboard entries came from MacBud itself, so
   dictation output is the heaviest single source. Snippets and Pin hold a tab and chords
   that are never used.
6. **The neighbours moved to one search box.** Tahoe Spotlight: ⌘Space, then ⌘1 to ⌘4 for
   Apps, Files, Actions, Clipboard; `/` prefixes; auto-learned Quick Keys. Raycast: one root
   search; clipboard history filters by type with ⌘P and actions with ⌘K. Neither asks you to
   choose a mode before typing.

## Options

| # | Option | What changes | Effort |
|---|--------|--------------|--------|
| A | One search box, no modes | Open, type, results grouped by kind with the best group first. Tabs become filters: ⇥ cycles, `/a`, `/s`, `/c` prefixes narrow. Empty query shows recents across everything. | Medium |
| B | Leader key instead of chords | ⌥Space, then a plain mnemonic letter: V clipboard, S screenshots, A apps, D dictations. A small strip under the notch shows the letters while waiting. Letters never move. | Small |
| C | Predict the section | Default to Clipboard. Screenshot saved in the last minute opens Screenshots. Turn "remember last section" off by default. | Tiny |
| D | Two tabs: Paste and Go | Clipboard, screenshots, dictations, snippets merge into Paste with type chips. Apps and windows become Go. Matches the usage data. | Medium |
| E | The notch as a shelf | Hover or hold the hotkey: a one-row strip of the last copies and screenshots as cards. ←→ pick, ↩ paste, ↓ expands into the full island. The notch becomes the UI, not a drop-down palette. Best trackpad path: one hover, one click. | Medium to high |
| F | Discoverability layer | `?` opens a cheat sheet. Number badges on tabs, always visible. Tabs on one side of the notch; clock and Keep Alive move to the footer. | Small |

## Recommendation

Do C, B and F first: no redesign, roughly a day, and they remove the "which tab am I on" and
"which key was it" costs. Then A, folding D into it, as the real fix. Prototype E afterwards;
it is the most original and the strongest answer to the trackpad habit, and it leans into what
Spotlight cannot copy: the notch, screenshots and dictation.

## References

- Tahoe Spotlight: https://www.macrumors.com/how-to/do-more-with-spotlight-in-macos-tahoe/ and https://9to5mac.com/2025/06/10/macos-26-spotlight-gets-actions-clipboard-manager-custom-shortcuts/
- Raycast clipboard history: https://manual.raycast.com/clipboard-history
- Paste shelf and pinboards: https://pasteapp.io/help/paste-on-mac
- Leader Key: https://github.com/mikker/LeaderKey
- Boring Notch hover model: https://boringnotch.com/
- Mobbin command palettes: Vapi https://mobbin.com/screens/593d7acd-2e16-4365-bcd6-02ce52f48f3b,
  Magnific https://mobbin.com/screens/14ceb943-f04a-460f-b4f5-2ebd78d74aff,
  Linear scope chips https://mobbin.com/screens/d0b98680-66e2-47d4-9dc4-28bc9450c27f,
  Higgsfield chips + recents https://mobbin.com/screens/c45648d0-80cd-4bac-a220-7cc068c78b8f,
  Notion cheat sheet https://mobbin.com/screens/49ebf525-3275-423a-9dda-725fdb0c1d68

## Decision (2026-09-24)

The owner chose Option E, the notch as a shelf, plus the kind filters from Option D with an Apps
filter added: All · Text · Links · Images · Screenshots · Dictations · Snippets · Apps. The five
section tabs go away. Prototypes: `docs/mockups/option-e-notch-shelf.html` (shelf and expanded) and
`docs/mockups/option-d-paste-and-go.html` (chip row). Option C, the predicted landing section, is
being built in the `predictive-section` worktree and will predict a "landing intent" (kind plus
item hint) so it maps onto either UI.
