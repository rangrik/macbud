import Foundation

/// One correction you made: what the recogniser wrote, and what you actually said.
nonisolated struct DictationWordRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var heard: String
    var meant: String
    /// Candidates bias the recogniser but never rewrite text. Only an active rule rewrites.
    var isActive = false
    var hits = 1
    var createdAt = Date.now
    var updatedAt = Date.now

    var key: String { DictationWordRule.normalize(heard) }

    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The words you have taught dictation, filled in by correcting the notch rather than by
/// sitting down and typing a list.
///
/// Biasing is eager and rewriting is cautious on purpose: telling the recogniser a word exists
/// can only help, but rewriting finished text on a hunch corrupts it.
@Observable
final class DictationWordStore {
    private(set) var rules: [DictationWordRule] = []
    private(set) var isLoaded = false
    var limit = 300 { didSet { prune(); save() } }

    /// Longest list handed to the recogniser. Biasing loses its edge if everything is a hint.
    static let vocabularyLimit = 100
    private static let fileName = "dictation-words.json"

    @ObservationIgnored private let dataStore: DataStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(dataStore: DataStore = .default) { self.dataStore = dataStore }

    func load() async {
        guard !isLoaded else { return }
        let saved = await dataStore.load([DictationWordRule].self, from: Self.fileName) ?? []
        let pending = Set(rules.map(\.key))
        rules += saved.filter { !pending.contains($0.key) }
        rules.sort { $0.updatedAt > $1.updatedAt }
        prune()
        isLoaded = true
        save()
    }

    /// Records a correction and returns the rule it produced, or nil when there is nothing to learn.
    ///
    /// `confirmed` means we have grounds to trust it straight away: the recogniser said it was
    /// unsure, or you picked one of its own alternatives. Everything else waits for a second
    /// sighting, so one stray rewording never becomes a permanent rewrite.
    @discardableResult
    func record(heard: String, meant: String, confirmed: Bool) -> DictationWordRule? {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        // A case-only difference is still worth learning: it fixes how the word is written.
        guard heard.count >= 2, !meant.isEmpty, heard != meant,
              !heard.contains(where: \.isWhitespace) else { return nil }

        let key = DictationWordRule.normalize(heard)
        if let index = rules.firstIndex(where: { $0.key == key && $0.meant == meant }) {
            rules[index].hits += 1
            rules[index].updatedAt = .now
            // Seen twice, or confirmed once: safe to start rewriting.
            if confirmed || rules[index].hits >= 2 { rules[index].isActive = true }
            let rule = rules[index]
            rules.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
            save()
            return rule
        }

        let rule = DictationWordRule(heard: heard, meant: meant, isActive: confirmed)
        rules.insert(rule, at: 0)
        prune()
        save()
        return rule
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func setActive(_ id: UUID, _ active: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isActive = active
        rules[index].updatedAt = .now
        save()
    }

    /// Words handed to the recogniser before you speak. Candidates count — a hint cannot do harm.
    var vocabulary: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rule in rules {
            let word = rule.meant
            guard seen.insert(DictationWordRule.normalize(word)).inserted else { continue }
            result.append(word)
            if result.count == Self.vocabularyLimit { break }
        }
        return result
    }

    /// Rewrites what the recogniser still got wrong, just before the text leaves. Whole words only.
    func apply(to text: String) -> String {
        var result = text
        for rule in rules where rule.isActive {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: rule.heard) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let template = NSRegularExpression.escapedTemplate(for: rule.meant)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    func flush() async { await saveTask?.value }

    private func prune() { rules = Array(rules.prefix(max(1, limit))) }

    private func save() {
        guard isLoaded else { return }
        let snapshot = rules
        let preceding = saveTask
        saveTask = Task { [dataStore] in
            await preceding?.value
            do { try await dataStore.save(snapshot, as: DictationWordStore.fileName) }
            catch { Log.app.error("dictation words save failed: \(error.localizedDescription)") }
        }
    }
}
