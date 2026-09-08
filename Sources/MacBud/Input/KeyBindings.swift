import AppKit
import Carbon.HIToolbox

/// Every island action the user can rebind. Order here is the order shown in Settings.
nonisolated enum BindableCommand: String, CaseIterable, Codable, Sendable {
    case moveUp, moveDown, moveLeft, moveRight, pageUp, pageDown, moveToStart, moveToEnd
    case primaryAction, secondaryAction
    case delete, clearAll, togglePin, saveAsSnippet, newItem, editItem, revealInFinder, quickLook
    case nextSection, previousSection, selectSection1, selectSection2, selectSection3, selectSection4, selectSection5
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
        case .selectSection1: .selectSectionAt(0)
        case .selectSection2: .selectSectionAt(1)
        case .selectSection3: .selectSectionAt(2)
        case .selectSection4: .selectSectionAt(3)
        case .selectSection5: .selectSectionAt(4)
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
        case .selectSection1: "Go to section 1"
        case .selectSection2: "Go to section 2"
        case .selectSection3: "Go to section 3"
        case .selectSection4: "Go to section 4"
        case .selectSection5: "Go to section 5"
        case .startDictation: "Start dictation"
        case .close: "Close"
        case .openSettings: "Open Settings"
        }
    }

    var group: String {
        switch self {
        case .moveUp, .moveDown, .moveLeft, .moveRight, .pageUp, .pageDown, .moveToStart, .moveToEnd: "Navigation"
        case .primaryAction, .secondaryAction, .delete, .clearAll, .togglePin, .saveAsSnippet, .newItem, .editItem, .revealInFinder, .quickLook: "Actions"
        case .nextSection, .previousSection, .selectSection1, .selectSection2, .selectSection3, .selectSection4, .selectSection5: "Sections"
        case .startDictation, .close, .openSettings: "General"
        }
    }

    static let groups = ["Navigation", "Actions", "Sections", "General"]

    /// ⌘1…⌘4 address tab positions, so they follow the order set in Settings › Features.
    /// One slot per section: `sectionSlotsCoverEverySection` keeps the two lists in step.
    static let sectionSlots: [BindableCommand] = [.selectSection1, .selectSection2, .selectSection3, .selectSection4, .selectSection5]

    static func sectionSlot(at index: Int) -> BindableCommand? {
        sectionSlots.indices.contains(index) ? sectionSlots[index] : nil
    }

    var sectionSlotIndex: Int? { Self.sectionSlots.firstIndex(of: self) }
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
        .selectSection1: [key(kVK_ANSI_1, .command)],
        .selectSection2: [key(kVK_ANSI_2, .command)],
        .selectSection3: [key(kVK_ANSI_3, .command)],
        .selectSection4: [key(kVK_ANSI_4, .command)],
        .selectSection5: [key(kVK_ANSI_5, .command)],
        .startDictation: [key(kVK_ANSI_D, .command)],
        .close: [key(kVK_Escape)],
        .openSettings: [key(kVK_ANSI_Comma, .command)],
    ])

    private enum CodingKeys: String, CodingKey { case chords }

    /// ⌘1…⌘4 used to name a fixed section. Settings saved before that moved to tab positions keep
    /// their chords: each old command hands them to the slot its section held in the default order.
    private static let legacySectionCommands: [(key: String, section: Section)] = [
        ("selectClipboard", .clipboard), ("selectSnippets", .snippets),
        ("selectScreenshots", .screenshots), ("selectDictationHistory", .dictationHistory),
    ]

    init(from decoder: any Decoder) throws {
        var stored = try decoder.container(keyedBy: CodingKeys.self).decode([String: [HotKey]].self, forKey: .chords)
        for (key, section) in Self.legacySectionCommands {
            guard let migrated = stored.removeValue(forKey: key),
                  let slot = BindableCommand.sectionSlot(at: section.index), stored[slot.rawValue] == nil else { continue }
            stored[slot.rawValue] = migrated
        }
        chords = stored.filter { BindableCommand(rawValue: $0.key) != nil }
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
