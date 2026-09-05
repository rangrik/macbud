import Foundation
import SwiftUI
import Testing
@testable import MacBud

@Suite struct SearchMatcherTests {
    @Test func emptyQueryMatchesEverythingWithZeroScore() {
        let m = SearchMatcher.match(query: "   ", in: "anything")
        #expect(m?.score == 0)
        #expect(m?.ranges.isEmpty == true)
    }

    @Test func prefixBeatsWordStartBeatsInner() {
        let prefix = SearchMatcher.match(query: "git", in: "git commit")!.score
        let wordStart = SearchMatcher.match(query: "git", in: "run git commit")!.score
        let inner = SearchMatcher.match(query: "git", in: "digital")!.score
        #expect(prefix > wordStart)
        #expect(wordStart > inner)
    }

    @Test func everyTokenMustMatch() {
        #expect(SearchMatcher.match(query: "git push", in: "git commit") == nil)
        #expect(SearchMatcher.match(query: "git commit", in: "git commit -m") != nil)
    }

    @Test func subsequenceFallback() {
        let m = SearchMatcher.match(query: "gcm", in: "git commit -m")
        #expect(m != nil)
        #expect(m!.ranges.map(\.lowerBound) == [0, 4, 6])
        let substring = SearchMatcher.match(query: "commit", in: "git commit -m")!.score
        #expect(substring > m!.score)
    }

    @Test func caseAndDiacriticInsensitive() {
        let m = SearchMatcher.match(query: "cafe", in: "Le Café")
        #expect(m != nil)
        #expect(m?.ranges == [3..<7])
    }

    @Test func contiguousOffsetsMergeIntoOneRange() {
        let m = SearchMatcher.match(query: "clip", in: "Clipboard history")!
        #expect(m.ranges == [0..<4])
    }

    @Test func rankSortsByScoreThenOriginalOrder() {
        let items = ["digital", "git commit", "run git"]
        let ranked = SearchMatcher.rank(items, query: "git", text: { $0 })
        #expect(ranked.map(\.item) == ["git commit", "run git", "digital"])
    }

    @Test func highlightingProducesAttributedRuns() {
        let a = AttributedString.highlighting("Clipboard", ranges: [0..<4]) { $0.foregroundColor = .red }
        var count = 0
        for run in a.runs where run.foregroundColor == .red { count += 1 }
        #expect(count == 1)
    }
}
