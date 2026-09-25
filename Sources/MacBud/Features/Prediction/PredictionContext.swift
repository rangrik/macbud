import Foundation

/// What the models may see about a moment. Metadata only: no text, file names, paths or window titles.
nonisolated struct PredictionContext: Codable, Equatable, Sendable {
    var hour: Int
    var weekday: String
    var app: String?
    var clipboardKind: String?
    var clipboardSource: String?
    var clipboardAge: Int?
    var screenshotKind: String?
    var screenshotAge: Int?
    var dictationAge: Int?
    /// Kinds the owner can reach now; hidden features drop out.
    var kinds: [IntentKind]

    static func capture(clipboard: [ClipboardItem], media: [MediaItem], dictations: [DictationHistoryItem],
                        app: String?, kinds: [IntentKind], now: Date = .now) -> PredictionContext {
        let clip = clipboard.max { $0.copiedAt < $1.copiedAt }
        let shot = media.max { $0.createdAt < $1.createdAt }
        let dictated = dictations.map(\.createdAt).max()
        func age(_ date: Date?) -> Int? { date.map { max(0, Int(now.timeIntervalSince($0))) } }
        let calendar = Calendar.current
        return PredictionContext(hour: calendar.component(.hour, from: now),
                                 weekday: calendar.shortWeekdaySymbols[calendar.component(.weekday, from: now) - 1],
                                 app: app, clipboardKind: clip?.kind.rawValue, clipboardSource: clip?.sourceBundleID,
                                 clipboardAge: age(clip?.copiedAt), screenshotKind: shot?.kind.rawValue,
                                 screenshotAge: age(shot?.createdAt), dictationAge: age(dictated),
                                 kinds: kinds)
    }

    /// Coarse on purpose, so a pick stays usable until something that matters changes.
    var key: String {
        func recent(_ age: Int?, _ flag: String) -> String { (age ?? .max) < 120 ? flag : "" }
        let flags = recent(clipboardAge, "c") + recent(screenshotAge, "s") + recent(dictationAge, "d")
        return [app ?? "-", String(hour), flags, clipboardKind ?? "-"].joined(separator: "|")
    }

    /// The pick that needs no model: a screenshot or dictation from the last minute, else text.
    var heuristic: LandingIntent? {
        let fresh = [(screenshotAge, IntentKind.screenshot), (dictationAge, .dictation)]
            .compactMap { age, kind in age.map { (age: $0, kind: kind) } }
            .filter { $0.age < 60 && kinds.contains($0.kind) }
        if let newest = fresh.min(by: { $0.age < $1.age }) { return LandingIntent(kind: newest.kind, hint: .newest) }
        return (kinds.contains(.text) ? .text : kinds.first).map { LandingIntent(kind: $0) }
    }
}

/// The driver's cached answer for one context key.
nonisolated struct ModelPick: Codable, Equatable, Sendable {
    var intent: LandingIntent
    var note: String
    var key: String
    var madeAt: Date
}

/// One plain open of the island: what we predicted, and what the owner used.
nonisolated struct SessionRecord: Codable, Identifiable, Sendable {
    var t: Date
    var context: PredictionContext
    var heuristic: LandingIntent?
    var model: ModelPick?
    var landed: LandingIntent
    var source: String
    /// Where the open landed and where the owner acted: "shelf" or a chip. Older records name tabs.
    var opened: String
    var actedIn: String?
    var outcome: Outcome?
    var action: String?
    var secs: Double?
    /// Nil when the owner used nothing, so there is nothing to score.
    var hit: Bool?
    var id: Date { t }
}

nonisolated struct TokenUsage: Codable, Equatable, Sendable {
    var input = 0, cached = 0, output = 0, reasoning = 0
}

/// One model call, kept whole so the owner can read exactly what was sent and received.
nonisolated struct CallRecord: Codable, Identifiable, Sendable {
    var t: Date
    var purpose: String
    var model: String
    var effort: String
    var ms = 0
    var status = "ok"
    var error: String?
    var tokens: TokenUsage?
    var prompt: String
    var reply: String?
    var id: Date { t }
}

nonisolated struct EventRecord: Codable, Sendable {
    var t: Date
    var context: PredictionContext
}
