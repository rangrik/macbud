import Foundation

@Observable
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    private(set) var isLoaded = false

    @ObservationIgnored let dataStore: DataStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(dataStore: DataStore = .default) {
        self.dataStore = dataStore
    }

    func load() async {
        if let loaded = await dataStore.load([Snippet].self, from: "snippets.json") {
            snippets = loaded
        } else {
            snippets = Self.starterSnippets
            isLoaded = true
            scheduleSave()
        }
        isLoaded = true
        Log.snippets.info("loaded \(self.snippets.count) snippets")
    }

    func upsert(_ snippet: Snippet) {
        var s = snippet
        s.updatedAt = .now
        if let index = snippets.firstIndex(where: { $0.id == s.id }) { snippets[index] = s } else { snippets.append(s) }
        scheduleSave()
    }

    func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        scheduleSave()
    }

    func recordUse(_ id: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].useCount += 1
        scheduleSave()
    }

    func snippet(id: UUID) -> Snippet? { snippets.first { $0.id == id } }

    /// Most used first when the query is empty; otherwise best match first, with exact keyword hits on top.
    func results(for query: String) -> [(item: Snippet, match: SearchMatch)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return snippets.sorted { a, b in a.useCount != b.useCount ? a.useCount > b.useCount : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
                .map { ($0, SearchMatch(score: 0, ranges: [])) }
        }
        var ranked = SearchMatcher.rank(snippets, query: trimmed, text: \.searchText)
        let lower = trimmed.lowercased()
        ranked.sort { a, b in
            let ak = a.item.keyword.lowercased() == lower, bk = b.item.keyword.lowercased() == lower
            if ak != bk { return ak }
            return a.match.score > b.match.score
        }
        return ranked
    }

    func replaceAll(_ new: [Snippet]) {
        snippets = new
        scheduleSave()
    }

    private func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let snapshot = snippets
            do { try await dataStore.save(snapshot, as: "snippets.json") }
            catch { Log.snippets.error("save failed: \(error.localizedDescription)") }
        }
    }

    static let starterSnippets: [Snippet] = [
        Snippet(name: "Today's date", keyword: "date", content: "{date}"),
        Snippet(name: "Email sign-off", keyword: "sig", content: "Thanks,\nPranav"),
        Snippet(name: "Meeting notes", keyword: "notes",
                content: "# Meeting — {date}\n\n**Attendees:** {cursor}\n\n**Agenda**\n- \n\n**Action items**\n- [ ] "),
    ]
}
