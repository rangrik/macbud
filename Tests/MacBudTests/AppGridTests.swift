import Testing
import Foundation
@testable import MacBud

/// Grid navigation is the seam: a wrong row map means ↑/↓ silently skips or traps the selection.
@Suite struct AppGridTests {
    private func entry(_ name: String) -> AppEntry {
        AppEntry(bundleID: "com.test.\(name)", name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    private func grid(open: Int, recent: Int, columns: Int = 3) -> AppGrid {
        AppGrid(groups: [.init(title: "Open now", items: (0..<open).map { entry("open\($0)") }),
                         .init(title: "Recent", items: (0..<recent).map { entry("recent\($0)") })],
                columns: columns)
    }

    @Test func groupsNeverShareARow() {
        // 2 open + 4 recent over 3 columns: [0,1] | [2,3,4] | [5]. Recent must start its own row.
        #expect(grid(open: 2, recent: 4).rows == [[0, 1], [2, 3, 4], [5]])
    }

    @Test func emptyGroupsAreDropped() {
        let g = grid(open: 3, recent: 0)
        #expect(g.groups.count == 1)
        #expect(g.rows == [[0, 1, 2]])
    }

    @Test func downCrossesTheGroupDivider() {
        // From open item 1, ↓ lands on the recent item in the same column, not on open item 2.
        #expect(grid(open: 3, recent: 3).index(from: 1, rows: 1) == 4)
    }

    @Test func downClampsToAShorterRow() {
        // Column 2 has no tile in the last row of two items, so ↓ lands on the last one there.
        #expect(grid(open: 3, recent: 2).index(from: 2, rows: 1) == 4)
    }

    @Test func verticalMovesStayPutAtTheEdges() {
        let g = grid(open: 3, recent: 3)
        #expect(g.index(from: 1, rows: -1) == 1)
        #expect(g.index(from: 4, rows: 1) == 4)
    }

    @Test func horizontalWalksTheFlatOrderAndClamps() {
        let g = grid(open: 3, recent: 3)
        #expect(g.index(from: 2, columns: 1) == 3)
        #expect(g.index(from: 0, columns: -1) == 0)
        #expect(g.index(from: 5, columns: 1) == 5)
    }

    @Test func navigationOnAnEmptyGridIsSafe() {
        let g = AppGrid(groups: [], columns: 3)
        #expect(g.isEmpty)
        #expect(g.index(from: 4, rows: 1) == 0)
    }
}

@Suite @MainActor struct AppUsageStoreTests {
    /// A throwaway directory so the debounced save never touches the real Application Support copy.
    private func makeStore() -> AppUsageStore {
        AppUsageStore(dataStore: DataStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macbud-tests-\(UUID().uuidString)", isDirectory: true)))
    }

    private func entry(_ name: String) -> AppEntry {
        AppEntry(bundleID: name, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    @Test func recentUseBeatsRawCount() {
        let store = makeStore()
        store.seed("stale", uses: 20, lastUsed: .now.addingTimeInterval(-60 * 86_400))
        store.seed("fresh", uses: 2, lastUsed: .now)
        #expect(store.score(for: "fresh") > store.score(for: "stale"))
    }

    @Test func recentListSkipsOpenAppsAndOnesNeverVisited() {
        let store = makeStore()
        store.record("chrome")
        store.record("mail")
        let recent = store.mostRecent([entry("chrome"), entry("mail"), entry("neverOpened")],
                                      excluding: ["chrome"], limit: 10)
        #expect(recent.map(\.bundleID) == ["mail"])
    }

    @Test func recentListIsLastVisitedFirstAndIgnoresHowOften() {
        let store = makeStore()
        // "workhorse" is used all day but you were in "quick" a minute ago. Recency wins outright.
        store.seed("workhorse", uses: 200, lastUsed: .now.addingTimeInterval(-3_600))
        store.seed("quick", uses: 1, lastUsed: .now.addingTimeInterval(-60))
        let recent = store.mostRecent([entry("workhorse"), entry("quick")], excluding: [], limit: 10)
        #expect(recent.map(\.bundleID) == ["quick", "workhorse"])
        #expect(store.score(for: "workhorse") > store.score(for: "quick"), "search ranking still values frequency")
    }

    @Test func recentListHonoursTheLimitAndStampsLastUsed() {
        let store = makeStore()
        for id in ["a", "b", "c"] { store.record(id) }
        let recent = store.mostRecent([entry("a"), entry("b"), entry("c")], excluding: [], limit: 2)
        #expect(recent.count == 2)
        #expect(recent.allSatisfy { $0.lastUsed != nil })
    }
}

@Suite @MainActor struct AppsShortcutMigrationTests {
    @Test func upgradingUserGetsTheAppsShortcutOnceAndKeepsLaterEdits() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // An existing install: shortcuts saved back when there was no Apps tab.
        let before = AppSettings(defaults: defaults)
        before.sectionHotKeys = [.clipboard: AppSettings.defaultSectionHotKeys[.clipboard]!]

        let upgraded = AppSettings(defaults: defaults)
        #expect(upgraded.sectionHotKeys[.apps] == AppSettings.defaultSectionHotKeys[.apps])

        upgraded.sectionHotKeys.removeValue(forKey: .apps)
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.sectionHotKeys[.apps] == nil, "a shortcut you cleared stays cleared")
    }

    @Test func migrationNeverStealsAChordAnotherTabIsUsing() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let taken = AppSettings.defaultSectionHotKeys[.apps]!
        let before = AppSettings(defaults: defaults)
        before.sectionHotKeys = [.snippets: taken]
        let upgraded = AppSettings(defaults: defaults)
        #expect(upgraded.sectionHotKeys[.apps] == nil)
        #expect(upgraded.sectionHotKeys[.snippets] == taken)
    }
}
