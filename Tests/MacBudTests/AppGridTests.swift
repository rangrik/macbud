import Testing
import Foundation
@testable import MacBud

/// Grid navigation is the seam: a wrong row map means ↑/↓ silently skips or traps the selection.
@Suite struct AppGridTests {
    private func entry(_ name: String) -> AppEntry {
        AppEntry(bundleID: "com.test.\(name)", name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    private func grid(open: Int, recent: Int, columns: Int = 3, recentColumns: Int? = nil) -> AppGrid {
        AppGrid(groups: [.init(title: "Recent", items: (0..<open).map { entry("open\($0)") }, columns: columns),
                         .init(title: "All", items: (0..<recent).map { entry("recent\($0)") },
                               columns: recentColumns ?? columns)])
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

    @Test func groupsCanUseDifferentColumnCounts() {
        // Recent narrows to 2 for the preview pane while All stays at 4: [0,1] | [2,3] | [4,5,6,7]
        let g = grid(open: 4, recent: 4, columns: 2, recentColumns: 4)
        #expect(g.rows == [[0, 1], [2, 3], [4, 5, 6, 7]])
        #expect(g.groupIndex(of: 3) == 0)
        #expect(g.groupIndex(of: 4) == 1)
        #expect(g.offsets == [0, 4])
        // Down from the last Recent row crosses into All, keeping the column.
        #expect(g.index(from: 3, rows: 1) == 5)
    }

    @Test func groupIndexIsNilPastTheEnd() {
        #expect(grid(open: 2, recent: 2).groupIndex(of: 9) == nil)
        #expect(AppGrid(groups: []).groupIndex(of: 0) == nil)
    }

    @Test func navigationOnAnEmptyGridIsSafe() {
        let g = AppGrid(groups: [])
        #expect(g.isEmpty)
        #expect(g.index(from: 4, rows: 1) == 0)
    }
}

/// Ordering is the seam: macOS gives us the dates, we decide what they mean.
@Suite struct AppOrderingTests {
    private func entry(_ name: String, minutesAgo: Int? = nil, useCount: Int = 0) -> AppEntry {
        AppEntry(bundleID: name, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
                 lastUsed: minutesAgo.map { Date.now.addingTimeInterval(-Double($0) * 60) }, useCount: useCount)
    }

    @Test func openAppsSortByLastVisit() {
        // Window stacking says [stale, fresh]; the recorded visits say otherwise and win.
        let sorted = AppsSectionController.byLastVisit([entry("stale", minutesAgo: 90), entry("fresh", minutesAgo: 2)])
        #expect(sorted.map(\.bundleID) == ["fresh", "stale"])
    }

    @Test func appsWithNoRecordKeepWindowStackingOrderBehindTheRest() {
        let sorted = AppsSectionController.byLastVisit([entry("neverA"), entry("neverB"), entry("visited", minutesAgo: 30)])
        #expect(sorted.map(\.bundleID) == ["visited", "neverA", "neverB"])
    }

    @Test func recentSkipsOpenAppsAndOnesNeverUsed() {
        let installed = [entry("open", minutesAgo: 1), entry("mail", minutesAgo: 20), entry("neverOpened")]
        let recent = AppsSectionController.recentApps(installed, excluding: ["open"], limit: 10)
        #expect(recent.map(\.bundleID) == ["mail"])
    }

    @Test func recentIsPurelyRecencyAndIgnoresHowOften() {
        // You launch the workhorse constantly but were in the other one a minute ago.
        let installed = [entry("workhorse", minutesAgo: 60, useCount: 9_000), entry("quick", minutesAgo: 1, useCount: 2)]
        let recent = AppsSectionController.recentApps(installed, excluding: [], limit: 10)
        #expect(recent.map(\.bundleID) == ["quick", "workhorse"])
    }

    @Test func recentHonoursTheLimit() {
        let installed = (0..<20).map { entry("app\($0)", minutesAgo: $0 + 1) }
        #expect(AppsSectionController.recentApps(installed, excluding: [], limit: 10).count == 10)
    }

    @Test func searchBonusFavoursRunningAppsAndFlattensHugeUseCounts() {
        let chrome = AppsSectionController.rankingBonus(isRunning: false, useCount: 35_000)
        let modest = AppsSectionController.rankingBonus(isRunning: false, useCount: 120)
        let unused = AppsSectionController.rankingBonus(isRunning: false, useCount: 0)
        #expect(unused == 0)
        #expect(modest > unused)
        #expect(chrome > modest)
        #expect(chrome - modest < modest, "a 300x use count must not become a 300x score")
        #expect(AppsSectionController.rankingBonus(isRunning: true, useCount: 0) > chrome)
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
