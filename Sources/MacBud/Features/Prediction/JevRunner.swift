import Foundation

/// TypeSafe's Jev answers typed questions instead of writing text, so the "prompt" is the request body itself.
actor JevRunner: ModelRunner {
    nonisolated static let keyFile = DataStore.default.directory.appendingPathComponent("typesafe-api-key")
    nonisolated static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    func codexPath() async -> String? {
        FileManager.default.fileExists(atPath: Self.keyFile.path) ? Self.keyFile.path : nil
    }

    func run(_ call: ModelCall) async throws -> ModelReply {
        let key = (try? String(contentsOf: Self.keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw ModelError(message: "No TypeSafe API key at \(Self.keyFile.path)") }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Double(call.timeout.components.seconds))
        request.httpMethod = "POST"
        request.httpBody = Data(call.prompt.utf8)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ModelError(message: "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))") }
        return try Self.normalize(data)
    }

    /// Jev's answers in the driver's reply shape, so one parser, ledger and Activity row serve both models.
    nonisolated static func normalize(_ data: Data) throws -> ModelReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any],
              let kind = answers["kind"] as? [String: Any], let choice = kind["choice"] as? String else {
            throw ModelError(message: "Jev gave no answers: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let item = answers["which_item"] as? [String: Any] ?? [:]
        let itemChoice = item["choice"] as? String ?? "either"
        let hint = itemChoice == "either" || (item["confidence"] as? Double ?? 0) < 0.5 ? "any" : itemChoice
        func top(_ answer: [String: Any]) -> String {
            (answer["probabilities"] as? [String: Double] ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }.joined(separator: ", ")
        }
        let reply: [String: Any] = ["kind": choice, "hint": hint, "confidence": kind["confidence"] as? Double ?? 0, "app": "",
                                    "note": "kind: \(top(kind)) · item: \(top(item))", "answers": answers]
        let usage = object["usage"] as? [String: Any] ?? [:]
        let text = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        return ModelReply(text: String(decoding: text, as: UTF8.self),
                          tokens: TokenUsage(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0))
    }
}
