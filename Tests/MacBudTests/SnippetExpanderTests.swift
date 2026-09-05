import Foundation
import Testing
@testable import MacBud

@Suite struct SnippetExpanderTests {
    private var context: SnippetExpander.Context {
        var c = SnippetExpander.Context(clipboard: "PASTE", now: Date(timeIntervalSince1970: 1_700_000_000), uuid: { "UUID-1" })
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func expandsClipboardAndUUID() {
        let e = SnippetExpander.expand("a {clipboard} b {uuid}", context: context)
        #expect(e.text == "a PASTE b UUID-1")
        #expect(e.charactersAfterCursor == nil)
    }

    @Test func expandsCustomDateFormat() {
        let e = SnippetExpander.expand("{date:yyyy-MM-dd HH:mm}", context: context)
        #expect(e.text == "2023-11-14 22:13")
    }

    @Test func cursorMarkerIsRemovedAndOffsetReported() {
        let e = SnippetExpander.expand("Hello {cursor}, bye", context: context)
        #expect(e.text == "Hello , bye")
        #expect(e.charactersAfterCursor == 5)
    }

    @Test func literalBracesAndUnknownPlaceholdersSurvive() {
        let e = SnippetExpander.expand("{{json}} {unknown} {", context: context)
        #expect(e.text == "{json} {unknown} {")
    }

    @Test func placeholderRangesOnlyCoverKnownOnes() {
        let ranges = SnippetExpander.placeholderRanges(in: "x {date} {nope} {clipboard}")
        #expect(ranges == [2..<8, 16..<27])
    }

    @Test func missingClipboardExpandsToEmpty() {
        var c = context
        c.clipboard = nil
        #expect(SnippetExpander.expand("[{clipboard}]", context: c).text == "[]")
    }
}
