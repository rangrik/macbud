import Foundation

nonisolated struct ModelCall: Sendable {
    var purpose: String
    var model: String
    var effort: String
    var prompt: String
    var schema: String
    var timeout: Duration
}

nonisolated struct ModelReply: Sendable {
    var text: String
    var tokens: TokenUsage
}

nonisolated struct ModelError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// Why calls cannot run right now.
nonisolated enum RunnerBlock: Equatable, Sendable { case missingCLI, notSignedIn }

nonisolated protocol ModelRunner: Sendable {
    /// "macbud" for MacBud's own Codex home, "shared" for the QA-only ~/.codex path.
    var home: String { get }
    func blocker() async -> RunnerBlock?
    func codexPath() async -> String?
    func run(_ call: ModelCall) async throws -> ModelReply
}

/// Runs `codex exec` with MacBud's own Codex home, so sessions and logins stay apart from the owner's.
actor CodexRunner: ModelRunner {
    nonisolated let home: String
    nonisolated let directory: URL
    private var located: (executable: URL, path: String)?
    private var lastLookup = Date.distantPast

    nonisolated static let signInCommand = #"CODEX_HOME="$HOME/Library/Application Support/MacBud/codex" codex login --device-auth"#
    /// Tools the models must not have; `-c` form because unknown names are ignored there.
    private nonisolated static let disabledFeatures = ["apps", "browser_use", "computer_use", "goals", "hooks", "image_generation",
                                           "memories", "multi_agent", "plugins", "shell_tool", "skill_search",
                                           "tool_suggest", "unified_exec", "view_image"]

    init(directory: URL = DataStore.default.directory.appendingPathComponent("codex", isDirectory: true),
         shared: Bool = ProcessInfo.processInfo.environment["MACBUD_CODEX_SHARED_HOME"] == "1") {
        self.directory = directory
        home = shared ? "shared" : "macbud"
    }

    func blocker() async -> RunnerBlock? {
        prepare()
        guard await locate() != nil else { return .missingCLI }
        let signedIn = home == "shared" || FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path)
        return signedIn ? nil : .notSignedIn
    }

    func codexPath() async -> String? { await locate()?.executable.path }

    func run(_ call: ModelCall) async throws -> ModelReply {
        guard let codex = await locate() else { throw ModelError(message: "Codex CLI not found in your login shell") }
        let schema = directory.appendingPathComponent("\(call.purpose).schema.json")
        let prompt = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-\(UUID().uuidString).prompt")
        try Data(call.schema.utf8).write(to: schema, options: .atomic)
        try Data(call.prompt.utf8).write(to: prompt)
        defer { try? FileManager.default.removeItem(at: prompt) }
        var args = ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "-s", "read-only",
                    "-m", call.model, "-c", "model_reasoning_effort=\(call.effort)",
                    "-c", "model_instructions_file=\"\(directory.appendingPathComponent("instructions.md").path)\"",
                    "-c", "include_environment_context=false", "-c", "include_permissions_instructions=false",
                    "-c", "web_search=disabled"]
        args += Self.disabledFeatures.flatMap { ["-c", "features.\($0)=false"] }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = codex.path
        if home == "shared" {
            env.removeValue(forKey: "CODEX_HOME")
        } else {
            env["CODEX_HOME"] = directory.path
            args += ["-c", "cli_auth_credentials_store=\"file\""]
        }
        args += ["--output-schema", schema.path, "--json", "-"]
        let result = try await Self.execute(codex.executable, args, env: env, cwd: directory, input: prompt, timeout: call.timeout)
        if result.timedOut { throw ModelError(message: "Timed out after \(call.timeout)") }
        return try Self.parse(result.out, stderr: result.err)
    }

    /// Writes the files `codex login` and `codex exec` need, so the sign-in command works before any call.
    private func prepare() {
        let files = ["instructions.md": PredictionPrompts.instructions,
                     "config.toml": "# Written by MacBud: keep this home's login in auth.json here.\ncli_auth_credentials_store = \"file\"\n"]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            let url = directory.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try? Data(text.utf8).write(to: url, options: .atomic) }
        }
    }

    /// GUI apps do not get the owner's shell PATH, so ask their login shell once, like their terminal would.
    private func locate() async -> (executable: URL, path: String)? {
        if let located { return located }
        guard Date.now.timeIntervalSince(lastLookup) > 300 else { return nil }
        lastLookup = .now
        let shell = try? await Self.execute(URL(fileURLWithPath: "/bin/zsh"), ["-lic", "command -v codex; command -v node"],
                                            env: ProcessInfo.processInfo.environment, cwd: directory, input: nil, timeout: .seconds(10))
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
        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        while process.isRunning {
            if ContinuousClock.now > deadline { timedOut = true; process.terminate(); break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        process.waitUntilExit()
        return (try Data(contentsOf: out), try Data(contentsOf: err), timedOut)
    }

    /// Reads `codex exec --json` events: the last agent message is the reply, `turn.completed` has the tokens.
    nonisolated static func parse(_ out: Data, stderr: Data) throws -> ModelReply {
        var text: String?, failure: String?, tokens = TokenUsage()
        for line in out.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch event["type"] as? String {
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
        if let text { return ModelReply(text: text, tokens: tokens) }
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
