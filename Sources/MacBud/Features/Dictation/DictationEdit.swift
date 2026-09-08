import Foundation

/// Works out what you actually changed when you edit the transcript by hand.
///
/// Only a clean one-word-for-one-word swap is worth learning. Deleting a word, deleting a run of
/// them, or typing something new says nothing about how a word should be spelled.
nonisolated enum DictationEdit {
    enum Change: Equatable, Sendable {
        case replaced(from: String, to: String, wasUncertain: Bool)
        case removed(String)
        case inserted(String)

        /// Only a swap teaches the store a word.
        var lesson: (heard: String, meant: String, confirmed: Bool)? {
            if case let .replaced(from, to, uncertain) = self { return (from, to, uncertain) }
            return nil
        }
    }

    /// Rebuilds the words after an edit and reports what changed. Words you left alone keep the
    /// recogniser's confidence, so they stay underlined; words you touched are yours now.
    static func reconcile(_ old: [DictationWord], with new: [String]) -> (words: [DictationWord], changes: [Change]) {
        let oldTexts = old.map(\.text)
        var words: [DictationWord] = []
        var changes: [Change] = []

        for block in align(oldTexts, new) {
            switch block {
            case let .same(oldIndex, count):
                words.append(contentsOf: old[oldIndex..<(oldIndex + count)])
            case let .differs(oldRange, newRange):
                let dropped = Array(oldTexts[oldRange])
                let added = newRange.map { new[$0] }
                if dropped.count == 1, added.count == 1 {
                    changes.append(.replaced(from: dropped[0], to: added[0],
                                             wasUncertain: old[oldRange.lowerBound].isUncertain))
                } else {
                    changes.append(contentsOf: dropped.map(Change.removed))
                    changes.append(contentsOf: added.map(Change.inserted))
                }
                words.append(contentsOf: added.map { DictationWord(text: $0, confidence: 1, isEdited: true) })
            }
        }
        return (words, changes)
    }

    private enum Block {
        case same(oldIndex: Int, count: Int)
        case differs(old: Range<Int>, new: Range<Int>)
    }

    /// Longest common subsequence, then everything between the matches is one changed block.
    /// Capped because this is quadratic and a transcript is never that long.
    private static func align(_ old: [String], _ new: [String]) -> [Block] {
        guard old.count <= 600, new.count <= 600 else {
            return old.isEmpty && new.isEmpty ? [] : [.differs(old: 0..<old.count, new: 0..<new.count)]
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1
                                               : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var blocks: [Block] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                let start = i
                while i < old.count, j < new.count, old[i] == new[j] { i += 1; j += 1 }
                blocks.append(.same(oldIndex: start, count: i - start))
            } else {
                let oldStart = i, newStart = j
                while i < old.count || j < new.count {
                    if i < old.count, j < new.count, old[i] == new[j] { break }
                    if j < new.count, i >= old.count || table[i][j + 1] >= table[i + 1][j] { j += 1 }
                    else if i < old.count { i += 1 }
                }
                blocks.append(.differs(old: oldStart..<i, new: newStart..<j))
            }
        }
        return blocks
    }
}
