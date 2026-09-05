import Foundation
import SwiftUI
import Testing
@testable import MacBud

@Suite struct NotchShapeTests {
    @Test func collapsedShapeFillsExactlyItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 220, height: 38)
        let bounds = NotchShape(topFillet: 0, bottomRadius: 12).path(in: rect).boundingRect
        #expect(abs(bounds.width - 220) < 0.01)
        #expect(abs(bounds.height - 38) < 0.01)
    }

    @Test func expandedShapeStaysInsideRectAndTouchesTop() {
        let rect = CGRect(x: 0, y: 0, width: 780, height: 500)
        let path = NotchShape(topFillet: 10, bottomRadius: 28).path(in: rect)
        let b = path.boundingRect
        #expect(b.minY == 0 && b.minX >= -0.01 && b.maxX <= 780.01 && b.maxY <= 500.01)
        // Fillets: the body is inset, so a point just inside the top corner is outside the shape.
        #expect(!path.contains(CGPoint(x: 6, y: 6)))
        #expect(path.contains(CGPoint(x: 390, y: 250)))
    }
}

@Suite struct ClipboardItemTests {
    @Test func linkDetection() {
        #expect(ClipboardItem.looksLikeLink("https://apple.com/mac"))
        #expect(!ClipboardItem.looksLikeLink("visit https://apple.com now"))
        #expect(!ClipboardItem.looksLikeLink("ftp://x.y"))
        #expect(!ClipboardItem.looksLikeLink("hello"))
    }

    @Test func titleIsFirstNonEmptyLine() {
        let item = ClipboardItem(id: UUID(), kind: .text, copiedAt: .now, text: "\n\n  second line  \nthird", byteCount: 1, contentHash: "h")
        #expect(item.title == "second line")
        #expect(item.lineCount == 4)
    }

    @Test func hashIsStable() {
        #expect(ClipboardItem.hash(ofText: "abc") == ClipboardItem.hash(ofText: "abc"))
        #expect(ClipboardItem.hash(ofText: "abc") != ClipboardItem.hash(ofText: "abd"))
    }
}

@Suite @MainActor struct ClipboardStoreTests {
    private func makeStore() -> ClipboardStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-tests-\(UUID().uuidString)")
        return ClipboardStore(dataStore: DataStore(directory: dir))
    }

    private func text(_ s: String, at date: Date = .now, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(id: UUID(), kind: .text, copiedAt: date, text: s, byteCount: s.utf8.count, isPinned: pinned, contentHash: ClipboardItem.hash(ofText: s))
    }

    @Test func duplicateContentBumpsInsteadOfDuplicating() {
        let store = makeStore()
        store.add(text("one", at: Date(timeIntervalSince1970: 1)))
        store.add(text("two", at: Date(timeIntervalSince1970: 2)))
        store.add(text("one", at: Date(timeIntervalSince1970: 3)))
        #expect(store.items.count == 2)
        #expect(store.items.first?.text == "one")
    }

    @Test func trimKeepsPinnedItems() {
        let store = makeStore()
        store.limit = 2
        store.add(text("pinned", at: Date(timeIntervalSince1970: 1), pinned: true))
        for i in 2...5 { store.add(text("item \(i)", at: Date(timeIntervalSince1970: TimeInterval(i)))) }
        #expect(store.items.count == 3)
        #expect(store.items.first?.isPinned == true)
        #expect(store.items.map(\.text) == ["pinned", "item 5", "item 4"])
    }

    @Test func searchRanksAndFilters() {
        let store = makeStore()
        store.add(text("hello world", at: Date(timeIntervalSince1970: 1)))
        store.add(text("say hello", at: Date(timeIntervalSince1970: 2)))
        store.add(text("unrelated", at: Date(timeIntervalSince1970: 3)))
        let results = store.results(for: "hello")
        #expect(results.map(\.item.text) == ["hello world", "say hello"])
    }

    @Test func persistsAndReloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-tests-\(UUID().uuidString)")
        let dataStore = DataStore(directory: dir)
        let store = ClipboardStore(dataStore: dataStore)
        store.add(text("persist me"))
        try await Task.sleep(for: .milliseconds(600))
        let reloaded = ClipboardStore(dataStore: dataStore)
        await reloaded.load()
        #expect(reloaded.items.map(\.text) == ["persist me"])
    }
}

@Suite struct ScreenshotScanTests {
    @Test func scanFindsImagesAndVideosNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("old.png"), mov = dir.appendingPathComponent("new.mov")
        try Data([0x89, 0x50]).write(to: png)
        try Data([0x00]).write(to: dir.appendingPathComponent("notes.txt"))
        try Data([0x00]).write(to: dir.appendingPathComponent("sub/nested.jpg"))
        try Data([0x00]).write(to: mov)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: png.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: mov.path)

        let flat = ScreenshotLibrary.scan(folders: [dir], includeSubfolders: false, includeVideos: true)
        #expect(flat.items.map(\.filename) == ["new.mov", "old.png"])
        #expect(flat.items.first?.kind == .video)

        let noVideo = ScreenshotLibrary.scan(folders: [dir], includeSubfolders: true, includeVideos: false)
        #expect(Set(noVideo.items.map(\.filename)) == ["old.png", "nested.jpg"])

        let missing = ScreenshotLibrary.scan(folders: [dir.appendingPathComponent("nope")], includeSubfolders: false, includeVideos: true)
        #expect(missing.missing.count == 1 && missing.items.isEmpty)
    }
}
