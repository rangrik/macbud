import Foundation

/// One row of the Prediction Activity timeline.
nonisolated struct ActivityEntry: Identifiable, Sendable {
    enum Kind: Sendable { case driver, reviewer, open, hit, miss, capReached, error }

    var id: String
    var t: Date
    var kind: Kind
    var summary: String
    var call: CallRecord?
    var session: SessionRecord?
    /// For an open: the driver call whose pick it used.
    var linkedCall: CallRecord?
    /// For a driver call: the opens that used its pick.
    var linkedOpens: [SessionRecord] = []

    func matches(_ query: String) -> Bool {
        query.isEmpty || [summary, call?.prompt, call?.reply, session?.model?.note, session?.context.app]
            .contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

nonisolated enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", driver = "Driver", reviewer = "Reviewer", opens = "Opens", misses = "Misses", errors = "Errors"
    var id: Self { self }

    func includes(_ entry: ActivityEntry) -> Bool {
        switch self {
        case .all: true
        case .driver: entry.call?.purpose == "driver"
        case .reviewer: entry.call?.purpose == "reviewer"
        case .opens: entry.session != nil
        case .misses: entry.kind == .miss
        case .errors: entry.kind == .error || entry.kind == .capReached
        }
    }
}

/// One expandable part of a row. `link` names another row to jump to.
nonisolated struct ActivityDetail: Sendable {
    var title: String
    var text: String
    var isCode = false
    var diff: [DiffLine]?
    var link: String?
}

nonisolated enum DiffLine: Equatable, Sendable { case same(String), added(String), removed(String) }

nonisolated enum PredictionActivity {
    /// Newest first. An open gets a second row for its outcome, linked to the driver call behind its pick.
    static func timeline(calls: [CallRecord], sessions: [SessionRecord], cap: Int) -> [ActivityEntry] {
        var seen = Set<String>(), entries: [ActivityEntry] = [], opensByCall: [Date: [SessionRecord]] = [:]
        // Times are stored to the second, so two opens can share one.
        func id(_ base: String, _ t: Date) -> String {
            var id = "\(base) \(t.timeIntervalSince1970)"
            while !seen.insert(id).inserted { id += "+" }
            return id
        }
        let drivers = calls.filter { $0.purpose == "driver" && $0.status == "ok" }
        for s in sessions {
            // A pick is cached for a while, so match the call that made it, not the call nearest the open.
            let call = s.model.flatMap { pick in drivers.last { $0.t <= pick.madeAt } }
            if let call { opensByCall[call.t, default: []].append(s) }
            entries.append(ActivityEntry(id: id("open", s.t), t: s.t, kind: .open, summary: openSummary(s), session: s, linkedCall: call))
            guard let outcome = s.outcome, let hit = s.hit else { continue }
            entries.append(ActivityEntry(id: id("outcome", s.t), t: s.t + (s.secs ?? 0), kind: hit ? .hit : .miss,
                                         summary: "\(hit ? "Hit" : "Miss"): opened on \(describe(s.landed)), used \(describe(outcome))",
                                         session: s, linkedCall: call))
        }
        var perDay: [Date: Int] = [:]
        for c in calls {
            let kind: ActivityEntry.Kind = c.status != "ok" ? .error : c.purpose == "reviewer" ? .reviewer : .driver
            entries.append(ActivityEntry(id: Self.id(of: c), t: c.t, kind: kind, summary: callSummary(c), call: c,
                                         linkedOpens: opensByCall[c.t] ?? []))
            let day = Calendar.current.startOfDay(for: c.t)
            perDay[day, default: 0] += 1
            if perDay[day] == cap {
                entries.append(ActivityEntry(id: id("cap", c.t), t: c.t + Double(c.ms) / 1000, kind: .capReached,
                                             summary: "Daily cap of \(cap) calls reached: rules only until tomorrow"))
            }
        }
        // Later rows win ties, so an outcome sits above its open.
        return entries.enumerated().sorted { ($0.element.t, $0.offset) > ($1.element.t, $1.offset) }.map(\.element)
    }

    private static func id(of call: CallRecord) -> String { "call \(call.t.timeIntervalSince1970)" }

    /// Calls and tokens per model today; Settings and the Activity window show the same numbers.
    /// Cached input is counted apart because it is billed at a fraction of the rest.
    static func usageToday(_ calls: [CallRecord]) -> [(model: String, calls: Int, tokens: Int, cached: Int)] {
        Dictionary(grouping: calls.filter { Calendar.current.isDateInToday($0.t) }, by: \.model)
            .map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + ($1.tokens?.input ?? 0) + ($1.tokens?.output ?? 0) },
                    $0.value.reduce(0) { $0 + ($1.tokens?.cached ?? 0) }) }
            .sorted { $0.model < $1.model }
    }

    static func details(_ entry: ActivityEntry) -> [ActivityDetail] {
        var out: [ActivityDetail] = []
        if let s = entry.session {
            let used = s.outcome.map { "Used \(describe($0)) (\(s.action ?? "?") in \(s.actedIn ?? "?"), after \(s.secs ?? 0) s): \(s.hit == true ? "hit" : "miss")" }
            out.append(ActivityDetail(title: "Outcome", text: used ?? "Used nothing, so this open is not scored."))
            out.append(ActivityDetail(title: "Prediction", text: """
                Landed on \(describe(s.landed)) in \(s.opened), picked by the \(s.source == "model" ? "model" : "rules").
                Rules said \(s.heuristic.map(describe) ?? "nothing"). Model said \(s.model.map { describe($0.intent) + String(format: ", %.2f", $0.intent.confidence) } ?? "nothing").
                """))
            if let note = s.model?.note { out.append(ActivityDetail(title: "Driver's note", text: note)) }
            out.append(ActivityDetail(title: "Context at open", text: pretty(try? JSONEncoder().encode(s.context)), isCode: true))
            if let c = entry.linkedCall {
                out.append(ActivityDetail(title: "Driver call behind the pick", text: "\(c.t.formatted(date: .abbreviated, time: .standard)) · \(callSummary(c))",
                                          link: id(of: c)))
            }
        }
        guard let c = entry.call else {
            if entry.kind == .capReached {
                out.append(ActivityDetail(title: "What happened", text: "MacBud stops calling Codex for the day at this cap, set in Settings → Prediction."))
            }
            return out
        }
        if let error = c.error { out.append(ActivityDetail(title: "Error", text: error)) }
        if let t = c.tokens {
            out.append(ActivityDetail(title: "Tokens", text: "\(t.input.formatted()) in (\(t.cached.formatted()) cached, \((t.input - t.cached).formatted()) new) · \(t.output.formatted()) out"))
        }
        if let thread = c.thread { out.append(ActivityDetail(title: "Codex thread", text: "\(thread), turn \(c.turn ?? 1)")) }
        let reply = (try? JSONSerialization.jsonObject(with: Data((c.reply ?? "").utf8))) as? [String: Any] ?? [:]
        if let note = reply["note"] as? String { out.append(ActivityDetail(title: "Driver's note", text: note)) }
        if c.purpose == "driver" {
            let context = c.prompt.split(separator: "\n").last { $0.hasPrefix("{") }
            out.append(ActivityDetail(title: "Context sent", text: pretty(context.map { Data($0.utf8) }), isCode: true))
        }
        if entry.kind == .driver {
            let opens = entry.linkedOpens.map { s in
                "\(s.t.formatted(date: .omitted, time: .standard)) · opened \(s.opened) on \(describe(s.landed)) · "
                    + (s.outcome.map { "used \(describe($0)), \(s.hit == true ? "hit" : "miss")" } ?? "used nothing")
            }
            out.append(ActivityDetail(title: "Opens that used this pick", text: opens.isEmpty ? "None yet." : opens.joined(separator: "\n")))
        }
        if let summary = reply["summary"] as? String { out.append(ActivityDetail(title: "Reviewer's summary", text: summary)) }
        if let change = strategiesChange(c) {
            let lines = diff(change.before, change.after)
            let text = lines.map { switch $0 { case .same(let l): "  " + l; case .added(let l): "+ " + l; case .removed(let l): "- " + l } }
            out.append(ActivityDetail(title: "Strategies, before → after", text: text.joined(separator: "\n"), isCode: true, diff: lines))
        }
        out.append(ActivityDetail(title: "Prompt sent to \(c.model) (\(c.effort))", text: c.prompt, isCode: true))
        out.append(ActivityDetail(title: "Reply", text: c.reply ?? "Nothing came back.", isCode: true))
        return out
    }

    /// Before comes from the reviewer's prompt and after from its reply, so older runs get a diff too.
    private static func strategiesChange(_ c: CallRecord) -> (before: String, after: String)? {
        guard c.purpose == "reviewer", let after = c.reply.flatMap(ReviewerReply.parse)?.strategies,
              let start = c.prompt.range(of: "## Current strategies\n"),
              let end = c.prompt.range(of: "\n\n## Hit rates", range: start.upperBound..<c.prompt.endIndex) else { return nil }
        let before = String(c.prompt[start.upperBound..<end.lowerBound])
        return (before == "None yet." ? "" : before.trimmingCharacters(in: .newlines), after.trimmingCharacters(in: .newlines))
    }

    /// Line diff through the longest common run of lines; removed lines come before added ones.
    private static func diff(_ old: String, _ new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n"), b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var common = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() { common[i][j] = a[i] == b[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1]) }
        }
        var i = 0, j = 0, out: [DiffLine] = []
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if i < a.count, j == b.count || common[i + 1][j] >= common[i][j + 1] { out.append(.removed(a[i])); i += 1 }
            else { out.append(.added(b[j])); j += 1 }
        }
        return out
    }

    static func markdown(_ entries: [ActivityEntry], scope: String) -> String {
        var md = "# MacBud prediction activity\n\n\(scope) · \(entries.count) rows · exported \(Date.now.formatted(date: .abbreviated, time: .shortened))\n"
        for entry in entries {
            md += "\n## \(entry.t.formatted(date: .abbreviated, time: .standard)) · \(entry.summary)\n"
            for d in details(entry) {
                md += "\n### \(d.title)\n\n"
                guard d.isCode else { md += d.text + "\n"; continue }
                // A fence longer than any run of backticks inside, so prompts that quote code stay whole.
                let fence = String(repeating: "`", count: max(3, (d.text.split { $0 != "`" }.map(\.count).max() ?? 0) + 1))
                md += "\(fence)\(d.diff == nil ? "" : "diff")\n\(d.text)\n\(fence)\n"
            }
        }
        return md
    }

    private static func describe(_ intent: LandingIntent) -> String { "\(intent.kind.rawValue) · \(intent.hint.rawValue)" }

    private static func describe(_ outcome: Outcome) -> String {
        outcome.kind.rawValue + (outcome.newest.map { $0 ? " · newest" : " · older" } ?? "")
    }

    private static func openSummary(_ s: SessionRecord) -> String {
        "Opened \(s.opened) on \(describe(s.landed)) (" + (s.source == "model" ? String(format: "model, %.2f", s.landed.confidence) : "rules") + ")"
    }

    private static func callSummary(_ c: CallRecord) -> String {
        let tokens = c.tokens.map { $0.input + $0.output }.map { $0 >= 1000 ? String(format: "%.1fk tokens", Double($0) / 1000) : "\($0) tokens" }
        let cost = [String(format: "%.1f s", Double(c.ms) / 1000), tokens].compactMap { $0 }.joined(separator: ", ")
        if c.status != "ok" { return "\(c.purpose.capitalized) \(c.status): \(c.error ?? "no reason given"), \(cost)" }
        if c.purpose == "reviewer" { return "Reviewer rewrote strategies, \(cost)" }
        let reply = (try? JSONSerialization.jsonObject(with: Data((c.reply ?? "").utf8))) as? [String: Any] ?? [:]
        // Replies before 0.8.0 named a section instead of a kind.
        let pick = [(reply["kind"] ?? reply["section"]) as? String, reply["hint"] as? String].compactMap { $0 }.joined(separator: " · ")
        let confidence = (reply["confidence"] as? Double).map { String(format: "%.2f", $0) }
        return "Driver said " + [pick.isEmpty ? "?" : pick, confidence, cost].compactMap { $0 }.joined(separator: ", ")
    }

    private static func pretty(_ json: Data?) -> String {
        guard let json, let object = try? JSONSerialization.jsonObject(with: json),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "Not recorded." }
        return String(decoding: data, as: UTF8.self)
    }
}
