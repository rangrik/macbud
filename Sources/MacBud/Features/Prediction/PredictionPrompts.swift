import Foundation

/// Builds what the models read. Only `PredictionContext` metadata and our own records go in, and no tab names.
nonisolated enum PredictionPrompts {
    static let instructions = "Reply with JSON only, matching the schema. You have no tools.\n"

    static let meanings: [IntentKind: String] = [
        .text: "text they copied", .link: "a link they copied", .image: "an image they copied",
        .screenshot: "a screenshot or screen recording saved to disk", .dictation: "the transcript of a dictation",
        .snippet: "a saved piece of reusable text", .app: "an app or window to switch to",
    ]

    static let hints = "Hint: newest = the most recent item of that kind (for app, the window of the app they just left); "
        + "older = an earlier one they will look for; any = no guess."

    static func driver(context: PredictionContext, strategies: String, recent: [SessionRecord]) -> String {
        """
        You predict what the owner of MacBud, a Mac notch utility, wants to reach when they press its open key.
        Kinds they can reach now:
        \(context.kinds.map { "- \($0.rawValue): \(meanings[$0] ?? "")" }.joined(separator: "\n"))
        \(hints)

        ## Strategies (written by a reviewer who reads your misses)
        \(strategies.isEmpty ? "None yet." : strategies)

        ## Recent opens, oldest first
        \(recent.isEmpty ? "None yet." : recent.map(line).joined(separator: "\n"))

        ## Now
        Fallback rule would pick: \(context.heuristic.map(describe) ?? "none")
        \(json(context))

        Pick one kind and a hint. `note`: one short sentence on why, for the reviewer.
        """
    }

    static func reviewer(strategies: String, misses: [SessionRecord], hits: [SessionRecord], rates: String) -> String {
        """
        You coach a small model that predicts what the owner of MacBud, a Mac notch utility, wants to reach when
        they press its open key: a kind (\(IntentKind.allCases.map(\.rawValue).joined(separator: ", "))) and a hint.
        \(hints)
        A miss means they used a different kind, or the newest-or-older guess was wrong.
        Read its misses and its notes, then rewrite the strategies it reads before every prediction.
        At most 40 lines of Markdown. Concrete rules of thumb that name apps, hours or signals.
        Keep what still holds, drop what the misses contradict. Use only the metadata you see here.

        ## Current strategies
        \(strategies.isEmpty ? "None yet." : strategies)

        ## Hit rates, last 7 days
        \(rates)

        ## Misses since the last review
        \(misses.map { "- \(line($0))\n  context: \(json($0.context))\n  driver note: \($0.model?.note ?? "none (fallback rule was used)")" }.joined(separator: "\n"))

        ## Recent hits
        \(hits.isEmpty ? "None." : hits.map(line).joined(separator: "\n"))

        `strategies`: the full new text. `summary`: one line on what changed.
        """
    }

    static func driverSchema(_ kinds: [IntentKind]) -> String {
        schema(["kind": ["type": "string", "enum": kinds.map(\.rawValue)],
                "hint": ["type": "string", "enum": ItemHint.allCases.map(\.rawValue)],
                "confidence": ["type": "number"], "note": ["type": "string"]])
    }

    static let reviewerSchema = schema(["strategies": ["type": "string"], "summary": ["type": "string"]])

    static func describe(_ intent: LandingIntent) -> String { "\(intent.kind.rawValue)/\(intent.hint.rawValue)" }

    private static func line(_ s: SessionRecord) -> String {
        let time = s.t.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
        let used = s.outcome.map { $0.kind.rawValue + ($0.newest.map { $0 ? " (newest)" : " (older)" } ?? "") } ?? "nothing"
        return "\(time) · app \(s.context.app ?? "-") · predicted \(describe(s.landed)) by \(s.source == "model" ? "you" : "the fallback rule")"
            + " · rule said \(s.heuristic.map(describe) ?? "-") · used \(used) · \(s.hit.map { $0 ? "hit" : "miss" } ?? "unscored")"
    }

    private static func json(_ context: PredictionContext) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(context)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func schema(_ properties: [String: [String: Any]]) -> String {
        let object: [String: Any] = ["type": "object", "additionalProperties": false,
                                     "required": properties.keys.sorted(), "properties": properties]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// What the driver answers.
nonisolated struct DriverReply: Decodable, Sendable {
    var kind: IntentKind
    var hint: ItemHint
    var confidence: Double
    var note: String

    /// Nil unless the reply names a kind the owner can reach now.
    static func parse(_ text: String, kinds: [IntentKind]) -> DriverReply? {
        guard let reply = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)), kinds.contains(reply.kind) else { return nil }
        return reply
    }
}

/// What the reviewer answers.
nonisolated struct ReviewerReply: Decodable, Sendable {
    var strategies: String
    var summary: String

    static func parse(_ text: String) -> ReviewerReply? {
        guard var reply = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              !reply.strategies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        reply.strategies = reply.strategies.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).joined(separator: "\n")
        return reply
    }
}
