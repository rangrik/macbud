import SwiftUI

nonisolated enum Section: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboard, snippets, screenshots

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .snippets: "Snippets"
        case .screenshots: "Screenshots"
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .snippets: "text.badge.checkmark"
        case .screenshots: "photo.on.rectangle.angled"
        }
    }
    var searchPlaceholder: String { "Search \(title.lowercased())…" }
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
    var tabHovered = false

    init(geometry: NotchGeometry) { self.geometry = geometry }

    var isExpanded: Bool { phase == .expanded }
    var isDictating: Bool { phase == .dictation }
    var isOpen: Bool { phase != .collapsed }
}
