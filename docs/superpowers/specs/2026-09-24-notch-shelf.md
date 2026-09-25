# The notch as a shelf

**Date:** 2026-09-24 · **Status:** chosen by the owner (Option E plus the chip row from Option D, with an Apps chip);
built from this spec. Design reference: [option-e-notch-shelf.html](../../mockups/option-e-notch-shelf.html),
[option-d-paste-and-go.html](../../mockups/option-d-paste-and-go.html), research in
[2026-09-24-ux-friction-research.md](2026-09-24-ux-friction-research.md).

## Problem

Five tabs meant picking a mode before typing, tabs split around the notch, and about twenty chords. Usage is
lopsided: ~20 clipboard captures and ~7 dictations a day, 2 snippets, 0 pins. The new island shows what you just
made, in one row, and filters with chips instead of tabs.

## States

Everything is pure black and grows out of the notch; nothing is drawn under the notch.

1. **Closed.** Unchanged: tab wings with the clock and the logo.
2. **Shelf** (620 × 170). The clock and logo stay where they were; below them one row of the **6 newest items**
   across clipboard (text, links, images, files), screenshots and dictations, newest on the left. Each card has a
   kind badge, a two-line excerpt or a thumbnail, and a caption "Arc · 9 min". One card has a ring. Under the row a
   hint line with a clickable **Search everything** chip. Snippets are kept things, not recent ones, so they wait
   in the list.
3. **Expanded** (760 × 500, as today). Header band: clock, logo, Keep Alive badge and switch. Then the
   **Search everything…** field, the chip row, the **Recent** cards (the same 6, filtered by the chip; hidden when
   the chip empties them or while searching), an **Earlier** list (300 pt) with a preview pane, and the 36 pt
   footer with hints for the selected item's kind. The **Apps** chip swaps the cards, list and preview for the
   existing open-windows grid, apps row and window preview.

## Opening

- **Hover** the notch tab for 150 ms (setting "Open the shelf on hover", on by default). Only the drawn tab counts,
  not its transparent margin, and never while a toast shows or dictation runs. A hover-opened shelf never takes
  focus: the mouse works, the keyboard stays with your app. Leaving the shelf closes it after 400 ms.
- **Click** the tab, or tap the **toggle hotkey**: the shelf opens and takes keys the way the island does today.
  A click on the notch or the hotkey gives a hover-opened shelf the keys; on a focused shelf or the island the
  hotkey closes it. A focused shelf closes on ⎋, the hotkey, or a click elsewhere, not when the pointer leaves.
- **Hold to peek:** hold the hotkey for more than 350 ms and let go; the shelf closes on release unless you
  expanded it meanwhile.
- **Per-chip global hotkeys** and menu items open straight into expanded on that chip. They are not scored.

## Keys

| | Shelf | Expanded |
|---|---|---|
| ← → | move the ring | move along Recent (with an empty query; else the text caret) |
| ↑ ↓ | ↓ expands onto the first Earlier row | move through Recent and Earlier |
| ↩ / ⌘↩ | primary / other action (the `enterAction` setting picks copy or paste) | same |
| ⇥ ⇧⇥ ⌘1…⌘8 | expand, then as expanded | cycle chips (wrapping, skipping hidden ones) / jump to chip N |
| ⌘S ⌘N ⌘E ⌘⇧⌫ | expand keeping the card, then as expanded | open the snippet editor / ask to clear clipboard history |
| typing | expands and starts the search | search |
| ⎋ | close | cancel the snippet editor, else close |

A click on a card acts; in the list a click selects and a double-click acts. Per-kind actions stay: ⌘P pin,
⌘⌫ delete (trash for screenshots), ⌘⇧⌫ clear clipboard history, ⌘S save as snippet, ⌘R Finder, ⌘Y Quick Look,
⌘N new snippet, ⌘E edit snippet, ⌘D dictate, ⌘, Settings. Dictation insert and recording are unchanged.

## Chips

`All · Text · Links · Images · Screenshots · Dictations · Snippets · Apps`, one fixed order, so ⌘1…⌘8 never move.
A chip is hidden when its feature is off (Clipboard hides Text, Links and Images; History hides Dictations) and its
items leave All. ⌘N on a hidden chip does nothing. Search runs `SearchMatcher` over every item the chip allows,
best match first. With a query, All also ranks open windows and apps, scored as the Apps chip scores them.

Kinds map to chips through `IntentKind`: text → Text, link → Links, image → Images, screenshot → Screenshots,
dictation → Dictations, snippet → Snippets, app → Apps. Copied files count as text, as prediction already says.
MacBud's own clipboard copies of a dictation are left out when History holds the same text, so one dictation is
one card.

## Prediction

`IntentKind.section` becomes `Shelf.landing(for:recents:)`, the one place an intent meets the UI:

- `app` naming an app, or `newest` → that app's front window (for `newest`, the app you just left) as the first card, with
  the ring. Any other `app` → expanded on Apps.
- any other kind → the shelf, with the ring on the first card of that kind (`older`: the second one). No card of
  that kind on the shelf → the ring stays on the newest card.
- no intent (prediction off) → the shelf, ring on the newest card.

Outcomes are recorded as before: the first item used, by key or mouse, from the shelf or the list. `opened` and
`actedIn` in `predictions.jsonl` become strings ("shelf" or a chip name); old records still load.

## Settings migration

- `sectionHotKeys` keeps its key; saved section names decode to chips: clipboard → All, screenshots → Screenshots,
  snippets → Snippets, dictationHistory → Dictations, apps → Apps. The owner's ⌥⇧V, ⌥⇧4, ⌥⇧S and ⌘H keep working.
- Saved island chords: `nextSection`/`previousSection` → next/previous chip; `selectSectionN` → chip N (the number
  keeps its position); the older per-section commands go to their section's chip. Commands missing from a saved
  set get their default chords unless another command already uses that chord.
- `sectionOrder`, `lastSection` and `rememberLastSection` are no longer read. The chip order is fixed.

## Removed

The five tabs, `Section`, `SectionTabLayout` and its tests, tab reordering in Settings → Features, "Reopen the last
used section", and the per-section list views and keyboard navigation (Clipboard list, Screenshots filmstrip,
History list, Snippets list). Their actions stay in the feature controllers; the previews and the snippet editor
are reused in the preview pane.

## Tests (seams only)

Merged recents across stores; chip scoping of results; intent → chip and card; key routing in shelf versus
expanded; the hover dwell rule; the settings migration.
