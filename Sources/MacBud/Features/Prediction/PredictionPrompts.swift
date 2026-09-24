import Foundation

/// Builds what the models read. Only `PredictionContext` metadata and our own records go in.
nonisolated enum PredictionPrompts {
    static let instructions = "Reply with JSON only, matching the schema. You have no tools.\n"

    static let purposes: [Section: String] = [
        .clipboard: "things copied recently (text, links, images, files)",
        .snippets: "saved reusable text",
        .screenshots: "screenshots and screen recordings",
        .dictationHistory: "transcripts of past dictations",
        .apps: "switch to an app or window",
    ]

    static func driver(context: PredictionContext, strategies: String, recent: [SessionRecord]) -> String {
        """
        You predict which section of MacBud, a Mac notch utility, its owner wants when they press the open key.
        Sections:
        \(context.enabled.map { "- \($0.rawValue): \(purposes[$0] ?? "")" }.joined(separator: "\n"))

        ## Strategies (written by a reviewer who reads your misses)
        \(strategies.isEmpty ? "None yet." : strategies)

        ## Recent opens, oldest first
        \(recent.isEmpty ? "None yet." : recent.map(line).joined(separator: "\n"))

        ## Now
        Fallback rule would pick: \(context.heuristic?.rawValue ?? "none")
        \(json(context))

        Pick one section. `note`: one short sentence on why, for the reviewer.
        """
    }

    static func reviewer(strategies: String, misses: [SessionRecord], hits: [SessionRecord], rates: String) -> String {
        """
        You coach a small model that predicts which section of MacBud, a Mac notch utility, its owner wants when
        they press the open key. Read its misses and its notes, then rewrite the strategies it reads before every
        prediction. At most 40 lines of Markdown. Concrete rules of thumb that name apps, hours or signals.
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

    static func driverSchema(_ enabled: [Section]) -> String {
        schema(["section": ["type": "string", "enum": enabled.map(\.rawValue)], "confidence": ["type": "number"],
                "note": ["type": "string"]])
    }

    static let reviewerSchema = schema(["strategies": ["type": "string"], "summary": ["type": "string"]])

    private static func line(_ s: SessionRecord) -> String {
        let time = s.t.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
        let outcome = s.hit.map { $0 ? "hit" : "miss" } ?? "no action"
        return "\(time) · app \(s.context.app ?? "-") · opened \(s.opened.rawValue) (\(s.source)) · "
            + "heuristic \(s.heuristic?.rawValue ?? "-") · actual \(s.actual?.rawValue ?? "-") · \(outcome)"
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
    var section: Section
    var confidence: Double
    var note: String

    /// Nil unless the reply names a section the owner has enabled.
    static func parse(_ text: String, enabled: [Section]) -> DriverReply? {
        guard let reply = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)), enabled.contains(reply.section) else { return nil }
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
