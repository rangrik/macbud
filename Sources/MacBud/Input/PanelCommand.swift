import AppKit

/// Everything the keyboard can ask the island to do. Sections handle what applies to them.
nonisolated enum PanelCommand: Equatable, Sendable {
    case moveUp, moveDown, moveLeft, moveRight, pageUp, pageDown, moveToStart, moveToEnd
    /// ↩ — copy or paste depending on the "Enter" setting.
    case primaryAction
    /// ⌘↩ — the other one.
    case secondaryAction
    case delete, clearAll, togglePin, saveAsSnippet, newItem, editItem, revealInFinder, quickLook
    case nextSection, previousSection
    /// Jump to the section sitting at this position in the island's tab bar (0-based),
    /// so ⌘1…⌘4 follow the order set in Settings › Features rather than fixed sections.
    case selectSectionAt(Int)
    case startDictation
    case close, openSettings
}

/// Maps key events to commands through the user's bindings. Anything unmapped falls through to the text field.
nonisolated enum KeyRouter {
    static func command(for event: NSEvent, bindings: KeyBindings = .defaults) -> PanelCommand? {
        bindings.command(for: event)
    }
}
