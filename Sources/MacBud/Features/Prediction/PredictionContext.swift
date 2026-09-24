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
    var enabled: [Section]

    static func capture(clipboard: [ClipboardItem], media: [MediaItem], dictations: [DictationHistoryItem],
                        app: String?, enabled: [Section], now: Date = .now) -> PredictionContext {
        let clip = clipboard.max { $0.copiedAt < $1.copiedAt }
        let shot = media.max { $0.createdAt < $1.createdAt }
        let dictated = dictations.map(\.createdAt).max()
        func age(_ date: Date?) -> Int? { date.map { max(0, Int(now.timeIntervalSince($0))) } }
        let calendar = Calendar.current
        return PredictionContext(hour: calendar.component(.hour, from: now),
                                 weekday: calendar.shortWeekdaySymbols[calendar.component(.weekday, from: now) - 1],
                                 app: app, clipboardKind: clip?.kind.rawValue, clipboardSource: clip?.sourceBundleID,
                                 clipboardAge: age(clip?.copiedAt), screenshotKind: shot?.kind.rawValue,
                                 screenshotAge: age(shot?.createdAt), dictationAge: age(dictated), enabled: enabled)
    }

    /// Coarse on purpose, so a pick stays usable until something that matters changes.
    var key: String {
        func recent(_ age: Int?, _ flag: String) -> String { (age ?? .max) < 120 ? flag : "" }
        let flags = recent(clipboardAge, "c") + recent(screenshotAge, "s") + recent(dictationAge, "d")
        return [app ?? "-", String(hour), flags, clipboardKind ?? "-"].joined(separator: "|")
    }

    /// The pick that needs no model: a fresh screenshot or dictation, else Clipboard, else the first tab.
    var heuristic: Section? {
        let fresh = [(screenshotAge, Section.screenshots), (dictationAge, .dictationHistory)]
            .compactMap { age, section in age.map { (age: $0, section: section) } }
            .filter { $0.age < 60 && enabled.contains($0.section) }
        if let newest = fresh.min(by: { $0.age < $1.age }) { return newest.section }
        return enabled.contains(.clipboard) ? .clipboard : enabled.first
    }
}

/// The driver's cached answer for one context key.
nonisolated struct ModelPick: Codable, Equatable, Sendable {
    var section: Section
    var confidence: Double
    var note: String
    var key: String
    var madeAt: Date
}

/// One plain open of the island: what we chose, and where the owner ended up.
nonisolated struct SessionRecord: Codable, Identifiable, Sendable {
    var t: Date
    var context: PredictionContext
    var heuristic: Section?
    var model: ModelPick?
    var opened: Section
    var source: String
    var actual: Section?
    var action: String?
    var secs: Double?
    /// Nil when the owner neither acted nor switched, so there is nothing to score.
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
    var home: String
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
