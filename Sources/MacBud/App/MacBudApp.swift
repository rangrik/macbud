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
        Button("Open MacBud") { app.notch.toggle() }
        Divider()
        ForEach(Section.allCases) { section in
            Button(section.title) { app.notch.open(section: section) }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit MacBud") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
