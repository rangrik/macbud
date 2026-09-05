import Foundation

/// Result of matching a query against a candidate string.
nonisolated struct SearchMatch: Equatable, Sendable {
    /// Higher is better. 0 for an empty query.
    var score: Int
    /// Matched character offsets (into `Array(text)`), merged into runs, for highlighting.
    var ranges: [Range<Int>]
}

/// Raycast-style matcher: every whitespace-separated query token must match; substring matches beat
/// subsequence matches; prefix and word-start positions score highest. Case- and diacritic-insensitive.
nonisolated enum SearchMatcher {
    static func match(query: String, in text: String) -> SearchMatch? {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
        if tokens.isEmpty { return SearchMatch(score: 0, ranges: []) }
        let haystack = fold(text)
        var total = 0
        var offsets: [Int] = []
        for token in tokens {
            guard let (score, matched) = matchToken(token, in: haystack) else { return nil }
            total += score
            offsets.append(contentsOf: matched)
        }
        // Prefer shorter candidates slightly so exact-ish hits float up.
        total += max(0, 30 - haystack.count / 10)
        return SearchMatch(score: total, ranges: merge(offsets))
    }

    /// Convenience for sorting: returns matches paired with elements, best first, stable for ties.
    static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [(item: T, match: SearchMatch)] {
        let scored = items.enumerated().compactMap { index, item -> (Int, T, SearchMatch)? in
            guard let m = match(query: query, in: text(item)) else { return nil }
            return (index, item, m)
        }
        return scored.sorted { a, b in a.2.score != b.2.score ? a.2.score > b.2.score : a.0 < b.0 }
            .map { (item: $0.1, match: $0.2) }
    }

    // MARK: - Internals

    /// Lower-cases and strips diacritics while keeping the character count stable where possible,
    /// so offsets map back onto the original string for highlighting.
    static func fold(_ s: String) -> [Character] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        if folded.count == s.count { return Array(folded) }
        let lowered = s.lowercased()
        if lowered.count == s.count { return Array(lowered) }
        return s.map { Character($0.lowercased().first.map(String.init) ?? String($0)) }
    }

    private static func matchToken(_ token: [Character], in text: [Character]) -> (Int, [Int])? {
        guard !token.isEmpty, token.count <= text.count else { return nil }
        // Substring search, best position wins.
        var best: (score: Int, start: Int)?
        var i = 0
        while i + token.count <= text.count {
            if text[i] == token[0], Array(text[i..<(i + token.count)]) == token {
                let score: Int
                if i == 0 { score = 100 }
                else if isBoundary(text[i - 1]) { score = 80 }
                else { score = 50 }
                if best == nil || score > best!.score { best = (score, i) }
                if score == 100 { break }
            }
            i += 1
        }
        if let best {
            return (best.score + token.count, Array(best.start..<(best.start + token.count)))
        }
        // Subsequence fallback: characters in order with gaps; contiguous runs and word starts score more.
        var offsets: [Int] = []
        var t = 0
        var score = 10
        var lastMatched = -2
        for (idx, ch) in text.enumerated() where t < token.count {
            if ch == token[t] {
                offsets.append(idx)
                if idx == lastMatched + 1 { score += 6 } else if idx == 0 || isBoundary(text[idx - 1]) { score += 4 } else { score += 1 }
                lastMatched = idx
                t += 1
            }
        }
        guard t == token.count else { return nil }
        return (score, offsets)
    }

    private static func isBoundary(_ c: Character) -> Bool {
        c.isWhitespace || c.isPunctuation || c.isSymbol || c == "_" || c == "/" || c == "."
    }

    private static func merge(_ offsets: [Int]) -> [Range<Int>] {
        let sorted = Array(Set(offsets)).sorted()
        var result: [Range<Int>] = []
        for o in sorted {
            if let last = result.last, last.upperBound == o {
                result[result.count - 1] = last.lowerBound..<(o + 1)
            } else {
                result.append(o..<(o + 1))
            }
        }
        return result
    }
}

extension AttributedString {
    /// Highlights matched character runs in `text` with the given attributes.
    static func highlighting(_ text: String, ranges: [Range<Int>], apply: (inout AttributeContainer) -> Void) -> AttributedString {
        var result = AttributedString(text)
        guard !ranges.isEmpty else { return result }
        let chars = Array(text)
        for range in ranges where range.upperBound <= chars.count {
            let startOffset = String(chars[0..<range.lowerBound]).utf8.count
            let endOffset = startOffset + String(chars[range]).utf8.count
            guard let start = result.utf8.index(result.startIndex, offsetBy: startOffset, limitedBy: result.endIndex),
                  let end = result.utf8.index(result.startIndex, offsetBy: endOffset, limitedBy: result.endIndex) else { continue }
            var container = AttributeContainer()
            apply(&container)
            result[start..<end].mergeAttributes(container)
        }
        return result
    }
}
