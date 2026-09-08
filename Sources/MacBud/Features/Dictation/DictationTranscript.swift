import Foundation

/// One word the recogniser produced, with how sure it was and what else it nearly chose.
nonisolated struct DictationWord: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var confidence: Double?
    var alternatives: [String] = []
    /// Set once you correct the word, so it stops being offered for correction.
    var isEdited = false

    /// Under this the notch underlines the word and offers alternatives. Calibrated against real
    /// recognitions: a sentence it got completely right scored 0.84 and up, while the words it
    /// actually misheard sat between 0.36 and 0.68.
    static let uncertainBelow = 0.70

    var isUncertain: Bool {
        guard !isEdited, let confidence else { return false }
        return confidence < Self.uncertainBelow
    }
}

/// A chunk of speech the recogniser has settled on, or the draft tail it is still rewriting.
nonisolated struct DictationSegment: Identifiable, Equatable, Sendable {
    var id = UUID()
    var words: [DictationWord]

    init(id: UUID = UUID(), words: [DictationWord]) {
        self.id = id
        self.words = words
    }

    init(id: UUID = UUID(), text: String) {
        self.init(id: id, words: DictationSegment.split(text).map { DictationWord(text: $0) })
    }

    var text: String { words.map(\.text).joined(separator: " ") }
    var isEmpty: Bool { words.isEmpty }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// What the notch shows: settled words you may edit, and the draft tail the engine still owns.
/// Splitting the two is what lets a correction survive — the engine never rewrites settled text.
nonisolated struct DictationTranscript: Equatable, Sendable {
    /// Changes when the engine starts over (a retry, or a file). Signals a wholesale replace.
    var attemptID = UUID()
    var settled: [DictationSegment] = []
    var draft: DictationSegment?
    /// How many chunks the engine has handed over. Editing can merge chunks together, so the
    /// segments on screen can no longer be counted to work out what is new.
    var consumedSegments: Int

    init(attemptID: UUID = UUID(), settled: [DictationSegment] = [], draft: DictationSegment? = nil) {
        self.attemptID = attemptID
        self.settled = settled
        self.draft = draft
        self.consumedSegments = settled.count
    }

    /// Convenience for callers that only have plain text.
    init(settledText: String, attemptID: UUID = UUID()) {
        let trimmed = settledText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(attemptID: attemptID, settled: trimmed.isEmpty ? [] : [DictationSegment(text: trimmed)])
    }

    var settledText: String {
        settled.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var text: String {
        ([settledText] + [draft?.text ?? ""]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var isEmpty: Bool { text.isEmpty }

    var uncertainWordCount: Int {
        settled.reduce(0) { $0 + $1.words.count(where: \.isUncertain) }
    }

    /// Keeps corrections you already made. The engine only appends settled chunks, so everything
    /// we already hold stays exactly as you left it and only the draft tail is swapped out.
    func merging(_ incoming: DictationTranscript) -> DictationTranscript {
        guard incoming.attemptID == attemptID else { return incoming }
        var result = self
        if incoming.settled.count > consumedSegments {
            result.settled.append(contentsOf: incoming.settled[consumedSegments...])
            result.consumedSegments = incoming.settled.count
        }
        result.draft = incoming.draft
        return result
    }

    var settledWords: [DictationWord] { settled.flatMap(\.words) }

    /// Folds your edited words back in as one chunk. What the engine has already handed over is
    /// remembered separately, so merging the next chunk still lands in the right place.
    mutating func replaceSettled(with words: [DictationWord]) {
        settled = words.isEmpty ? [] : [DictationSegment(words: words)]
    }

    /// Per-word alternatives, lifted from the recogniser's runner-up transcriptions. Only usable
    /// when a runner-up lines up word for word; otherwise there is no honest way to say which
    /// word it disagreed about, so that segment simply gets none.
    static func alignedAlternatives(chosen: [String], runnersUp: [[String]]) -> [[String]] {
        var result = [[String]](repeating: [], count: chosen.count)
        for candidate in runnersUp where candidate.count == chosen.count {
            for index in chosen.indices where candidate[index] != chosen[index] {
                if !result[index].contains(candidate[index]) { result[index].append(candidate[index]) }
            }
        }
        return result
    }
}
