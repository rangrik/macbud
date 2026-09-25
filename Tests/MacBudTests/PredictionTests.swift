import Foundation
import Testing
@testable import MacBud

@MainActor @Suite struct PredictionTests {
    /// Seam: store items → prompt text. Catches clipboard text, paths, file names or dictation text reaching Codex.
    @Test func promptsCarryMetadataOnly() {
        let now = Date.now
        let clips = [ClipboardItem(id: UUID(), kind: .text, copiedAt: now - 5, text: "hunter2-token", byteCount: 13,
                                   sourceBundleID: "com.tinyspeck.slackmacgap", contentHash: "a"),
                     ClipboardItem(id: UUID(), kind: .file, copiedAt: now - 50, filePaths: ["/Users/owner/Private/Plan.pdf"],
                                   byteCount: 1, sourceBundleID: "com.apple.finder", contentHash: "b")]
        let shot = MediaItem(url: URL(fileURLWithPath: "/Users/owner/Private/Screenshot secret.png"), kind: .image,
                             createdAt: now - 20, byteCount: 1, folder: URL(fileURLWithPath: "/Users/owner/Private"))
        let context = PredictionContext.capture(clipboard: clips, media: [shot], dictations: [DictationHistoryItem(text: "my pin is 4321")],
                                                app: "com.apple.Safari", kinds: IntentKind.allCases, now: now)
        let rule = LandingIntent(kind: .screenshot, hint: .newest)
        let miss = SessionRecord(t: now, context: context, heuristic: rule, landed: rule, source: "heuristic", opened: "shelf",
                                 outcome: Outcome(kind: .text, newest: true), hit: false)
        for prompt in [PredictionPrompts.driver(context: context, strategies: "", recent: [miss]),
                       PredictionPrompts.delta(context: context, since: now - 60, sessions: [miss], events: [EventRecord(t: now, context: context)],
                                               strategies: "", written: nil),
                       PredictionPrompts.reviewer(strategies: "", misses: [miss], hits: [], rates: "")] {
            for secret in ["hunter2", "Private", "Plan.pdf", "secret", "4321"] { #expect(!prompt.contains(secret)) }
            #expect(prompt.contains("com.tinyspeck.slackmacgap") && prompt.contains(#""screenshotAge":20"#))
            #expect(!prompt.contains("dictationHistory") && !prompt.contains("section"), "Prompts must not name today's tabs")
        }
    }

    /// Seam: runner failure → open path. Catches a broken CLI leaving the open without the rules' pick.
    @Test func failingRunnerLeavesTheRulesInCharge() async {
        let context = context(screenshotAge: 10)
        let (predictor, _) = makePredictor(FakeRunner(["driver": .failure(ModelError(message: "Not signed in"))]), context)
        await predictor.refresh(context)
        #expect(predictor.status == .failed("Not signed in"))
        #expect(predictor.calls.last?.status == "failed")
        #expect(predictor.intentForOpen { _ in "shelf" }?.kind == .screenshot)
    }

    /// Seam: `codex exec --json` output → reply, tokens and cached pick. Catches lost tokens, hidden errors and hidden kinds.
    @Test func codexOutputIsParsedAndChecked() async throws {
        let ok = #"""
        {"type":"thread.started","thread_id":"th-1"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"kind\":\"snippet\",\"hint\":\"any\",\"confidence\":0.8,\"note\":\"n\"}"}}
        {"type":"turn.completed","usage":{"input_tokens":8946,"cached_input_tokens":0,"output_tokens":34,"reasoning_output_tokens":0}}
        """#
        let reply = try CodexRunner.parse(Data(ok.utf8), stderr: Data())
        #expect(reply.tokens == TokenUsage(input: 8946, output: 34) && reply.thread == "th-1")
        let failed = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"Model not supported\"}}"}}"#
        let error = #expect(throws: ModelError.self) { try CodexRunner.parse(Data(failed.utf8), stderr: Data()) }
        #expect(error?.message == "Model not supported")

        let all = context()
        let (predictor, _) = makePredictor(FakeRunner(["driver": .success(reply.text)]), all)
        await predictor.refresh(all)
        #expect(predictor.intentForOpen { _ in "shelf" }?.kind == .snippet)
        let noSnippets = context(kinds: [.text, .link, .image, .screenshot])
        let (refusing, _) = makePredictor(FakeRunner(["driver": .success(reply.text)]), noSnippets)
        await refusing.refresh(noSnippets)
        #expect(refusing.calls.last?.status == "unusable")
        #expect(refusing.intentForOpen { _ in "shelf" }?.kind == .text)
    }

    /// Seam: recorded misses → reviewer → strategies file → next driver prompt.
    /// Catches a reviewer that never fires, a strategies file that is not written, or a driver that never reads it.
    @Test func missesPastTheThresholdRewriteWhatTheDriverReads() async throws {
        let runner = FakeRunner(["driver": .success(#"{"kind":"text","hint":"any","confidence":0.5,"note":"n"}"#),
                                 "reviewer": .success(#"{"strategies":"- In Xcode, open Snippets.","summary":"s"}"#)])
        let context = context()
        let (predictor, settings) = makePredictor(runner, context)
        settings.prediction.missThreshold = 2
        for _ in 0..<2 {
            #expect(predictor.intentForOpen { _ in "shelf" }?.kind == .text)
            predictor.noteAction("copy", outcome: Outcome(kind: .snippet), in: "snippets")
            predictor.sessionEnded()
        }
        for _ in 0..<200 where predictor.lastReview == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predictor.memory.text("strategies.md")?.text == "- In Xcode, open Snippets.\n")
        await predictor.refresh(context)
        #expect(await runner.prompts["driver"]?.contains("- In Xcode, open Snippets.") == true)
        #expect(ReviewTrigger.isDue(misses: 1, since: .now - 12 * 3600, now: .now, threshold: 10, hours: 12))
    }

    /// Seam: session memory → next driver turn. Catches a delta that repeats old opens, items or strategies, or misses new ones.
    @Test func deltaCarriesOnlyWhatCameAfterTheLastCall() {
        let last = Date.now - 100
        func open(_ t: Date, _ app: String) -> SessionRecord {
            let ctx = PredictionContext(hour: 10, weekday: "Thu", app: app, kinds: IntentKind.allCases)
            return SessionRecord(t: t, context: ctx, landed: LandingIntent(kind: .text), source: "model", opened: "shelf",
                                 outcome: Outcome(kind: .text), hit: true)
        }
        func event(_ t: Date, clip: Int?, shot: Int? = nil) -> EventRecord {
            EventRecord(t: t, context: PredictionContext(hour: 10, weekday: "Thu", clipboardKind: "text", clipboardSource: "com.apple.Notes",
                                                         clipboardAge: clip, screenshotAge: shot, kinds: IntentKind.allCases))
        }
        let events = [event(last - 5, clip: 30), event(last + 20, clip: 5), event(last + 40, clip: 25, shot: 1)]
        let sessions = [open(last - 50, "com.old.App"), open(last + 10, "com.new.App")]
        let delta = PredictionPrompts.delta(context: context(), since: last, sessions: sessions, events: events,
                                            strategies: "- a rule", written: last - 10)
        #expect(delta.contains("com.new.App") && !delta.contains("com.old.App") && !delta.contains("- a rule"))
        #expect(delta.components(separatedBy: "copied text from com.apple.Notes").count == 2, "one new clip, told once")
        #expect(delta.contains("saved a screenshot") && !delta.contains("Kinds they can reach now"))
        #expect(PredictionPrompts.delta(context: context(), since: last, sessions: [], events: [], strategies: "- a rule",
                                        written: last + 5).contains("- a rule"))
    }

    /// Seam: thread state → resume or start over. Catches a thread that grows without bound or outlives a model change.
    @Test func threadIsResumedUntilItIsTooLongOrTooBig() throws {
        let thread = DriverThread(id: "t", model: "m", turns: 39, size: 29_999, lastCall: .now)
        #expect(DriverThread.resumable(thread, model: "m", maxTurns: 40, maxTokens: 30_000) == thread)
        #expect(DriverThread.resumable(nil, model: "m", maxTurns: 40, maxTokens: 30_000) == nil)
        for (turns, size, model) in [(40, 1, "m"), (1, 30_000, "m"), (1, 1, "other")] {
            let stale = DriverThread(id: "t", model: "m", turns: turns, size: size, lastCall: .now)
            #expect(DriverThread.resumable(stale, model: model, maxTurns: 40, maxTokens: 30_000) == nil)
        }
        // Settings saved before these knobs existed must keep the owner's choices, not reset to defaults.
        let saved = try JSONDecoder().decode(PredictionConfig.self, from: Data(#"{"enabled":true,"useModel":false}"#.utf8))
        #expect(!saved.useModel && saved.threadTurns == 40)
    }

    /// Seam: driver calls ↔ the kept Codex thread, across relaunches. Catches a thread re-sent the whole instruction,
    /// running totals logged as one turn's tokens, a thread id lost on relaunch, and a lost thread that never recovers.
    @Test func driverResumesOneThreadAndStartsOverWhenItIsLost() async throws {
        let runner = FakeRunner(["driver": .success(#"{"kind":"text","hint":"any","confidence":0.5,"note":"n"}"#)])
        let context = context()
        let memory = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        func launch() async -> SectionPredictor {
            let predictor = makePredictor(runner, context, memory).0
            await predictor.start()
            await predictor.refresh(context)
            return predictor
        }
        #expect(await launch().thread?.id == "t1")
        #expect(await runner.prompts["driver"]?.contains("Kinds they can reach now") == true)
        let relaunched = await launch()
        #expect(await runner.prompts["driver"]?.hasPrefix("## Since your last pick") == true)
        #expect(relaunched.calls.last?.thread == "t1" && relaunched.calls.last?.turn == 2 && relaunched.calls.last?.tokens?.input == 10)
        await runner.forget("t1")
        #expect(await launch().thread == nil)
        #expect(await launch().thread?.id == "t2")
        #expect(await runner.prompts["driver"]?.contains("Kinds they can reach now") == true)
    }

    private func context(screenshotAge: Int? = nil, kinds: [IntentKind] = IntentKind.allCases) -> PredictionContext {
        PredictionContext(hour: 10, weekday: "Thu", app: "com.apple.dt.Xcode", screenshotAge: screenshotAge, kinds: kinds)
    }

    private func makePredictor(_ runner: FakeRunner, _ context: PredictionContext,
                               _ memory: DataStore = DataStore(directory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString))) -> (SectionPredictor, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return (SectionPredictor(settings: settings, memory: memory, runner: runner) { context }, settings)
    }
}

private actor FakeRunner: ModelRunner {
    let replies: [String: Result<String, ModelError>]
    var prompts: [String: String] = [:]
    /// Kept threads and their turn counts, like Codex's stored sessions.
    var threads: [String: Int] = [:], made = 0

    init(_ replies: [String: Result<String, ModelError>]) { self.replies = replies }

    func codexPath() async -> String? { "/fake/codex" }
    func run(_ call: ModelCall) async throws -> ModelReply {
        prompts[call.purpose] = call.prompt
        var id: String?
        if call.keepThread {
            if let old = call.thread, threads[old] == nil { throw ModelError(message: "no rollout found", threadGone: true) }
            if call.thread == nil { made += 1 }
            id = call.thread ?? "t\(made)"
            threads[id!, default: 0] += 1
        }
        // Like Codex, a kept thread reports its running total.
        return ModelReply(text: try (replies[call.purpose] ?? .failure(ModelError(message: "no reply"))).get(),
                          tokens: TokenUsage(input: 10 * (id.flatMap { threads[$0] } ?? 1)), thread: id)
    }

    func forget(_ id: String) { threads[id] = nil }
}
