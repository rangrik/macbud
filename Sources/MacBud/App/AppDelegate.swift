import AppKit
import SwiftUI
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
    var clipboardCaptureRunning: Bool { monitor?.isRunning ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = PanelCoordinator(state: notch.state, notch: notch, settings: settings,
                                       clipboardStore: clipboardStore, snippetStore: snippetStore, library: library)
        notch.keyHandler = { [coordinator] event in coordinator!.handle(event: event) }
        notch.willOpen = { [coordinator] in coordinator!.willOpen() }
        notch.contentProvider = { [coordinator] in IslandContentView(state: coordinator!.state, coordinator: coordinator!) }
        notch.dictationProvider = { [coordinator, settings] in
            AnyView(DictationView(controller: coordinator!.dictation, settings: settings,
                                 notchHeight: coordinator!.state.geometry.notchRect.height,
                                 holdingToTalk: coordinator!.isHoldingToTalk,
                                 shortcut: coordinator!.dictationSessionHotKey?.displayString))
        }
        notch.didClose = { [coordinator] in coordinator!.didClose() }
        notch.state.showsNotchTab = settings.showNotchTab
        notch.state.notchStatusSymbol = settings.isEnabled(.clipboard) && settings.clipboardPaused ? "pause.fill" : nil
        coordinator.keepAwake.onChange = { [weak coordinator, weak notch] in
            notch?.state.keepsAwake = coordinator?.keepAwake.isActive ?? false
            if let error = coordinator?.keepAwake.errorMessage { coordinator?.context.showHint(error) }
        }
        notch.install()
        configureLaunchAtLoginIfNeeded()

        clipboardStore.limit = settings.historyLimit
        coordinator.dictationHistoryStore.limit = settings.historyLimit
        Task {
            await clipboardStore.load()
            await snippetStore.load()
            await coordinator.dictationHistoryStore.load()
            await coordinator.dictationWordStore.load()
            if settings.isEnabled(.dictationHistory), !settings.hasMigratedDictationHistory {
                coordinator.dictationHistoryStore.importLegacy(clipboardStore.items, sourceBundleID: Bundle.main.bundleIdentifier ?? "com.rangrik.macbud")
                await coordinator.dictationHistoryStore.flush()
                settings.hasMigratedDictationHistory = true
            }
        }
        monitor = ClipboardMonitor(store: clipboardStore, settings: settings)
        if settings.isEnabled(.clipboard) { monitor.start() }

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
        coordinator?.keepAwake.stop()
        coordinator?.dictation.cancel()
        HotKeyCenter.shared.unregisterAll()
    }

    // MARK: Settings → subsystems

    private func applyLibrarySettings() {
        library.isEnabled = settings.isEnabled(.screenshots)
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
            _ = settings.dictationHotKey
            _ = settings.holdToTalkHotKey
            _ = settings.keyBindings
            _ = settings.showNotchTab
            _ = settings.clipboardPaused
            _ = settings.disabledFeatures
            _ = settings.sectionOrder
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                applyLibrarySettings()
                if settings.isEnabled(.clipboard) { monitor.start() } else { monitor.stop() }
                coordinator.applyFeatureSettings()
                clipboardStore.limit = settings.historyLimit
                coordinator.dictationHistoryStore.limit = settings.historyLimit
                hotKeys.apply()
                notch.state.showsNotchTab = settings.showNotchTab
                notch.state.notchStatusSymbol = settings.isEnabled(.clipboard) && settings.clipboardPaused ? "pause.fill" : nil
                notch.applyBaseFrame(phase: notch.state.basePhase)
                observeSettings()
            }
        }
    }

    // MARK: Launch at login

    /// Like Raycast, MacBud should simply be there after login. Enabled once, the first time the app runs
    /// from an Applications folder (a build directory would leave a dangling login item).
    private func configureLaunchAtLoginIfNeeded() {
        guard !settings.hasConfiguredLaunchAtLogin, Self.isInstalledInApplications else { return }
        settings.launchAtLogin = true
        settings.hasConfiguredLaunchAtLogin = true
        Log.app.info("launch at login enabled on first run: \(self.settings.launchAtLogin)")
    }

    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
