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
                                                app: "com.apple.Safari", enabled: Section.allCases, now: now)
        let miss = SessionRecord(t: now, context: context, heuristic: .screenshots, opened: .screenshots, source: "heuristic",
                                 actual: .clipboard, hit: false)
        for prompt in [PredictionPrompts.driver(context: context, strategies: "", recent: [miss]),
                       PredictionPrompts.reviewer(strategies: "", misses: [miss], hits: [], rates: "")] {
            for secret in ["hunter2", "Private", "Plan.pdf", "secret", "4321"] { #expect(!prompt.contains(secret)) }
            #expect(prompt.contains("com.tinyspeck.slackmacgap") && prompt.contains(#""screenshotAge":20"#))
        }
    }

    /// Seam: runner failure → open path. Catches a broken CLI leaving the open without the rules' pick.
    @Test func failingRunnerLeavesTheRulesInCharge() async {
        let context = context(screenshotAge: 10)
        let (predictor, _) = makePredictor(FakeRunner(["driver": .failure(ModelError(message: "Not signed in"))]), context)
        await predictor.refresh(context)
        #expect(predictor.status == .failed("Not signed in"))
        #expect(predictor.calls.last?.status == "failed")
        #expect(predictor.sectionForOpen() == .screenshots)
    }

    /// Seam: `codex exec --json` output → reply, tokens and cached pick. Catches lost tokens, hidden errors and hidden tabs.
    @Test func codexOutputIsParsedAndChecked() async throws {
        let ok = #"""
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"section\":\"snippets\",\"confidence\":0.8,\"note\":\"n\"}"}}
        {"type":"turn.completed","usage":{"input_tokens":8946,"cached_input_tokens":0,"output_tokens":34,"reasoning_output_tokens":0}}
        """#
        let reply = try CodexRunner.parse(Data(ok.utf8), stderr: Data())
        #expect(reply.tokens == TokenUsage(input: 8946, output: 34))
        let failed = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"Model not supported\"}}"}}"#
        let error = #expect(throws: ModelError.self) { try CodexRunner.parse(Data(failed.utf8), stderr: Data()) }
        #expect(error?.message == "Model not supported")

        let all = context()
        let (predictor, _) = makePredictor(FakeRunner(["driver": .success(reply.text)]), all)
        await predictor.refresh(all)
        #expect(predictor.sectionForOpen() == .snippets)
        let noSnippets = context(enabled: [.clipboard, .screenshots])
        let (refusing, _) = makePredictor(FakeRunner(["driver": .success(reply.text)]), noSnippets)
        await refusing.refresh(noSnippets)
        #expect(refusing.calls.last?.status == "unusable")
        #expect(refusing.sectionForOpen() == .clipboard)
    }

    /// Seam: recorded misses → reviewer → strategies file → next driver prompt.
    /// Catches a reviewer that never fires, a strategies file that is not written, or a driver that never reads it.
    @Test func missesPastTheThresholdRewriteWhatTheDriverReads() async throws {
        let runner = FakeRunner(["driver": .success(#"{"section":"clipboard","confidence":0.5,"note":"n"}"#),
                                 "reviewer": .success(#"{"strategies":"- In Xcode, open Snippets.","summary":"s"}"#)])
        let context = context()
        let (predictor, settings) = makePredictor(runner, context)
        settings.prediction.missThreshold = 2
        for _ in 0..<2 {
            #expect(predictor.sectionForOpen() == .clipboard)
            predictor.noteAction("copy", in: .snippets)
            predictor.sessionEnded()
        }
        for _ in 0..<200 where predictor.lastReview == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predictor.memory.text("strategies.md")?.text == "- In Xcode, open Snippets.\n")
        await predictor.refresh(context)
        #expect(await runner.prompts["driver"]?.contains("- In Xcode, open Snippets.") == true)
        #expect(ReviewTrigger.isDue(misses: 1, since: .now - 12 * 3600, now: .now, threshold: 10, hours: 12))
    }

    private func context(screenshotAge: Int? = nil, enabled: [Section] = Section.allCases) -> PredictionContext {
        PredictionContext(hour: 10, weekday: "Thu", app: "com.apple.dt.Xcode", screenshotAge: screenshotAge, enabled: enabled)
    }

    private func makePredictor(_ runner: FakeRunner, _ context: PredictionContext) -> (SectionPredictor, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let memory = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (SectionPredictor(settings: settings, memory: memory, runner: runner) { context }, settings)
    }
}

private actor FakeRunner: ModelRunner {
    nonisolated let home = "test"
    let replies: [String: Result<String, ModelError>]
    var prompts: [String: String] = [:]

    init(_ replies: [String: Result<String, ModelError>]) { self.replies = replies }

    func blocker() async -> RunnerBlock? { nil }
    func codexPath() async -> String? { nil }
    func run(_ call: ModelCall) async throws -> ModelReply {
        prompts[call.purpose] = call.prompt
        return ModelReply(text: try (replies[call.purpose] ?? .failure(ModelError(message: "no reply"))).get(), tokens: TokenUsage(input: 10))
    }
}
