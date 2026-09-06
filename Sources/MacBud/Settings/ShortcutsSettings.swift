import SwiftUI

/// Global hotkeys plus every in-island key binding, all editable.
struct ShortcutsSettings: View {
    @Bindable var settings: AppSettings
    let hotKeys: HotKeyBinder?

    var body: some View {
        Form {
            GlobalShortcutsSection(settings: settings, hotKeys: hotKeys)
            ForEach(BindableCommand.groups, id: \.self) { group in
                BindingGroupSection(settings: settings, group: group)
            }
            SwiftUI.Section {
                Button("Reset island shortcuts to defaults") { settings.keyBindings = .defaults }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GlobalShortcutsSection: View {
    @Bindable var settings: AppSettings
    let hotKeys: HotKeyBinder?

    var body: some View {
        SwiftUI.Section {
            LabeledContent("Open MacBud") {
                HotKeyRecorder(hotKey: $settings.toggleHotKey, onRecordingChanged: suspendHotKeys)
            }
            ForEach(settings.sectionOrder) { section in
                LabeledContent("Open \(section.title) directly") {
                    HotKeyRecorder(hotKey: sectionBinding(section), onRecordingChanged: suspendHotKeys)
                }
                .disabled(!settings.isEnabled(section.feature))
            }
            LabeledContent("Toggle dictation / insert") {
                HotKeyRecorder(hotKey: $settings.dictationHotKey, onRecordingChanged: suspendHotKeys)
            }
            .disabled(!settings.isEnabled(.dictation))
            LabeledContent("Hold to talk") {
                HotKeyRecorder(hotKey: $settings.holdToTalkHotKey, onRecordingChanged: suspendHotKeys)
            }
            .disabled(!settings.isEnabled(.dictation))
            ForEach([hotKeys?.dictationProblem, hotKeys?.holdToTalkProblem].compactMap { $0 }, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let problem = hotKeys?.toggleProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
        } header: {
            Text("Global — work from any app")
        } footer: {
            Text("Press the dictation shortcut again to stop and insert. Hold to talk records while its shortcut is held, then inserts on release. With no editable input, the text is copied. Escape cancels.")
        }
    }

    private func sectionBinding(_ section: Section) -> Binding<HotKey?> {
        Binding(get: { settings.sectionHotKeys[section] },
                set: { newValue in
                    var keys = settings.sectionHotKeys
                    if let newValue { keys[section] = newValue } else { keys.removeValue(forKey: section) }
                    settings.sectionHotKeys = keys
                })
    }

    private func suspendHotKeys(_ recording: Bool) {
        if recording { HotKeyCenter.shared.unregisterAll() } else { hotKeys?.apply() }
    }
}

private struct BindingGroupSection: View {
    @Bindable var settings: AppSettings
    let group: String

    var body: some View {
        SwiftUI.Section {
            ForEach(BindableCommand.allCases.filter { $0.group == group }, id: \.self) { command in
                BindingRow(settings: settings, command: command, section: section(for: command))
                    .disabled(command.sectionSlotIndex != nil && section(for: command) == nil)
            }
        } header: {
            Text(group == "General" ? "Inside the island — general" : "Inside the island — \(group.lowercased())")
        } footer: {
            if group == "Sections" {
                Text("Section shortcuts follow the tab order: ⌘1 is always the first tab. Reorder or hide tabs in Features.")
            }
        }
    }

    /// The section a ⌘1…⌘4 slot opens right now, or nil when the island shows fewer tabs than slots.
    private func section(for command: BindableCommand) -> Section? {
        guard let index = command.sectionSlotIndex else { return nil }
        let sections = settings.enabledSections
        return sections.indices.contains(index) ? sections[index] : nil
    }
}

private struct BindingRow: View {
    @Bindable var settings: AppSettings
    let command: BindableCommand
    /// For a ⌘1…⌘4 slot, the section it currently lands on — the row names it so the mapping is visible.
    var section: Section? = nil

    var body: some View {
        LabeledContent(section.map { "\(command.title) — \($0.title)" } ?? command.title) {
            HStack(spacing: 6) {
                HotKeyRecorder(hotKey: chordBinding(slot: 0), requiresModifier: false, compact: true)
                HotKeyRecorder(hotKey: chordBinding(slot: 1), requiresModifier: false, compact: true)
                if let conflict = conflictText {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(conflict)
                }
            }
        }
    }

    private func chordBinding(slot: Int) -> Binding<HotKey?> {
        Binding(get: {
            let chords = settings.keyBindings.chords(for: command)
            return chords.indices.contains(slot) ? chords[slot] : nil
        }, set: { newValue in
            var bindings = settings.keyBindings
            var chords = bindings.chords(for: command)
            if let newValue {
                if chords.indices.contains(slot) { chords[slot] = newValue } else { chords.append(newValue) }
            } else if chords.indices.contains(slot) {
                chords.remove(at: slot)
            }
            bindings.set(chords, for: command)
            settings.keyBindings = bindings
        })
    }

    private var conflictText: String? {
        let conflicts = settings.keyBindings.chords(for: command).flatMap { chord in
            settings.keyBindings.conflicts(for: chord, excluding: command).map { "\(chord.displayString) is also \($0.title)" }
        }
        return conflicts.isEmpty ? nil : conflicts.joined(separator: "\n")
    }
}
