import SwiftUI

@main
struct MacBudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("MacBud", systemImage: "rectangle.topthird.inset.filled") {
            MenuBarMenu(app: delegate)
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
        ForEach(Section.allCases) { section in
            Button(section.title) { app.coordinator.open(section: section) }
        }
        Button("Start Dictation") { app.coordinator.startDictation() }
        Divider()
        Toggle("Pause Clipboard Capture", isOn: Binding(get: { app.settings.clipboardPaused }, set: { app.settings.clipboardPaused = $0 }))
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit MacBud") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
