import Foundation
import Testing
@testable import MacBud

@Suite struct PredictionActivityTests {
    /// Seam: calls + sessions → one timeline. Catches rows out of order, lost error or cap rows,
    /// and an outcome linked to the driver call nearest the open instead of the one that made its pick.
    @Test func timelineOrdersRowsAndLinksOutcomesToThePick() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let reply = #"{"kind":"screenshot","hint":"newest","confidence":0.82,"note":"n"}"#
        let used = CallRecord(t: t0, purpose: "driver", model: "luna", effort: "medium", ms: 4800, tokens: TokenUsage(input: 9200), prompt: "p", reply: reply)
        let later = CallRecord(t: t0 + 30, purpose: "driver", model: "luna", effort: "medium", prompt: "p", reply: reply)
        let failed = CallRecord(t: t0 + 40, purpose: "driver", model: "luna", effort: "medium", status: "failed", error: "Not signed in", prompt: "p")
        let review = CallRecord(t: t0 + 90, purpose: "reviewer", model: "sol", effort: "high", prompt: "p", reply: "{}")
        let intent = LandingIntent(kind: .screenshot, hint: .newest, confidence: 0.82)
        let open = SessionRecord(t: t0 + 60, context: PredictionContext(hour: 10, weekday: "Thu", kinds: IntentKind.allCases),
                                 model: ModelPick(intent: intent, note: "n", key: "k", madeAt: t0 + 5), landed: intent, source: "model",
                                 opened: "shelf", outcome: Outcome(kind: .dictation, newest: true), secs: 3, hit: false)
        let rows = PredictionActivity.timeline(calls: [used, later, failed, review], sessions: [open], cap: 3)
        #expect(rows.map(\.kind) == [.reviewer, .miss, .open, .capReached, .error, .driver, .driver])
        #expect(rows[1].summary == "Miss: opened on screenshot · newest, used dictation · newest")
        #expect(rows[1].linkedCall?.t == used.t)
        #expect(rows[6].summary == "Driver said screenshot · newest, 0.82, 4.8 s, 9.2k tokens")
        #expect(rows[6].linkedOpens.count == 1 && rows[5].linkedOpens.isEmpty)
    }

    /// Seam: the reviewer's prompt and reply → strategies diff. Catches a prompt change that hides "before".
    @Test func reviewerRowsDiffTheStrategies() {
        let prompt = PredictionPrompts.reviewer(strategies: "- keep\n- drop\n", misses: [], hits: [], rates: "")
        let call = CallRecord(t: .now, purpose: "reviewer", model: "sol", effort: "high", prompt: prompt,
                              reply: #"{"strategies":"- keep\n- new","summary":"s"}"#)
        let entry = PredictionActivity.timeline(calls: [call], sessions: [], cap: 100)[0]
        #expect(PredictionActivity.details(entry).first { $0.diff != nil }?.diff == [.same("- keep"), .removed("- drop"), .added("- new")])
    }

    /// Seam: timeline → exported Markdown. Catches a prompt that quotes code breaking out of its block.
    @Test func exportKeepsQuotedCodeInsideItsBlock() {
        let call = CallRecord(t: .now, purpose: "driver", model: "luna", effort: "medium", status: "failed", error: "Timed out",
                              prompt: "```\nquoted\n```")
        let md = PredictionActivity.markdown(PredictionActivity.timeline(calls: [call], sessions: [], cap: 100), scope: "Filter: Errors")
        #expect(md.contains("· Driver failed: Timed out, 0.0 s\n"))
        #expect(md.contains("````\n```\nquoted\n```\n````"))
    }
}
