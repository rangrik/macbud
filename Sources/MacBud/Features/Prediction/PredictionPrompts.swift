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
        + "older = an earlier one they will look for; any = no guess. "
        + "For app you may instead name one app from runningApps by bundle id."

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

        Pick one kind and a hint. `app`: a bundle id for kind app, else "". `note`: one short sentence on why, for the reviewer.
        Later messages here carry only what changed since your last pick; answer each the same way.
        """
    }

    /// A later turn in the driver's thread: only what happened after `last`.
    static func delta(context: PredictionContext, since last: Date, sessions: [SessionRecord], events: [EventRecord],
                      strategies: String, written: Date?) -> String {
        let news = sessions.filter { $0.hit != nil && $0.t + ($0.secs ?? 0) > last }.map(line) + added(events, since: last)
        let rewritten = (written ?? .distantPast) > last ? "\n## New strategies from the reviewer (they replace the earlier ones)\n\(strategies)\n" : ""
        return """
        ## Since your last pick
        \(news.isEmpty ? "Nothing new." : news.joined(separator: "\n"))
        \(rewritten)
        ## Now
        Fallback rule would pick: \(context.heuristic.map(describe) ?? "none")
        \(json(context))
        """
    }

    /// Items added after `last`, once each: an item shows up in every event until a newer one replaces it.
    private static func added(_ events: [EventRecord], since last: Date) -> [String] {
        var seen: [String: Date] = [:], lines: [(Date, String)] = []
        for event in events {
            let c = event.context
            for (kind, age, text) in [("clip", c.clipboardAge, "copied \(c.clipboardKind ?? "something") from \(c.clipboardSource ?? "an unknown app")"),
                                      ("shot", c.screenshotAge, c.screenshotKind == "video" ? "saved a screen recording" : "saved a screenshot"),
                                      ("dictation", c.dictationAge, "dictated")] {
                guard let age else { continue }
                let at = event.t - Double(age)
                guard at > last, abs(at.timeIntervalSince(seen[kind] ?? .distantPast)) > 2 else { continue }
                seen[kind] = at
                lines.append((at, at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) + " " + text))
            }
        }
        return lines.sorted { $0.0 < $1.0 }.suffix(20).map(\.1)
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

    /// Jev takes a block of state and typed questions, not a prompt. Ages become words because it reads numbers as text.
    static func jev(context: PredictionContext, strategies: String, recent: [SessionRecord], model: String) -> String {
        func age(_ s: Int?) -> String {
            guard let s else { return "never" }
            return switch s {
            case ..<15: "seconds ago"
            case ..<60: "under a minute ago"
            case ..<300: "1 to 5 minutes ago"
            case ..<1800: "5 to 30 minutes ago"
            case ..<7200: "30 minutes to 2 hours ago"
            case ..<28_800: "2 to 8 hours ago"
            default: "more than 8 hours ago"
            }
        }
        func short(_ bundle: String?) -> String { bundle?.split(separator: ".").last.map(String.init) ?? "unknown" }
        func open(_ s: SessionRecord) -> String {
            let c = s.context
            let used = s.outcome.map { $0.kind.rawValue + ($0.newest.map { $0 ? " (newest)" : " (older)" } ?? "") + ($0.app.map { " " + short($0) } ?? "") }
            return "\(s.t.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())) · front app \(short(c.app))"
                + " · latest copy \(c.clipboardKind ?? "none") \(age(c.clipboardAge)) · screenshot \(age(c.screenshotAge))"
                + " · dictation \(age(c.dictationAge)) → used \(used ?? "nothing")"
        }
        let hour = context.hour
        var state: [String: Any] = [
            "now": ["weekday": context.weekday, "hour": String(format: "%02d:00", hour),
                    "part_of_day": hour < 6 ? "night" : hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening"],
            "front_app": ["bundle_id": context.app ?? "unknown", "name": short(context.app)],
            "latest_clipboard_item": ["kind": context.clipboardKind ?? "none", "copied_from": short(context.clipboardSource),
                                      "copied": age(context.clipboardAge)],
            "latest_screenshot": ["kind": context.screenshotKind ?? "none", "saved": age(context.screenshotAge)],
            "latest_dictation": ["finished": age(context.dictationAge)],
            "recent_opens_oldest_first": recent.isEmpty ? ["none yet"] : recent.map(open),
        ]
        if let previous = context.previousApp { state["previous_app"] = short(previous) }
        if let running = context.runningApps { state["running_apps"] = running.map { short($0) } }
        if !strategies.isEmpty { state["rules_written_by_a_reviewer_from_past_misses"] = strategies }
        let questions: [String: Any] = [
            "kind": ["type": "choice",
                     "instructions": "The owner of a Mac utility just pressed its open key. Which kind of item are they most likely "
                         + "reaching for right now? Weigh `front_app`, how recently each item arrived, and `recent_opens_oldest_first`.",
                     "criteria": Dictionary(uniqueKeysWithValues: context.kinds.map { ($0.rawValue, meanings[$0] ?? "") })],
            "which_item": ["type": "choice",
                           "instructions": "Within the kind they are reaching for, do they want the most recent item of that kind, "
                               + "or an earlier one they will search for?",
                           "criteria": ["newest": "the most recent item of that kind (for an app: the window they just left)",
                                        "older": "an earlier item of that kind that they will look for",
                                        "either": "nothing here says which; they will pick either way"]],
        ]
        let body: [String: Any] = ["model": model, "state": state, "questions": questions]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func driverSchema(_ kinds: [IntentKind]) -> String {
        schema(["kind": ["type": "string", "enum": kinds.map(\.rawValue)], "app": ["type": "string"],
                "hint": ["type": "string", "enum": ItemHint.allCases.map(\.rawValue)],
                "confidence": ["type": "number"], "note": ["type": "string"]])
    }

    static let reviewerSchema = schema(["strategies": ["type": "string"], "summary": ["type": "string"]])

    static func describe(_ intent: LandingIntent) -> String { "\(intent.kind.rawValue)/\(intent.hint.rawValue)" + (intent.app.map { " \($0)" } ?? "") }

    private static func line(_ s: SessionRecord) -> String {
        let time = s.t.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
        let used = s.outcome.map { $0.kind.rawValue + ($0.app.map { " \($0)" } ?? "") + ($0.newest.map { $0 ? " (newest)" : " (older)" } ?? "") } ?? "nothing"
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
    var app: String?

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
