import SwiftUI

@main
struct MacBudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(app: delegate)
        } label: {
            Image("MacBudStatusIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityLabel("MacBud")
        }
        Settings {
            SettingsView(app: delegate)
        }
    }
}

struct MenuBarMenu: View {
    let app: AppDelegate

    var body: some View {
        Button("Open MacBud") { app.coordinator.toggle() }
        Divider()
        ForEach(app.settings.enabledSections) { section in
            Button(section.title) { app.coordinator.open(section: section) }
        }
        if app.settings.isEnabled(.dictation) {
            Button("Start Dictation") { app.coordinator.startDictation() }
        }
        Divider()
        if app.settings.isEnabled(.clipboard) {
            Toggle("Pause Clipboard Capture", isOn: Binding(get: { app.settings.clipboardPaused }, set: { app.settings.clipboardPaused = $0 }))
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit MacBud") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
