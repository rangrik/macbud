import Foundation
import Testing
@testable import MacBud

@MainActor @Suite struct PredictionTests {
    /// Seam: store items and outcomes → prompt text. Catches clipboard text, paths, file names, dictation text
    /// or an app card's window title reaching a model, and the running apps an `app` pick needs not reaching it.
    @Test func promptsCarryMetadataOnly() {
        let now = Date.now
        let clips = [ClipboardItem(id: UUID(), kind: .text, copiedAt: now - 5, text: "hunter2-token", byteCount: 13,
                                   sourceBundleID: "com.tinyspeck.slackmacgap", contentHash: "a"),
                     ClipboardItem(id: UUID(), kind: .file, copiedAt: now - 50, filePaths: ["/Users/owner/Private/Plan.pdf"],
                                   byteCount: 1, sourceBundleID: "com.apple.finder", contentHash: "b")]
        let shot = MediaItem(url: URL(fileURLWithPath: "/Users/owner/Private/Screenshot secret.png"), kind: .image,
                             createdAt: now - 20, byteCount: 1, folder: URL(fileURLWithPath: "/Users/owner/Private"))
        let context = PredictionContext.capture(clipboard: clips, media: [shot], dictations: [DictationHistoryItem(text: "my pin is 4321")],
                                                app: "com.apple.Safari", running: ["com.apple.Safari", "com.google.Chrome"],
                                                kinds: IntentKind.allCases, now: now)
        let rule = LandingIntent(kind: .screenshot, hint: .newest)
        let miss = SessionRecord(t: now, context: context, heuristic: rule, landed: rule, source: "heuristic", opened: "shelf",
                                 outcome: Outcome(kind: .text, newest: true), hit: false)
        let window = AppEntry(bundleID: "com.apple.Preview", name: "Preview", url: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                              windowID: "w", label: "Layoffs draft.pdf")
        let switched = SessionRecord(t: now, context: context, heuristic: rule, landed: rule, source: "heuristic", opened: "all",
                                     outcome: .app(window, switchTarget: nil), hit: false)
        for prompt in [PredictionPrompts.luna(context: context, strategies: "", recent: [miss, switched]),
                       PredictionPrompts.delta(context: context, since: now - 60, sessions: [miss, switched], events: [EventRecord(t: now, context: context)],
                                               strategies: "", written: nil),
                       PredictionPrompts.reviewer(strategies: "", misses: [miss, switched], hits: [], rates: "")] {
            for secret in ["hunter2", "Private", "Plan.pdf", "secret", "4321", "Layoffs"] { #expect(!prompt.contains(secret)) }
            #expect(prompt.contains("com.tinyspeck.slackmacgap") && prompt.contains(#""screenshotAge":20"#))
            #expect(prompt.contains(#""previousApp":"com.google.Chrome""#) && prompt.contains("app com.apple.Preview"))
            #expect(!prompt.contains("dictationHistory") && !prompt.contains("section"), "Prompts must not name today's tabs")
        }
        let jev = PredictionPrompts.jev(context: context, strategies: "", recent: [miss, switched], model: "jev-latest")
        for secret in ["hunter2", "Private", "Plan.pdf", "secret", "4321", "Layoffs"] { #expect(!jev.contains(secret)) }
        #expect(jev.contains("slackmacgap") && jev.contains("Preview") && jev.contains("seconds ago"))
    }

    /// Seam: Jev's answers → the landing, Luna's → a scored shadow, both stamped with who answered.
    /// Catches a shadow that lands, goes unscored, flips Jev's status or eats the daily cap, and an open
    /// from before the swap (Luna driving, Jev in the shadow) counted as Jev's result.
    @Test func jevDrivesLunaIsScoredInTheShadowAndOldOpensStayApart() async throws {
        let answers = #"""
        {"model":"jev-1.13.0","answers":{"kind":{"type":"choice","choice":"snippet","probabilities":{"snippet":0.7,"text":0.3},"confidence":0.55},
        "which_item":{"type":"choice","choice":"either","probabilities":{"either":0.8,"newest":0.1,"older":0.1},"confidence":0.7}},
        "usage":{"input_tokens":900,"output_tokens":20}}
        """#
        let reply = try JevRunner.normalize(Data(answers.utf8))
        let parsed = try #require(DriverReply.parse(reply.text, kinds: IntentKind.allCases))
        #expect(parsed.kind == .snippet && parsed.hint == .any && parsed.confidence == 0.55 && reply.tokens.input == 900)
        let context = context()
        let jev = FakeRunner(["driver": .success(reply.text)])
        let (failing, _) = makePredictor(jev, context, codex: FakeRunner(["shadow": .failure(ModelError(message: "Model not supported"))]))
        await failing.refresh(context)?.value
        #expect(failing.status == .ready && failing.calls.last { $0.purpose == "shadow" }?.status == "failed")

        let pick = #"{"intent":{"kind":"%@","hint":"any","confidence":0.8},"note":"n","key":"k","madeAt":"2026-09-30T09:59:00Z"}"#
        let old = #"{"t":"2026-09-30T10:00:00Z","context":{"hour":10,"weekday":"Wed","kinds":["text","snippet"]},"#
            + #""landed":{"kind":"text","hint":"any","confidence":0.8},"source":"model","opened":"shelf","outcome":{"kind":"text"},"#
            + #""model":\#(String(format: pick, "text")),"shadow":\#(String(format: pick, "snippet")),"hit":true,"shadowHit":false}"#
        let memory = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await memory.writeText(old + "\n", to: "predictions.jsonl")
        let luna = FakeRunner(["shadow": .success(#"{"kind":"text","hint":"any","confidence":0.5,"note":"n"}"#)])
        let (scored, _) = makePredictor(jev, context, memory, codex: luna)
        await scored.start()
        await scored.activity.record(ActivityEvent(t: .now, app: "com.apple.dt.Xcode", title: "Plan.swift", url: "github.com/rangrik/macbud"))
        let now = scored.context()
        await scored.refresh(now)?.value
        let sent = "just now: com.apple.dt.Xcode, “Plan.swift”, github.com/rangrik/macbud"
        #expect(now.activity == sent && scored.calls.count == 2 && scored.calls.allSatisfy { $0.activity == sent })
        #expect(await jev.prompts["driver"]?.contains(sent) == true)
        #expect(await luna.prompts["shadow"]?.contains(sent) == true)
        #expect(scored.intentForOpen { _ in "shelf" }?.kind == .snippet)
        scored.noteAction("copy", outcome: Outcome(kind: .text), in: "shelf")
        scored.sessionEnded()
        let session = try #require(scored.sessions.last)
        #expect(session.hit == false && session.shadowHit == true && session.driver == "jev-latest")
        #expect(session.model?.model == "jev-latest" && session.shadow?.model == "gpt-6-luna" && scored.jevSince == session.t)
        let rates = scored.rates
        #expect(rates.jev.model.total == 1 && rates.jev.model.hits == 0 && rates.jev.shadow.hits == 1 && rates.jev.landedWhereShadow.hits == 0)
        #expect(rates.luna.model.hits == 1 && rates.luna.shadow.total == 1 && rates.luna.shadow.hits == 0)
        #expect(scored.callsToday == 1, "shadow calls stay outside the cap")
    }

    /// Seam: an Accessibility read → the recorded event. Catches reading while locked, idle or untrusted,
    /// a secure field's window being read, and file paths or query strings kept as web addresses.
    @Test func activityRecordsOnlyWhatIsAllowed() {
        for (trusted, locked, idle) in [(false, false, 0.0), (true, true, 0), (true, false, 300)] {
            #expect(ActivityProbe.gate(trusted: trusted, locked: locked, idle: idle) { Issue.record("read while blocked"); return nil } == nil)
        }
        let secure = ActivityEvent.read(t: .now, app: "com.apple.Safari", role: "AXTextField", subrole: "AXSecureTextField") {
            Issue.record("a secure field's window was read")
            return ("Bank login", "https://bank.example/login")
        }
        #expect(secure == ActivityEvent(t: secure.t, app: "com.apple.Safari", role: "secure field"))
        let page = ActivityEvent.read(t: .now, app: "com.apple.Safari", role: "AXTextArea", subrole: nil) {
            ("Pull requests", URL(string: "https://github.com/rangrik/macbud/pulls?token=abc#top"))
        }
        #expect(page.title == "Pull requests" && page.url == "github.com/rangrik/macbud/pulls" && page.role == "text area")
        for raw in ["file:///Users/owner/Private/Plan.pdf", "not a url", 42] as [Any] { #expect(ActivityEvent.webAddress(raw) == nil) }
    }

    /// Seam: recorded events → the activity file and the line both models read. Catches a day-old event surviving a relaunch,
    /// a line past 10 minutes or 8 events or out of order, and a role-only change counted as a change worth a call.
    @Test func activityFileAndLineStayBounded() async {
        let memory = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let now = Date.now
        await memory.appendLine(ActivityEvent(t: now - 86_000, app: "com.old.App"), to: ActivityLog.file)
        let log = ActivityLog(memory: memory) { _, _ in nil }
        await log.load()
        #expect(log.line(now: now) == "No recent activity.")
        #expect(await memory.lines(ActivityEvent.self, in: ActivityLog.file).isEmpty)
        await log.record(ActivityEvent(t: now - 700, app: "com.too.Old"))
        for i in 0..<10 { await log.record(ActivityEvent(t: now - 590 + Double(i) * 60, app: "app\(i)", title: "T\(i)")) }
        let parts = log.line(now: now).components(separatedBy: "; ")
        #expect(parts.count == 8 && parts.first == "7 min ago: app2, “T2”" && parts.last == "just now: app9, “T9”")
        let changed = log.changedAt
        await log.record(ActivityEvent(t: now, app: "app9", title: "T9", role: "text field"))
        #expect(log.changedAt == changed && log.events.last?.role == "text field")
        await log.record(ActivityEvent(t: now, app: "app9", title: "T9", url: "example.com/b", role: "text field"))
        #expect(log.changedAt == now)
    }

    /// Seam: activity changes and opens → when Jev is asked. Catches a refresh before 10 quiet seconds, a role-only change
    /// or a current pick asking again, a same-host page change not asking, an open waiting past its budget or the cap,
    /// and a late reply changing an open that already landed.
    @Test func jevIsAskedWhenTheMomentChangesOrAnOpenNeedsIt() async throws {
        let jev = FakeRunner(["driver": .success(#"{"kind":"snippet","hint":"any","confidence":0.9,"note":"n"}"#)])
        let (predictor, settings) = makePredictor(jev, context())
        await predictor.start()
        let t = Date.now
        await predictor.activity.record(ActivityEvent(t: t, app: "com.apple.dt.Xcode", title: "Plan", url: "github.com/a"))
        let now = predictor.context()
        #expect(!predictor.wantsRefresh(now, at: t + 9) && predictor.wantsRefresh(now, at: t + 10))
        await jev.hold()
        #expect(predictor.wantsCallBeforeOpen(now))
        await predictor.callBeforeOpen(now, budget: .milliseconds(50))
        #expect(predictor.intentForOpen(now) { _ in "shelf" }?.kind == .text, "Jev missed the budget, so the rules land")
        await jev.release()
        for _ in 0..<200 where predictor.status != .ready { try await Task.sleep(for: .milliseconds(5)) }
        predictor.noteAction("copy", outcome: Outcome(kind: .snippet), in: "shelf")
        predictor.sessionEnded()
        #expect(predictor.sessions.last?.landed.kind == .text && predictor.sessions.last?.source == "heuristic")
        #expect(!predictor.wantsCallBeforeOpen(now) && !predictor.wantsRefresh(now, at: t + 60))
        await predictor.activity.record(ActivityEvent(t: t + 20, app: "com.apple.dt.Xcode", title: "Plan", url: "github.com/a", role: "text field"))
        #expect(!predictor.wantsRefresh(predictor.context(), at: t + 60))
        await predictor.activity.record(ActivityEvent(t: t + 30, app: "com.apple.dt.Xcode", title: "Plan", url: "github.com/b"))
        let moved = predictor.context()
        #expect(moved.key == now.key && predictor.wantsRefresh(moved, at: t + 40) && predictor.wantsCallBeforeOpen(moved))
        settings.prediction.dailyCallCap = 1
        #expect(!predictor.wantsCallBeforeOpen(moved))
    }

    /// Seam: runner failure → open path. Catches a broken CLI leaving the open without the rules' pick.
    @Test func failingRunnerLeavesTheRulesInCharge() async {
        let context = context(screenshotAge: 10)
        let (predictor, _) = makePredictor(FakeRunner(["driver": .failure(ModelError(message: "HTTP 401"))]), context)
        await predictor.refresh(context)
        #expect(predictor.status == .failed("HTTP 401"))
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

    /// Seam: recorded misses → Codex reviewer → strategies file → both models' next requests.
    /// Catches a reviewer that never fires, a strategies file that is not written, or a model that never reads it.
    @Test func missesPastTheThresholdRewriteWhatBothModelsRead() async throws {
        let jev = FakeRunner(["driver": .success(#"{"kind":"text","hint":"any","confidence":0.5,"note":"n"}"#)])
        let codex = FakeRunner(["shadow": .success(#"{"kind":"text","hint":"any","confidence":0.5,"note":"n"}"#),
                                "reviewer": .success(#"{"strategies":"- In Xcode, open Snippets.","summary":"s"}"#)])
        let context = context()
        let (predictor, settings) = makePredictor(jev, context, codex: codex)
        settings.prediction.missThreshold = 2
        for _ in 0..<2 {
            #expect(predictor.intentForOpen { _ in "shelf" }?.kind == .text)
            predictor.noteAction("copy", outcome: Outcome(kind: .snippet), in: "snippets")
            predictor.sessionEnded()
        }
        for _ in 0..<200 where predictor.lastReview == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predictor.memory.text("strategies.md")?.text == "- In Xcode, open Snippets.\n")
        await predictor.refresh(context)?.value
        #expect(await jev.prompts["driver"]?.contains("- In Xcode, open Snippets.") == true)
        #expect(await codex.prompts["shadow"]?.contains("- In Xcode, open Snippets.") == true)
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
        // Settings saved before these knobs existed, or while Luna drove, must keep the owner's choices.
        let saved = try JSONDecoder().decode(PredictionConfig.self, from: Data(#"{"useModel":false,"driverModel":"gpt-x","driverEffort":"low"}"#.utf8))
        #expect(!saved.useModel && saved.threadTurns == 40 && saved.lunaModel == "gpt-x" && saved.lunaEffort == "low" && saved.enabled)
    }

    /// Seam: Luna's shadow calls ↔ the kept Codex thread, across relaunches. Catches a thread re-sent the whole instruction,
    /// running totals logged as one turn's tokens, a thread id lost on relaunch, and a lost thread that never recovers.
    @Test func lunaResumesOneThreadAndStartsOverWhenItIsLost() async throws {
        let codex = FakeRunner(["shadow": .success(#"{"kind":"text","hint":"any","confidence":0.5,"note":"n"}"#)])
        let jev = FakeRunner(["driver": .success(#"{"kind":"text","hint":"any","confidence":0.5,"note":"n"}"#)])
        let context = context()
        let memory = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        func launch() async -> SectionPredictor {
            let predictor = makePredictor(jev, context, memory, codex: codex).0
            await predictor.start()
            await predictor.refresh(context)?.value
            return predictor
        }
        #expect(await launch().thread?.id == "t1")
        #expect(await codex.prompts["shadow"]?.contains("Kinds they can reach now") == true)
        let relaunched = await launch()
        let turn = relaunched.calls.last { $0.purpose == "shadow" }
        #expect(await codex.prompts["shadow"]?.hasPrefix("## Since your last pick") == true)
        #expect(turn?.thread == "t1" && turn?.turn == 2 && turn?.tokens?.input == 10)
        await codex.forget("t1")
        #expect(await launch().thread == nil)
        #expect(await launch().thread?.id == "t2")
        #expect(await codex.prompts["shadow"]?.contains("Kinds they can reach now") == true)
    }

    private func context(screenshotAge: Int? = nil, kinds: [IntentKind] = IntentKind.allCases) -> PredictionContext {
        PredictionContext(hour: 10, weekday: "Thu", app: "com.apple.dt.Xcode", screenshotAge: screenshotAge, kinds: kinds)
    }

    /// Without a Codex runner given, Codex is "not found", so Luna stays quiet.
    private func makePredictor(_ jev: FakeRunner, _ context: PredictionContext,
                               _ memory: DataStore = DataStore(directory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString)), codex: FakeRunner = FakeRunner([:], path: nil)) -> (SectionPredictor, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return (SectionPredictor(settings: settings, memory: memory, driver: jev, codex: codex, probe: { _, _ in nil }) { context }, settings)
    }
}

actor FakeRunner: ModelRunner {
    let replies: [String: Result<String, ModelError>]
    let path: String?
    var prompts: [String: String] = [:]
    /// Kept threads and their turn counts, like Codex's stored sessions.
    var threads: [String: Int] = [:], made = 0
    /// While held, calls wait for `release`, like a slow network.
    private var holding = false, held: [CheckedContinuation<Void, Never>] = []

    init(_ replies: [String: Result<String, ModelError>], path: String? = "/fake/codex") { self.replies = replies; self.path = path }

    func codexPath() async -> String? { path }
    func run(_ call: ModelCall) async throws -> ModelReply {
        prompts[call.purpose] = call.prompt
        if holding { await withCheckedContinuation { held.append($0) } }
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
    func hold() { holding = true }
    func release() { holding = false; held.forEach { $0.resume() }; held = [] }
}
