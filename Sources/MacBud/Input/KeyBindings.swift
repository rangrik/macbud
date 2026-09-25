import AppKit
import Carbon.HIToolbox

/// Every island action the user can rebind. Order here is the order shown in Settings.
nonisolated enum BindableCommand: String, CaseIterable, Codable, Sendable {
    case moveUp, moveDown, moveLeft, moveRight, pageUp, pageDown, moveToStart, moveToEnd
    case primaryAction, secondaryAction
    case delete, clearAll, togglePin, saveAsSnippet, newItem, editItem, revealInFinder, quickLook
    case nextChip, previousChip, selectChip1, selectChip2, selectChip3, selectChip4, selectChip5, selectChip6, selectChip7, selectChip8
    case startDictation, close, openSettings, openPredictionActivity

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
        case .nextChip: .nextChip
        case .previousChip: .previousChip
        case .selectChip1, .selectChip2, .selectChip3, .selectChip4, .selectChip5, .selectChip6, .selectChip7, .selectChip8:
            .selectChip(Chip.allCases[chipSlotIndex ?? 0])
        case .startDictation: .startDictation
        case .close: .close
        case .openSettings: .openSettings
        case .openPredictionActivity: .openPredictionActivity
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
        case .nextChip: "Next filter"
        case .previousChip: "Previous filter"
        case .selectChip1, .selectChip2, .selectChip3, .selectChip4, .selectChip5, .selectChip6, .selectChip7, .selectChip8:
            "Filter \((chipSlotIndex ?? 0) + 1) — \(Chip.allCases[chipSlotIndex ?? 0].title)"
        case .startDictation: "Start dictation"
        case .close: "Close"
        case .openSettings: "Open Settings"
        case .openPredictionActivity: "Open Prediction Activity"
        }
    }

    var group: String {
        switch self {
        case .moveUp, .moveDown, .moveLeft, .moveRight, .pageUp, .pageDown, .moveToStart, .moveToEnd: "Navigation"
        case .primaryAction, .secondaryAction, .delete, .clearAll, .togglePin, .saveAsSnippet, .newItem, .editItem, .revealInFinder, .quickLook: "Actions"
        case .nextChip, .previousChip, .selectChip1, .selectChip2, .selectChip3, .selectChip4, .selectChip5, .selectChip6,
             .selectChip7, .selectChip8: "Filters"
        case .startDictation, .close, .openSettings, .openPredictionActivity: "General"
        }
    }

    static let groups = ["Navigation", "Actions", "Filters", "General"]

    /// One slot per chip, in the chip row's fixed order.
    static let chipSlots: [BindableCommand] = [.selectChip1, .selectChip2, .selectChip3, .selectChip4,
                                               .selectChip5, .selectChip6, .selectChip7, .selectChip8]

    var chipSlotIndex: Int? { Self.chipSlots.firstIndex(of: self) }
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
        .nextChip: [key(kVK_Tab)],
        .previousChip: [key(kVK_Tab, .shift)],
        .selectChip1: [key(kVK_ANSI_1, .command)],
        .selectChip2: [key(kVK_ANSI_2, .command)],
        .selectChip3: [key(kVK_ANSI_3, .command)],
        .selectChip4: [key(kVK_ANSI_4, .command)],
        .selectChip5: [key(kVK_ANSI_5, .command)],
        .selectChip6: [key(kVK_ANSI_6, .command)],
        .selectChip7: [key(kVK_ANSI_7, .command)],
        .selectChip8: [key(kVK_ANSI_8, .command)],
        .startDictation: [key(kVK_ANSI_D, .command)],
        .close: [key(kVK_Escape)],
        .openSettings: [key(kVK_ANSI_Comma, .command)],
        .openPredictionActivity: [key(kVK_ANSI_L, .command)],
    ])

    private enum CodingKeys: String, CodingKey { case chords }

    /// Chords saved for the tabs keep working: numbered slots keep their number, and the older
    /// per-tab commands go to their tab's chip.
    private static let renamed: [(old: String, new: BindableCommand)] = [
        ("nextSection", .nextChip), ("previousSection", .previousChip),
        ("selectSection1", .selectChip1), ("selectSection2", .selectChip2), ("selectSection3", .selectChip3),
        ("selectSection4", .selectChip4), ("selectSection5", .selectChip5),
        ("selectClipboard", .selectChip1), ("selectScreenshots", .selectChip5),
        ("selectDictationHistory", .selectChip6), ("selectSnippets", .selectChip7),
    ]

    init(from decoder: any Decoder) throws {
        var stored = try decoder.container(keyedBy: CodingKeys.self).decode([String: [HotKey]].self, forKey: .chords)
        for (old, new) in Self.renamed {
            guard let chords = stored.removeValue(forKey: old), stored[new.rawValue] == nil else { continue }
            stored[new.rawValue] = chords
        }
        stored = stored.filter { BindableCommand(rawValue: $0.key) != nil }
        // Commands added since the save get their defaults, unless that chord is already taken.
        let taken = Set(stored.values.joined())
        for command in BindableCommand.allCases where stored[command.rawValue] == nil {
            stored[command.rawValue] = Self.defaults.chords(for: command).filter { !taken.contains($0) }
        }
        chords = stored
    }

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
