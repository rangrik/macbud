import AppKit

/// In-memory clipboard history with debounced JSON persistence and image blobs on disk.
@Observable
final class ClipboardStore {
    private(set) var items: [ClipboardItem] = []
    private(set) var isLoaded = false
    var limit: Int = 500 { didSet { trim(); scheduleSave() } }

    @ObservationIgnored let dataStore: DataStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(dataStore: DataStore = .default) {
        self.dataStore = dataStore
    }

    func load() async {
        let loaded = await dataStore.load([ClipboardItem].self, from: "clipboard.json") ?? []
        items = Self.sorted(loaded)
        isLoaded = true
        Log.clipboard.info("loaded \(loaded.count) clipboard items")
    }

    // MARK: Mutations

    /// Inserts a new item or, when the same content exists, bumps it to the top.
    func add(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            var existing = items[index]
            existing.copiedAt = item.copiedAt
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            items[index] = existing
            // A duplicate image write leaves an orphan blob behind; drop it.
            if let file = item.imageFile, file != existing.imageFile { removeBlobs(image: file, preview: item.previewFile) }
        } else {
            items.append(item)
        }
        items = Self.sorted(items)
        trim()
        scheduleSave()
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        removeBlobs(image: removed.imageFile, preview: removed.previewFile)
        scheduleSave()
    }

    func removeAll(keepPinned: Bool = true) {
        let removed = keepPinned ? items.filter { !$0.isPinned } : items
        for item in removed { removeBlobs(image: item.imageFile, preview: item.previewFile) }
        items = keepPinned ? items.filter(\.isPinned) : []
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        items = Self.sorted(items)
        scheduleSave()
    }

    func item(id: UUID) -> ClipboardItem? { items.first { $0.id == id } }

    // MARK: Queries

    /// Pinned first, then newest first; with a query, best match first.
    func results(for query: String) -> [(item: ClipboardItem, match: SearchMatch)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return items.map { ($0, SearchMatch(score: 0, ranges: [])) } }
        return SearchMatcher.rank(items, query: trimmed, text: \.searchText)
    }

    func imageURL(for item: ClipboardItem) -> URL? { item.imageFile.map(dataStore.imageURL(named:)) }
    func previewURL(for item: ClipboardItem) -> URL? { (item.previewFile ?? item.imageFile).map(dataStore.imageURL(named:)) }

    // MARK: Internals

    private static func sorted(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.copiedAt > b.copiedAt
        }
    }

    private func trim() {
        guard limit > 0 else { return }
        var unpinnedSeen = 0
        var kept: [ClipboardItem] = []
        for item in items {
            if item.isPinned { kept.append(item); continue }
            unpinnedSeen += 1
            if unpinnedSeen <= limit { kept.append(item) } else { removeBlobs(image: item.imageFile, preview: item.previewFile) }
        }
        items = kept
    }

    private func removeBlobs(image: String?, preview: String?) {
        let store = dataStore
        Task.detached {
            if let image { await store.removeImage(named: image) }
            if let preview { await store.removeImage(named: preview) }
        }
    }

    private func scheduleSave() {
        guard isLoaded else { return } // never overwrite the file with a pre-load empty list
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let snapshot = items
            do { try await dataStore.save(snapshot, as: "clipboard.json") }
            catch { Log.clipboard.error("save failed: \(error.localizedDescription)") }
        }
    }
}
