import SwiftUI

/// A filter over the shelf. One fixed order, so ⌘1…⌘8 never move.
nonisolated enum Chip: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, text, links, images, screenshots, dictations, snippets, apps

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Saved shortcuts name the old tabs; each tab becomes the chip that shows the same things.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "clipboard": self = .all
        case "dictationHistory": self = .dictations
        default:
            guard let chip = Chip(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown chip \(raw)"))
            }
            self = chip
        }
    }
}

nonisolated enum NotchPhase: Equatable, Sendable { case collapsed, shelf, expanded, dictation }
nonisolated enum BasePhase: Equatable, Sendable { case idle, toast }

/// A button the toast offers. The work it does lives on NotchController.
struct ToastAction: Equatable, Sendable {
    var title: String
    var symbol: String
}

struct Toast: Equatable, Sendable {
    var symbol: String
    var title: String
    var subtitle: String? = nil
    var tint: Color = .green
    var action: ToastAction? = nil
}

/// Everything the island's views observe. Owned by `NotchController`.
@Observable
final class NotchState {
    var phase: NotchPhase = .collapsed
    /// The phase whose size the panel canvas keeps during collapse; SwiftUI must never negotiate a new window size.
    var canvasPhase: NotchPhase = .expanded
    var basePhase: BasePhase = .idle
    var chip: Chip = .all
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
    var opensShelfOnHover = true
    var keepsAwake = false
    var clockText: String?
    var tabHovered = false
    /// Where the toast button sits, in the collapsed window's own coordinates, so clicks can find it.
    var toastActionRect: CGRect = .zero
    var toastActionHovered = false

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var isExpanded: Bool { phase == .expanded }
    var isShelf: Bool { phase == .shelf }
    var isDictating: Bool { phase == .dictation }
    var isOpen: Bool { phase != .collapsed }
}
