import Foundation

nonisolated struct ModelCall: Sendable {
    var purpose: String
    var model: String
    var effort: String
    var prompt: String
    var schema: String
    var timeout: Duration
    /// Store the session so later calls can resume it; `thread` names the one to resume.
    var keepThread = false
    var thread: String?
}

nonisolated struct ModelReply: Sendable {
    var text: String
    /// On a resumed thread Codex reports the thread's running total, not this turn's.
    var tokens: TokenUsage
    var thread: String?
}

nonisolated struct ModelError: LocalizedError, Sendable {
    var message: String
    var threadGone = false
    var errorDescription: String? { message }
}

nonisolated protocol ModelRunner: Sendable {
    /// Nil when the Codex CLI cannot be found.
    func codexPath() async -> String?
    func run(_ call: ModelCall) async throws -> ModelReply
}

/// Runs `codex exec` on MacBud's own Codex login when signed in, else ephemerally on the owner's, so nothing lands
/// in their Codex history. `--ignore-user-config` keeps their MCP servers and settings out.
actor CodexRunner: ModelRunner {
    private var located: (executable: URL, path: String)?
    private var lastLookup = Date.distantPast

    /// Tools the models must not have; `-c` form because unknown names are ignored there.
    private nonisolated static let disabledFeatures = ["apps", "browser_use", "computer_use", "goals", "hooks", "image_generation",
                                                       "memories", "multi_agent", "plugins", "shell_tool", "skill_search",
                                                       "tool_suggest", "unified_exec", "view_image"]

    /// MacBud's own Codex login, so its stored sessions never mix with the owner's history.
    nonisolated static let home = DataStore.default.directory.appendingPathComponent("codex", isDirectory: true)
    nonisolated static var signedIn: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) }

    func codexPath() async -> String? { await locate()?.executable.path }

    func run(_ call: ModelCall) async throws -> ModelReply {
        guard let codex = await locate() else { throw ModelError(message: "Codex CLI not found in your login shell") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in ["prompt.txt": call.prompt, "schema.json": call.schema, "instructions.md": PredictionPrompts.instructions] {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
        let own = Self.signedIn, keep = call.keepThread && own
        let resume = keep ? call.thread : nil
        if call.thread != nil, !keep { throw ModelError(message: "MacBud's Codex sign-in is gone", threadGone: true) }
        var args = ["exec"] + (resume == nil ? [] : ["resume"]) + (keep ? [] : ["--ephemeral"])
        args += ["--ignore-user-config", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\"",
                 "-m", call.model, "-c", "model_reasoning_effort=\(call.effort)",
                 "-c", "model_instructions_file=\"\(dir.appendingPathComponent("instructions.md").path)\"",
                 "-c", "include_environment_context=false", "-c", "include_permissions_instructions=false",
                 "-c", "web_search=disabled"]
        args += Self.disabledFeatures.flatMap { ["-c", "features.\($0)=false"] }
        args += ["--output-schema", dir.appendingPathComponent("schema.json").path, "--json"] + (resume.map { [$0] } ?? []) + ["-"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = codex.path
        if own { env["CODEX_HOME"] = Self.home.path }
        // A fixed folder for kept threads, so every turn of a thread runs in the same place.
        let result = try await Self.execute(codex.executable, args, env: env, cwd: keep ? Self.home : dir,
                                            input: dir.appendingPathComponent("prompt.txt"), timeout: call.timeout)
        if result.timedOut { throw ModelError(message: "Timed out after \(call.timeout)") }
        do {
            var reply = try Self.parse(result.out, stderr: result.err)
            if !keep { reply.thread = nil }  // an ephemeral thread cannot be resumed
            return reply
        } catch var error as ModelError {
            // A resume that never reports its thread could not open it: the session is gone.
            error.threadGone = resume != nil && result.out.range(of: Data(#""thread.started""#.utf8)) == nil
            throw error
        }
    }

    /// GUI apps do not get the owner's shell PATH, so ask their login shell once, like their terminal would.
    private func locate() async -> (executable: URL, path: String)? {
        if let located { return located }
        guard Date.now.timeIntervalSince(lastLookup) > 300 else { return nil }
        lastLookup = .now
        let shell = try? await Self.execute(URL(fileURLWithPath: "/bin/zsh"), ["-lic", "command -v codex; command -v node"],
                                            env: ProcessInfo.processInfo.environment, cwd: FileManager.default.temporaryDirectory,
                                            input: nil, timeout: .seconds(10))
        let lines = String(decoding: shell?.out ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
        func real(_ name: String) -> URL? {
            lines.last { $0.hasPrefix("/") && $0.hasSuffix("/" + name) }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        }
        guard let codex = real("codex") else { return nil }
        let dirs = [real("node"), codex].compactMap { $0?.deletingLastPathComponent().path } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        located = (codex, dirs.joined(separator: ":"))
        return located
    }

    /// Output goes to files, not pipes, so a chatty process can never block on a full buffer.
    nonisolated static func execute(_ executable: URL, _ arguments: [String], env: [String: String], cwd: URL,
                                    input: URL?, timeout: Duration) async throws -> (out: Data, err: Data, timedOut: Bool) {
        let tmp = FileManager.default.temporaryDirectory
        let out = tmp.appendingPathComponent("macbud-\(UUID().uuidString).out"), err = out.appendingPathExtension("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: err) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = cwd
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        // Poll, never `waitUntilExit()`: on a concurrency thread it can wait forever for a run-loop message.
        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        while process.isRunning {
            if !timedOut, ContinuousClock.now > deadline { timedOut = true; process.terminate() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (try Data(contentsOf: out), try Data(contentsOf: err), timedOut)
    }

    /// Reads `codex exec --json` events: the last agent message is the reply, `turn.completed` has the tokens.
    nonisolated static func parse(_ out: Data, stderr: Data) throws -> ModelReply {
        var text: String?, thread: String?, failure: String?, tokens = TokenUsage()
        for line in out.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "thread.started":
                thread = event["thread_id"] as? String
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" { text = item["text"] as? String }
            case "turn.completed":
                let usage = event["usage"] as? [String: Any] ?? [:]
                tokens = TokenUsage(input: usage["input_tokens"] as? Int ?? 0, cached: usage["cached_input_tokens"] as? Int ?? 0,
                                    output: usage["output_tokens"] as? Int ?? 0, reasoning: usage["reasoning_output_tokens"] as? Int ?? 0)
            case "turn.failed":
                failure = (event["error"] as? [String: Any])?["message"] as? String
            case "error":
                failure = failure ?? event["message"] as? String
            default: break
            }
        }
        if let text { return ModelReply(text: text, tokens: tokens, thread: thread) }
        let lastError = String(decoding: stderr, as: UTF8.self).split(separator: "\n").last.map(String.init)
        throw ModelError(message: readable(failure ?? lastError ?? "Codex gave no reply"))
    }

    /// API errors arrive as JSON inside the message; show the inner sentence.
    private nonisolated static func readable(_ message: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let inner = (object["error"] as? [String: Any])?["message"] as? String else { return message }
        return inner
    }
}
