import AppKit

/// Everything the keyboard can ask the island to do. Sections handle what applies to them.
nonisolated enum PanelCommand: Equatable, Sendable {
    case moveUp, moveDown, moveLeft, moveRight, pageUp, pageDown, moveToStart, moveToEnd
    /// ↩ — copy or paste depending on the "Enter" setting.
    case primaryAction
    /// ⌘↩ — the other one.
    case secondaryAction
    case delete, clearAll, togglePin, saveAsSnippet, newItem, editItem, revealInFinder, quickLook
    case nextSection, previousSection, selectSection(Section)
    case close, openSettings
}

/// Maps key events to commands. Anything unmapped falls through to the focused text field.
nonisolated enum KeyRouter {
    static func command(for event: NSEvent) -> PanelCommand? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let cmd = mods.contains(.command), ctrl = mods.contains(.control), shift = mods.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch Int(event.keyCode) {
        case 53: return .close                                            // esc
        case 126: return .moveUp                                          // ↑
        case 125: return .moveDown                                        // ↓
        case 123: return .moveLeft                                        // ←
        case 124: return .moveRight                                       // →
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .moveToStart                                     // home
        case 119: return .moveToEnd                                       // end
        case 36, 76: return cmd ? .secondaryAction : .primaryAction       // ↩ / keypad enter
        case 48: return shift ? .previousSection : .nextSection           // ⇥
        case 51 where cmd: return shift ? .clearAll : .delete             // ⌫
        default: break
        }
        if ctrl, !cmd {
            switch key {
            case "n", "j": return .moveDown
            case "p", "k": return .moveUp
            default: break
            }
        }
        if cmd, !ctrl {
            switch key {
            case "1": return .selectSection(.clipboard)
            case "2": return .selectSection(.snippets)
            case "3": return .selectSection(.screenshots)
            case "p": return .togglePin
            case "s": return .saveAsSnippet
            case "n": return .newItem
            case "e": return .editItem
            case "r": return .revealInFinder
            case "y": return .quickLook
            case ",": return .openSettings
            default: break
            }
        }
        return nil
    }
}
