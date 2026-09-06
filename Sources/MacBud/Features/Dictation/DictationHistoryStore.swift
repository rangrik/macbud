import Foundation

nonisolated struct DictationHistoryItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var createdAt = Date.now
}

/// Completed transcripts are saved independently of general clipboard capture.
@Observable
final class DictationHistoryStore {
    private(set) var items: [DictationHistoryItem] = []
    private(set) var isLoaded = false
    var limit = 500 { didSet { prune(); save() } }
    @ObservationIgnored private let dataStore: DataStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(dataStore: DataStore = .default) { self.dataStore = dataStore }

    func load() async {
        guard !isLoaded else { return }
        let saved = await dataStore.load([DictationHistoryItem].self, from: "dictation-history.json") ?? []
        let pendingIDs = Set(items.map(\.id))
        items += saved.filter { !pendingIDs.contains($0.id) }
        items.sort { $0.createdAt > $1.createdAt }
        prune()
        isLoaded = true
        save()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(DictationHistoryItem(text: trimmed), at: 0)
        prune()
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Older versions explicitly saved completed dictations to Clipboard with MacBud as their source.
    func importLegacy(_ clipboard: [ClipboardItem], sourceBundleID: String) {
        for entry in clipboard where entry.kind == .text && entry.sourceBundleID == sourceBundleID {
            guard let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !items.contains(where: { $0.id == entry.id || ($0.text == text && abs($0.createdAt.timeIntervalSince(entry.copiedAt)) < 2) }) else { continue }
            items.append(DictationHistoryItem(id: entry.id, text: text, createdAt: entry.copiedAt))
        }
        items.sort { $0.createdAt > $1.createdAt }
        prune()
        save()
    }

    func results(for query: String) -> [DictationHistoryItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? items : items.filter { $0.text.localizedStandardContains(query) }
    }

    func flush() async { await saveTask?.value }

    private func prune() { items = Array(items.prefix(max(1, limit))) }

    private func save() {
        guard isLoaded else { return }
        let snapshot = items
        let preceding = saveTask
        saveTask = Task { [dataStore] in
            await preceding?.value
            do { try await dataStore.save(snapshot, as: "dictation-history.json") }
            catch { Log.app.error("dictation history save failed: \(error.localizedDescription)") }
        }
    }
}
