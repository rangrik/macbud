import SwiftUI

nonisolated enum Section: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboard, snippets, screenshots, dictationHistory, apps

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .snippets: "Snippets"
        case .screenshots: "Screenshots"
        case .dictationHistory: "History"
        case .apps: "Apps"
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .snippets: "text.badge.checkmark"
        case .screenshots: "photo.on.rectangle.angled"
        case .dictationHistory: "clock"
        case .apps: "square.grid.2x2"
        }
    }
    var searchPlaceholder: String { self == .dictationHistory ? "Search dictation history…" : "Search \(title.lowercased())…" }
    var index: Int { Section.allCases.firstIndex(of: self) ?? 0 }
    var next: Section { Section.allCases[(index + 1) % Section.allCases.count] }
    var previous: Section { Section.allCases[(index + Section.allCases.count - 1) % Section.allCases.count] }
}

nonisolated enum NotchPhase: Equatable, Sendable { case collapsed, expanded, dictation }
nonisolated enum BasePhase: Equatable, Sendable { case idle, toast }

struct Toast: Equatable, Sendable {
    var symbol: String
    var title: String
    var subtitle: String? = nil
    var tint: Color = .green
}

/// Everything the island's views observe. Owned by `NotchController`.
@Observable
final class NotchState {
    var phase: NotchPhase = .collapsed
    /// Keep the last panel canvas during collapse; SwiftUI must never negotiate a new window size.
    var panelUsesDictationSize = false
    var basePhase: BasePhase = .idle
    var section: Section = .clipboard
    var query = ""
    var toast: Toast?
    var geometry: NotchGeometry
    var metrics = NotchMetrics()
    /// Mirrored into the search field's `@FocusState`.
    var wantsSearchFocus = false
    /// A transient hint shown in the footer (e.g. "press ⌘⇧⌫ again to clear").
    var footerHint: String?
    /// Draw a clickable tab with an icon beside the idle notch.
    var showsNotchTab = true
    /// Small status glyph shown in the idle tab (e.g. "pause.fill" while capture is paused).
    var notchStatusSymbol: String?
    var keepsAwake = false
    var tabHovered = false

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var isExpanded: Bool { phase == .expanded }
    var isDictating: Bool { phase == .dictation }
    var isOpen: Bool { phase != .collapsed }
}
