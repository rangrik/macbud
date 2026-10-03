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
        #expect(rows[6].summary == "Driver luna said screenshot · newest, 0.82, 4.8 s, 9.2k tokens")
        #expect(rows[6].linkedOpens.count == 1 && rows[5].linkedOpens.isEmpty)
    }

    /// Seam: calls read back from the ledger → rows and links. Catches a Jev and a Luna call from one second (the ledger
    /// keeps whole seconds) sharing a row, and an open linked to the Luna call instead of Jev's.
    @Test func callsFromOneSecondKeepTheirOwnRows() async throws {
        let memory = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let t = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down) + 0.1)
        let reply = #"{"kind":"text","hint":"any","confidence":0.9,"note":"n"}"#
        await memory.appendLine(CallRecord(t: t, purpose: "driver", model: "jev-latest", effort: "-", prompt: "p", reply: reply), to: "calls.jsonl")
        await memory.appendLine(CallRecord(t: t + 0.4, purpose: "shadow", model: "gpt-6-luna", effort: "medium", prompt: "p", reply: reply),
                                to: "calls.jsonl")
        let calls = await memory.lines(CallRecord.self, in: "calls.jsonl")
        #expect(calls.count == 2 && calls[0].t == calls[1].t, "the ledger keeps whole seconds")
        let pick = ModelPick(intent: LandingIntent(kind: .text), note: "n", key: "k", madeAt: t + 0.2, model: "jev-latest")
        let open = SessionRecord(t: t + 2, context: PredictionContext(hour: 10, weekday: "Thu", kinds: [.text]), model: pick,
                                 landed: pick.intent, source: "model", driver: "jev-latest", opened: "shelf")
        let rows = PredictionActivity.timeline(calls: calls, sessions: [open], cap: 100)
        let jev = try #require(rows.first { $0.call?.purpose == "driver" }), luna = try #require(rows.first { $0.call?.purpose == "shadow" })
        #expect(Set(rows.map(\.id)).count == rows.count && jev.linkedOpens.count == 1 && luna.linkedOpens.isEmpty)
        let open1 = try #require(rows.first { $0.kind == .open })
        #expect(PredictionActivity.details(open1).first { $0.link != nil }?.link == jev.id)
    }

    /// Seam: records → their details. Catches an activity line recomputed, dropped or shown with escaped slashes, Luna's note
    /// labelled as the driver's, an old call
    /// claiming activity, and an open from before the swap relabelled as Jev driving with Luna in the shadow.
    @Test func detailsShowTheActivitySentAndKeepOldLabels() {
        let sent = CallRecord(t: .now, purpose: "shadow", model: "gpt-6-luna", effort: "medium",
                              prompt: #"{"activity":"just now: com.apple.Safari, “Docs”, github.com/a"}"#, reply: #"{"note":"n"}"#,
                              activity: "just now: com.apple.Safari, “Docs”, github.com/a")
        let old = CallRecord(t: .now - 60, purpose: "driver", model: "gpt-6-luna", effort: "medium", prompt: "p", reply: "{}")
        let rows = PredictionActivity.timeline(calls: [old, sent], sessions: [], cap: 100)
        let seen = rows.map { row in PredictionActivity.details(row).first { $0.title == "Activity the model saw" }?.text }
        #expect(seen == ["just now: com.apple.Safari, “Docs”, github.com/a", "Not recorded for this call."] && rows[0].summary.hasPrefix("Shadow gpt-6-luna said"))
        #expect(PredictionActivity.details(rows[0]).first { $0.title == "Context sent" }?.text.contains("“Docs”, github.com/a") == true)
        #expect(PredictionActivity.details(rows[0]).map(\.title).contains("Shadow's note") && !PredictionActivity.details(rows[0]).map(\.title).contains("Driver's note"))
        let pick = ModelPick(intent: LandingIntent(kind: .text), note: "n", key: "k", madeAt: .now)
        var open = SessionRecord(t: .now, context: PredictionContext(hour: 10, weekday: "Thu", kinds: [.text]), model: pick,
                                 landed: pick.intent, source: "model", opened: "shelf", shadow: pick)
        func titles() -> [String] { PredictionActivity.details(ActivityEntry(id: "o", t: open.t, kind: .open, summary: "", session: open)).map(\.title) }
        #expect(titles().contains("Jev, in the shadow") && PredictionActivity.timeline(calls: [], sessions: [open], cap: 1)[0].summary.hasSuffix("(model, 1.00)"))
        open.driver = "jev-latest"
        open.shadow?.model = "gpt-6-luna"
        #expect(titles().contains("gpt-6-luna, in the shadow") && PredictionActivity.timeline(calls: [], sessions: [open], cap: 1)[0].summary.hasSuffix("(Jev, 1.00)"))
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
