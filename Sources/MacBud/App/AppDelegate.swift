import AppKit
import Observation

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let notch = NotchController()
    let clipboardStore = ClipboardStore()
    let snippetStore = SnippetStore()
    let library = ScreenshotLibrary()
    private(set) var coordinator: PanelCoordinator!
    private(set) var hotKeys: HotKeyBinder!
    private var monitor: ClipboardMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = PanelCoordinator(state: notch.state, notch: notch, settings: settings,
                                       clipboardStore: clipboardStore, snippetStore: snippetStore, library: library)
        notch.keyHandler = { [coordinator] event in coordinator!.handle(event: event) }
        notch.willOpen = { [coordinator] in coordinator!.willOpen() }
        notch.contentProvider = { [coordinator] in IslandContentView(state: coordinator!.state, coordinator: coordinator!) }
        notch.install()

        clipboardStore.limit = settings.historyLimit
        Task {
            await clipboardStore.load()
            await snippetStore.load()
        }
        monitor = ClipboardMonitor(store: clipboardStore, settings: settings)
        monitor.start()

        applyLibrarySettings()
        hotKeys = HotKeyBinder(settings: settings, coordinator: coordinator)
        coordinator.hotKeys = hotKeys
        hotKeys.apply()
        observeSettings()
        Automation.installListener(app: self)

        if !settings.hasSeenWelcome {
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                coordinator.open(section: .clipboard)
            }
        }
        Log.app.info("MacBud launched; automation=\(Automation.isEnabled)")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Automation.handle(url, app: self) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }

    // MARK: Settings → subsystems

    private func applyLibrarySettings() {
        library.includeSubfolders = settings.includeSubfolders
        library.includeVideos = settings.includeVideos
        library.folders = settings.screenshotFolderURLs
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.screenshotFolders
            _ = settings.includeSubfolders
            _ = settings.includeVideos
            _ = settings.historyLimit
            _ = settings.toggleHotKey
            _ = settings.sectionHotKeys
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                applyLibrarySettings()
                clipboardStore.limit = settings.historyLimit
                hotKeys.apply()
                observeSettings()
        Automation.installListener(app: self)
            }
        }
    }
}
