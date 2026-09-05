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
            ForEach(Section.allCases) { section in
                LabeledContent("Open \(section.title) directly") {
                    HotKeyRecorder(hotKey: sectionBinding(section), onRecordingChanged: suspendHotKeys)
                }
            }
            LabeledContent("Start dictation") {
                HotKeyRecorder(hotKey: $settings.dictationHotKey, onRecordingChanged: suspendHotKeys)
            }
            if let problem = hotKeys?.toggleProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
        } header: {
            Text("Global — work from any app")
        } footer: {
            Text("A global shortcut needs ⌘, ⌥ or ⌃ (or a function key). Pressing the dictation shortcut again while recording inserts the text.")
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
        SwiftUI.Section(group == "General" ? "Inside the island — general" : "Inside the island — \(group.lowercased())") {
            ForEach(BindableCommand.allCases.filter { $0.group == group }, id: \.self) { command in
                BindingRow(settings: settings, command: command)
            }
        }
    }
}

private struct BindingRow: View {
    @Bindable var settings: AppSettings
    let command: BindableCommand

    var body: some View {
        LabeledContent(command.title) {
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
