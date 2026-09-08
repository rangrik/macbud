import AppKit
import SwiftUI

struct SettingsView: View {
    let app: AppDelegate

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(settings: app.settings, hotKeys: app.hotKeys) }
            Tab("Features", systemImage: "slider.horizontal.3") { FeaturesSettings(settings: app.settings) }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutsSettings(settings: app.settings, hotKeys: app.hotKeys) }
            if app.settings.isEnabled(.clipboard) {
                Tab("Clipboard", systemImage: "doc.on.clipboard") { ClipboardSettings(settings: app.settings, store: app.clipboardStore) }
            }
            if app.settings.isEnabled(.snippets) {
                Tab("Snippets", systemImage: "text.badge.checkmark") { SnippetsSettings(store: app.snippetStore) }
            }
            if app.settings.isEnabled(.screenshots) {
                Tab("Screenshots", systemImage: "photo.on.rectangle.angled") { ScreenshotSettings(settings: app.settings, library: app.library) }
            }
            if app.settings.isEnabled(.dictation) {
                Tab("Dictation", systemImage: "mic") { DictationSettings(settings: app.settings, words: app.coordinator?.dictationWordStore) }
            }
            Tab("About", systemImage: "info.circle") { AboutView() }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let hotKeys: HotKeyBinder?
    @State private var accessibilityTrusted = Paster.isAccessibilityTrusted
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            SwiftUI.Section("Behaviour") {
                Picker("Return key", selection: $settings.enterAction) {
                    ForEach(AppSettings.EnterAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("⌘↩ always does the other one.").font(.caption).foregroundStyle(.secondary)
                Toggle("Reopen the last used section", isOn: $settings.rememberLastSection)
                Toggle("Show a clickable notch tab on every display", isOn: $settings.showNotchTab)
                Text("External displays get a drawn notch; the shortcut opens on the display you are working on.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show a confirmation in the notch after copying", isOn: $settings.showToasts)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        settings.launchAtLogin = on
                        settings.hasConfiguredLaunchAtLogin = true
                        launchAtLogin = settings.launchAtLogin
                    }
                if !AppDelegate.isInstalledInApplications {
                    Text("Move MacBud to /Applications so the login item keeps working after rebuilds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack {
                        StatusDot(ok: accessibilityTrusted)
                        Text(accessibilityTrusted ? "Granted — paste into apps works" : "Needed only to paste directly into apps")
                        Button("Open Settings") { Paster.promptForAccessibility(); Paster.openAccessibilitySettings() }
                    }
                }
                LabeledContent("Clipboard access") {
                    HStack {
                        StatusDot(ok: NSPasteboard.general.accessBehavior != .alwaysDeny)
                        Text(pasteboardAccessDescription)
                        Button("Privacy Settings") { Paster.openPasteboardPrivacySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = settings.launchAtLogin
            accessibilityTrusted = Paster.isAccessibilityTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = Paster.isAccessibilityTrusted
        }
    }

    private var pasteboardAccessDescription: String {
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: "Always allowed"
        case .alwaysDeny: "Denied — history cannot be captured"
        case .ask: "macOS asks; choose “Always Allow”"
        default: "Default"
        }
    }

}

struct StatusDot: View {
    let ok: Bool
    var body: some View { Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8) }
}

/// Click, press a chord, done. Esc cancels, ⌫ clears.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    var onRecordingChanged: (Bool) -> Void = { _ in }
    /// Global shortcuts need ⌘/⌥/⌃ so plain typing can't be captured; island bindings may be bare keys.
    var requiresModifier = true
    var compact = false
    @State private var recording = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording.toggle()
            } label: {
                Text(recording ? (compact ? "Press…" : "Press shortcut…") : hotKey?.displayString ?? (compact ? "＋" : "Not set"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: compact ? 58 : 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if hotKey != nil, !recording {
                Button { hotKey = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Remove shortcut")
            }
        }
        .background(KeyCaptureView(isRecording: $recording, onKey: handle).frame(width: 0, height: 0))
        .onChange(of: recording) { _, now in onRecordingChanged(now) }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { recording = false; return }
        if event.keyCode == 51, mods.isEmpty { hotKey = nil; recording = false; return }
        let candidate = HotKey(keyCode: event.keyCode, modifiers: mods)
        guard !requiresModifier || candidate.isUsableGlobally else { NSSound.beep(); return }
        hotKey = candidate
        recording = false
    }
}

struct KeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        view.onResign = { Task { @MainActor in if isRecording { isRecording = false } } }
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        guard let window = view.window else { return }
        if isRecording, window.firstResponder !== view {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        } else if !isRecording, window.firstResponder === view {
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onResign: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { onKey?(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            onKey?(event)
            return true
        }
        override func resignFirstResponder() -> Bool { onResign?(); return true }
    }
}

// MARK: - Clipboard

struct ClipboardSettings: View {
    @Bindable var settings: AppSettings
    let store: ClipboardStore
    @State private var newBundleID = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            SwiftUI.Section("History") {
                Picker("Keep up to", selection: $settings.historyLimit) {
                    ForEach([100, 250, 500, 1000, 5000], id: \.self) { Text("\($0) items").tag($0) }
                }
                Toggle("Pause capturing", isOn: $settings.clipboardPaused)
                LabeledContent("Stored now") { Text("\(store.items.count) items (\(store.items.filter(\.isPinned).count) pinned)") }
                Button("Clear history…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Delete all clipboard history, including pinned items?", isPresented: $confirmClear) {
                        Button("Delete everything", role: .destructive) { store.removeAll(keepPinned: false) }
                    }
            }
            SwiftUI.Section {
                ForEach(settings.ignoredBundleIDs, id: \.self) { id in
                    HStack {
                        Text(AppInfo.name(for: id) ?? id)
                        Text(id).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button { settings.ignoredBundleIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Bundle identifier, e.g. com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addBundleID)
                    Button("Add", action: addBundleID).disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Ignored apps")
            } footer: {
                Text("Copies made in these apps are never recorded. Password managers that mark their pasteboard data as concealed are skipped automatically.")
            }
        }
        .formStyle(.grouped)
    }

    private func addBundleID() {
        let id = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !settings.ignoredBundleIDs.contains(id) else { return }
        settings.ignoredBundleIDs.append(id)
        newBundleID = ""
    }
}

// MARK: - Snippets

struct SnippetsSettings: View {
    let store: SnippetStore
    @State private var selection: UUID?
    @State private var editing: Snippet?

    var body: some View {
        VStack(spacing: 0) {
            Table(store.snippets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Keyword") { Text($0.keyword).font(.system(.body, design: .monospaced)) }.width(90)
                TableColumn("Content") { Text($0.content.replacingOccurrences(of: "\n", with: " ⏎ ")).lineLimit(1) }
                TableColumn("Uses") { Text("\($0.useCount)") }.width(40)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Edit") { editing = ids.first.flatMap(store.snippet(id:)) }
                Button("Delete", role: .destructive) { ids.forEach(store.remove) }
            } primaryAction: { ids in
                editing = ids.first.flatMap(store.snippet(id:))
            }
            Divider()
            HStack {
                Button { editing = Snippet(name: "", keyword: "", content: "") } label: { Image(systemName: "plus") }
                Button { if let id = selection { store.remove(id); selection = nil } } label: { Image(systemName: "minus") }.disabled(selection == nil)
                Button("Edit") { editing = selection.flatMap(store.snippet(id:)) }.disabled(selection == nil)
                Spacer()
                Button("Import…", action: importSnippets)
                Button("Export…", action: exportSnippets).disabled(store.snippets.isEmpty)
            }
            .padding(10)
        }
        .sheet(item: $editing) { snippet in
            SnippetFormSheet(snippet: snippet) { saved in store.upsert(saved) }
        }
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let imported = try? decoder.decode([Snippet].self, from: data) else { return }
        var merged = store.snippets
        for s in imported where !merged.contains(where: { $0.id == s.id }) { merged.append(s) }
        store.replaceAll(merged)
    }

    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacBud Snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(store.snippets).write(to: url)
    }
}

struct SnippetFormSheet: View {
    @State var snippet: Snippet
    let onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snippet.name.isEmpty ? "New snippet" : "Edit snippet").font(.headline)
            HStack {
                TextField("Name", text: $snippet.name).textFieldStyle(.roundedBorder)
                TextField("Keyword", text: $snippet.keyword).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            TextEditor(text: $snippet.content)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Text("Placeholders: \(SnippetExpander.knownPlaceholders.joined(separator: "  "))").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(snippet); dismiss() }.keyboardShortcut(.defaultAction).disabled(!snippet.isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Screenshots

struct ScreenshotSettings: View {
    @Bindable var settings: AppSettings
    let library: ScreenshotLibrary

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(settings.screenshotFolders, id: \.self) { path in
                    let missing = library.missingFolders.contains { $0.path == (path as NSString).expandingTildeInPath }
                    HStack {
                        Image(systemName: missing ? "folder.badge.questionmark" : "folder").foregroundStyle(missing ? .orange : .secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath).foregroundStyle(missing ? .secondary : .primary)
                        Spacer()
                        Button { settings.screenshotFolders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Add Folder…", action: addFolder)
            } header: {
                Text("Folders")
            } footer: {
                Text("macOS saves screenshots to \((AppSettings.systemScreenshotFolder().path as NSString).abbreviatingWithTildeInPath). \(library.items.count) items indexed.")
            }
            SwiftUI.Section("Options") {
                Toggle("Include subfolders", isOn: $settings.includeSubfolders)
                Toggle("Include videos and screen recordings", isOn: $settings.includeVideos)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.screenshotFolders.contains(url.path) {
            settings.screenshotFolders.append(url.path)
        }
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("MacBud").font(.title.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · macOS 26 · Apple Silicon")
                .foregroundStyle(.secondary)
            Text("Clipboard history, snippets and a screenshot browser — living in the notch, driven by the keyboard.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            GroupBox("Automation") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macbud://open?section=clipboard|snippets|screenshots")
                    Text("macbud://toggle · macbud://close")
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 380)
            Link("github.com/rangrik/macbud", destination: URL(string: "https://github.com/rangrik/macbud")!)
        }
        .padding(30)
    }
}
