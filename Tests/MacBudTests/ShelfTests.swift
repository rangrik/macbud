import AppKit
import Testing
@testable import MacBud

@Suite @MainActor struct ShelfTests {
    /// Seam: four stores → the shelf. Catches a store left out, a wrong order, snippets on the shelf,
    /// a dictation shown twice (History plus MacBud's own clipboard copy), and hidden kinds leaking in.
    @Test func recentsMergeEveryStoreNewestFirst() {
        let items = Shelf.merge(clips: [clip("hello", 30), clip("https://example.com/a", 50, kind: .link),
                                        clip("Ship it", 9, source: Bundle.main.bundleIdentifier)] + (1...4).map { clip("old \($0)", 900 + Double($0)) },
                                media: [shot("Screenshot.png", 20)], dictations: [DictationHistoryItem(text: "Ship it", createdAt: .now - 10)],
                                snippets: [Snippet(name: "Sign-off", keyword: "sig", content: "Thanks", updatedAt: .now)], kinds: IntentKind.allCases)
        #expect(Shelf.recents(items).map(\.title) == ["Ship it", "Screenshot.png", "hello", "https://example.com/a", "old 1", "old 2"])
        #expect(Shelf.recents(items).first?.kind == .dictation)
        #expect(items.first?.kind == .snippet, "the snippet is newest, and waits in the list")
        let noShots = Shelf.merge(clips: [], media: [shot("Screenshot.png", 20)], dictations: [], snippets: [],
                                  kinds: IntentKind.allCases.filter { $0 != .screenshot })
        #expect(noShots.isEmpty)
    }

    /// Seam: chip and query → Recent row and list. Catches a chip showing other kinds, a search escaping
    /// its chip, a Recent row left up under a chip that empties it or while searching, and windows missing
    /// from All's search, leaking into recents or another chip, or tacked on instead of ranked.
    @Test func chipsScopeTheListAndTheSearch() {
        let items = Shelf.merge(clips: [clip("alpha note", 1), clip("https://alpha.example", 2, kind: .link)] + (3...9).map { clip("older \($0)", Double($0) * 60) },
                                media: [shot("alpha.png", 5)], dictations: [], snippets: [], kinds: IntentKind.allCases)
        let all = Shelf.layout(items, chip: .all, query: "")
        #expect(all.cards.map(\.title) == ["alpha note", "https://alpha.example", "alpha.png", "older 3", "older 4", "older 5"])
        #expect(all.rows.map(\.title) == ["older 6", "older 7", "older 8", "older 9"])
        let text = Shelf.layout(items, chip: .text, query: "")
        #expect(text.cards.map(\.title) == ["alpha note", "older 3", "older 4", "older 5"])
        #expect(text.rows.allSatisfy { $0.kind == .text })
        let snippets = Shelf.layout(items, chip: .snippets, query: "")
        #expect(snippets.cards.isEmpty && snippets.rows.isEmpty)
        let found = Shelf.layout(items, chip: .all, query: "alpha")
        #expect(found.cards.isEmpty)
        #expect(Set(found.rows.map(\.kind)) == [.text, .link, .screenshot])
        #expect(Shelf.layout(items, chip: .links, query: "alpha").rows.map(\.kind) == [.link])
        let window = AppEntry(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app"),
                              isRunning: true, windowID: "slack#1", label: "alpha standup")
        #expect(Shelf.layout(items, apps: [window], chip: .all, query: "alpha").rows.map(\.kind) == [.app, .screenshot, .text, .link])
        #expect(Shelf.layout(items, apps: [window], chip: .all, query: "").rows == all.rows)
        #expect(Shelf.layout(items, apps: [window], chip: .text, query: "alpha").rows.allSatisfy { $0.kind == .text })
    }

    /// Seam: predicted intent → where the UI lands. Catches an app intent with no app named stuck on the shelf,
    /// a named app or `newest` window not put first with the ring, an ignored `older` hint, and a lost ring.
    @Test func intentsLandOnTheirChipAndCard() {
        let recents = Shelf.recents(Shelf.merge(clips: [clip("a", 1), clip("b", 3)], media: [shot("s.png", 2)], dictations: [],
                                                snippets: [], kinds: IntentKind.allCases))
        #expect(Shelf.landing(for: nil, recents: recents) == Landing(card: recents[0].id))
        #expect(Shelf.landing(for: LandingIntent(kind: .screenshot, hint: .newest), recents: recents) == Landing(card: recents[1].id))
        #expect(Shelf.landing(for: LandingIntent(kind: .text, hint: .older), recents: recents) == Landing(card: recents[2].id))
        #expect(Shelf.landing(for: LandingIntent(kind: .dictation), recents: recents) == Landing(card: recents[0].id))
        #expect(Shelf.landing(for: LandingIntent(kind: .app, hint: .newest), recents: recents) == Landing(chip: .apps, expanded: true))
        let left = AppEntry(bundleID: "com.google.Chrome", name: "Chrome", url: URL(fileURLWithPath: "/Applications/Chrome.app"), windowID: "chrome#1")
        let slack = AppEntry(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app"))
        #expect(AppsSectionController.pick(LandingIntent(kind: .app, hint: .newest), pool: [left, slack], switchTarget: left) == left)
        #expect(AppsSectionController.pick(LandingIntent(kind: .app, hint: .newest, app: slack.bundleID), pool: [left, slack], switchTarget: left) == slack)
        #expect(AppsSectionController.pick(LandingIntent(kind: .app), pool: [left, slack], switchTarget: left) == nil)
        let led = Shelf.recents(recents, lead: left)
        #expect(led.first == .app(left) && Shelf.landing(for: LandingIntent(kind: .app), recents: led) == Landing(card: led[0].id))
    }

    /// Seam: pointer over the tab → shelf. Catches opening on a pass to the menu bar, over a toast's button,
    /// during dictation, or with the setting off.
    @Test func hoverOpensOnlyAfterRestingOnAQuietClosedNotch() {
        let rest = HoverDwell.delay
        #expect(HoverDwell.opens(enabled: true, phase: .collapsed, toasting: false, hoveredFor: rest))
        #expect(!HoverDwell.opens(enabled: true, phase: .collapsed, toasting: false, hoveredFor: .milliseconds(60)))
        #expect(!HoverDwell.opens(enabled: false, phase: .collapsed, toasting: false, hoveredFor: rest))
        #expect(!HoverDwell.opens(enabled: true, phase: .collapsed, toasting: true, hoveredFor: rest))
        #expect(!HoverDwell.opens(enabled: true, phase: .dictation, toasting: false, hoveredFor: rest))
    }

    /// Seam: keys → shelf or island, and the use → the prediction log. Catches ↓ not expanding, arrows
    /// doing the wrong thing in either state, ⇥ not wrapping or landing on a hidden chip, and outcomes
    /// lost from either state.
    @Test func keysRouteDifferentlyOnTheShelfAndInTheIsland() {
        let coordinator = makeCoordinator()
        defer { coordinator.notch.close() }
        for age in 1...8 { coordinator.clipboardStore.add(clip("item \(age)", Double(age))) }
        coordinator.openShelf()
        let cards = coordinator.shelf.recents
        #expect(coordinator.state.isShelf && coordinator.shelf.selected == cards[0])
        coordinator.handle(.moveRight)
        #expect(coordinator.shelf.selected == cards[1])
        coordinator.handle(.moveUp)
        #expect(coordinator.state.isShelf)
        coordinator.handle(.togglePin)
        coordinator.notch.close()
        coordinator.predictor.sessionEnded()
        #expect(coordinator.predictor.sessions.last?.actedIn == "shelf")
        #expect(coordinator.predictor.sessions.last?.outcome?.kind == .text)

        coordinator.openShelf()
        coordinator.handle(.moveDown)
        let rows = coordinator.shelf.layout.rows
        #expect(coordinator.state.isExpanded && coordinator.shelf.selected == rows[0])
        coordinator.handle(.moveDown)
        #expect(coordinator.shelf.selected == rows[1])
        coordinator.handle(.togglePin)
        coordinator.settings.setEnabled(false, for: .screenshots)
        coordinator.settings.setEnabled(false, for: .apps)
        coordinator.handle(.previousChip)
        #expect(coordinator.state.chip == .snippets, "⇧⇥ wraps from All to the end")
        coordinator.handle(.nextChip)
        for _ in 0..<4 { coordinator.handle(.nextChip) }
        #expect(coordinator.state.chip == .dictations, "Screenshots is hidden, so ⇥ skips it")
        coordinator.handle(.selectChip(.screenshots))
        #expect(coordinator.state.chip == .dictations)
        coordinator.notch.close()
        coordinator.predictor.sessionEnded()
        #expect(coordinator.predictor.sessions.last?.actedIn == "all")
    }

    private func makeCoordinator() -> PanelCoordinator {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.hasSeenWelcome = true
        settings.prediction.useModel = false
        let notch = NotchController()
        let data = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return PanelCoordinator(state: notch.state, notch: notch, settings: settings, clipboardStore: ClipboardStore(dataStore: data),
                                snippetStore: SnippetStore(dataStore: data), library: ScreenshotLibrary())
    }

    private func clip(_ text: String, _ age: TimeInterval, kind: ClipboardItem.Kind = .text,
                      source: String? = "com.apple.Safari") -> ClipboardItem {
        ClipboardItem(id: UUID(), kind: kind, copiedAt: .now - age, text: text, byteCount: text.utf8.count,
                      sourceBundleID: source, contentHash: text)
    }

    private func shot(_ name: String, _ age: TimeInterval) -> MediaItem {
        MediaItem(url: URL(fileURLWithPath: "/tmp/\(name)"), kind: .image, createdAt: .now - age, byteCount: 1,
                  folder: URL(fileURLWithPath: "/tmp"))
    }
}
