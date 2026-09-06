import AppKit
import Carbon.HIToolbox

/// Every island action the user can rebind. Order here is the order shown in Settings.
nonisolated enum BindableCommand: String, CaseIterable, Codable, Sendable {
    case moveUp, moveDown, moveLeft, moveRight, pageUp, pageDown, moveToStart, moveToEnd
    case primaryAction, secondaryAction
    case delete, clearAll, togglePin, saveAsSnippet, newItem, editItem, revealInFinder, quickLook
    case nextSection, previousSection, selectClipboard, selectSnippets, selectScreenshots, selectDictationHistory
    case startDictation, close, openSettings

    var panelCommand: PanelCommand {
        switch self {
        case .moveUp: .moveUp
        case .moveDown: .moveDown
        case .moveLeft: .moveLeft
        case .moveRight: .moveRight
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .moveToStart: .moveToStart
        case .moveToEnd: .moveToEnd
        case .primaryAction: .primaryAction
        case .secondaryAction: .secondaryAction
        case .delete: .delete
        case .clearAll: .clearAll
        case .togglePin: .togglePin
        case .saveAsSnippet: .saveAsSnippet
        case .newItem: .newItem
        case .editItem: .editItem
        case .revealInFinder: .revealInFinder
        case .quickLook: .quickLook
        case .nextSection: .nextSection
        case .previousSection: .previousSection
        case .selectClipboard: .selectSection(.clipboard)
        case .selectSnippets: .selectSection(.snippets)
        case .selectScreenshots: .selectSection(.screenshots)
        case .selectDictationHistory: .selectSection(.dictationHistory)
        case .startDictation: .startDictation
        case .close: .close
        case .openSettings: .openSettings
        }
    }

    var title: String {
        switch self {
        case .moveUp: "Move up"
        case .moveDown: "Move down"
        case .moveLeft: "Move left"
        case .moveRight: "Move right"
        case .pageUp: "Page up"
        case .pageDown: "Page down"
        case .moveToStart: "First item"
        case .moveToEnd: "Last item"
        case .primaryAction: "Use item (Return)"
        case .secondaryAction: "Use item the other way"
        case .delete: "Delete item"
        case .clearAll: "Clear clipboard history"
        case .togglePin: "Pin / unpin"
        case .saveAsSnippet: "Save text as snippet"
        case .newItem: "New snippet"
        case .editItem: "Edit snippet"
        case .revealInFinder: "Reveal in Finder"
        case .quickLook: "Quick Look"
        case .nextSection: "Next section"
        case .previousSection: "Previous section"
        case .selectClipboard: "Go to Clipboard"
        case .selectSnippets: "Go to Snippets"
        case .selectScreenshots: "Go to Screenshots"
        case .selectDictationHistory: "Go to Dictation History"
        case .startDictation: "Start dictation"
        case .close: "Close"
        case .openSettings: "Open Settings"
        }
    }

    var group: String {
        switch self {
        case .moveUp, .moveDown, .moveLeft, .moveRight, .pageUp, .pageDown, .moveToStart, .moveToEnd: "Navigation"
        case .primaryAction, .secondaryAction, .delete, .clearAll, .togglePin, .saveAsSnippet, .newItem, .editItem, .revealInFinder, .quickLook: "Actions"
        case .nextSection, .previousSection, .selectClipboard, .selectSnippets, .selectScreenshots, .selectDictationHistory: "Sections"
        case .startDictation, .close, .openSettings: "General"
        }
    }

    static let groups = ["Navigation", "Actions", "Sections", "General"]
}

/// User-editable map from island commands to key chords. A command may have up to two chords.
nonisolated struct KeyBindings: Codable, Equatable, Sendable {
    private var chords: [String: [HotKey]]

    init(chords: [BindableCommand: [HotKey]]) {
        self.chords = Dictionary(uniqueKeysWithValues: chords.map { ($0.key.rawValue, $0.value) })
    }

    static let maxChordsPerCommand = 2

    static let defaults = KeyBindings(chords: [
        .moveUp: [key(kVK_UpArrow), key(kVK_ANSI_P, .control), key(kVK_ANSI_K, .control)],
        .moveDown: [key(kVK_DownArrow), key(kVK_ANSI_N, .control), key(kVK_ANSI_J, .control)],
        .moveLeft: [key(kVK_LeftArrow)],
        .moveRight: [key(kVK_RightArrow)],
        .pageUp: [key(kVK_PageUp)],
        .pageDown: [key(kVK_PageDown)],
        .moveToStart: [key(kVK_Home)],
        .moveToEnd: [key(kVK_End)],
        .primaryAction: [key(kVK_Return), key(kVK_ANSI_KeypadEnter)],
        .secondaryAction: [key(kVK_Return, .command), key(kVK_ANSI_KeypadEnter, .command)],
        .delete: [key(kVK_Delete, .command)],
        .clearAll: [key(kVK_Delete, [.command, .shift])],
        .togglePin: [key(kVK_ANSI_P, .command)],
        .saveAsSnippet: [key(kVK_ANSI_S, .command)],
        .newItem: [key(kVK_ANSI_N, .command)],
        .editItem: [key(kVK_ANSI_E, .command)],
        .revealInFinder: [key(kVK_ANSI_R, .command)],
        .quickLook: [key(kVK_ANSI_Y, .command)],
        .nextSection: [key(kVK_Tab)],
        .previousSection: [key(kVK_Tab, .shift)],
        .selectClipboard: [key(kVK_ANSI_1, .command)],
        .selectSnippets: [key(kVK_ANSI_2, .command)],
        .selectScreenshots: [key(kVK_ANSI_3, .command)],
        .selectDictationHistory: [key(kVK_ANSI_4, .command)],
        .startDictation: [key(kVK_ANSI_D, .command)],
        .close: [key(kVK_Escape)],
        .openSettings: [key(kVK_ANSI_Comma, .command)],
    ])

    func chords(for command: BindableCommand) -> [HotKey] { chords[command.rawValue] ?? [] }

    mutating func set(_ newChords: [HotKey], for command: BindableCommand) {
        chords[command.rawValue] = Array(newChords.prefix(Self.maxChordsPerCommand + 1))
    }

    /// The command bound to this key event, if any. Chords on later commands never shadow earlier ones.
    func command(for event: NSEvent) -> PanelCommand? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        for command in BindableCommand.allCases {
            for chord in chords(for: command) where chord.keyCode == event.keyCode && chord.modifiers == mods {
                return command.panelCommand
            }
        }
        return nil
    }

    /// Other commands already using this chord (for conflict warnings in Settings).
    func conflicts(for chord: HotKey, excluding command: BindableCommand) -> [BindableCommand] {
        BindableCommand.allCases.filter { $0 != command && chords(for: $0).contains(chord) }
    }

    private static func key(_ code: Int, _ modifiers: NSEvent.ModifierFlags = []) -> HotKey {
        HotKey(keyCode: UInt16(code), modifiers: modifiers)
    }
}
