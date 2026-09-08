import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// User preferences, persisted in UserDefaults. Observable so views update live.
@Observable
final class AppSettings {
    enum EnterAction: String, Codable, CaseIterable, Sendable {
        case copy, paste
        var title: String { self == .copy ? "Copy to clipboard" : "Paste into the active app" }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = true

    var historyLimit: Int = 500 { didSet { set(historyLimit, "historyLimit") } }
    var enterAction: EnterAction = .copy { didSet { set(enterAction.rawValue, "enterAction") } }
    var showToasts = true { didSet { set(showToasts, "showToasts") } }
    var ignoredBundleIDs: [String] = AppSettings.defaultIgnoredBundleIDs { didSet { set(ignoredBundleIDs, "ignoredBundleIDs") } }
    var screenshotFolders: [String] = [] { didSet { set(screenshotFolders, "screenshotFolders") } }
    var includeSubfolders = false { didSet { set(includeSubfolders, "includeSubfolders") } }
    var includeVideos = true { didSet { set(includeVideos, "includeVideos") } }
    var toggleHotKey: HotKey? = .defaultToggle { didSet { setCodable(toggleHotKey, "toggleHotKey") } }
    var sectionHotKeys: [Section: HotKey] = [:] { didSet { setCodable(sectionHotKeys, "sectionHotKeys") } }
    var rememberLastSection = true { didSet { set(rememberLastSection, "rememberLastSection") } }
    var lastSection: Section = .clipboard { didSet { set(lastSection.rawValue, "lastSection") } }
    var hasSeenWelcome = false { didSet { set(hasSeenWelcome, "hasSeenWelcome") } }
    var clipboardPaused = false { didSet { set(clipboardPaused, "clipboardPaused") } }
    var keyBindings: KeyBindings = .defaults { didSet { setCodable(keyBindings, "keyBindings") } }
    var dictationHotKey: HotKey? = .defaultDictation { didSet { setCodable(dictationHotKey, "dictationHotKey") } }
    var holdToTalkHotKey: HotKey? = .defaultHoldToTalk { didSet { setCodable(holdToTalkHotKey, "holdToTalkHotKey") } }
    var hasMigratedDictationHistory = false { didSet { set(hasMigratedDictationHistory, "hasMigratedDictationHistory") } }
    /// Locale identifier for dictation; empty means "follow the system language".
    var dictationLocale = "" { didSet { set(dictationLocale, "dictationLocale") } }
    var showNotchTab = true { didSet { set(showNotchTab, "showNotchTab") } }
    var hasConfiguredLaunchAtLogin = false { didSet { set(hasConfiguredLaunchAtLogin, "hasConfiguredLaunchAtLogin") } }
    private(set) var sectionOrder: [Section] = Section.allCases {
        didSet { set(sectionOrder.map(\.rawValue), "sectionOrder") }
    }
    private(set) var disabledFeatures: Set<AppFeature> = [] {
        didSet { set(disabledFeatures.map(\.rawValue).sorted(), "disabledFeatures") }
    }

    static let defaultSectionHotKeys: [Section: HotKey] = [
        .clipboard: HotKey(keyCode: UInt16(kVK_ANSI_V), modifiers: [.option, .shift]),
        .snippets: HotKey(keyCode: UInt16(kVK_ANSI_S), modifiers: [.option, .shift]),
        .screenshots: HotKey(keyCode: UInt16(kVK_ANSI_4), modifiers: [.option, .shift]),
        .apps: HotKey(keyCode: UInt16(kVK_ANSI_A), modifiers: [.option, .shift]),
    ]

    static let defaultIgnoredBundleIDs = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess", "com.bitwarden.desktop", "com.apple.Passwords",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyLimit = defaults.object(forKey: "historyLimit") as? Int ?? 500
        enterAction = (defaults.string(forKey: "enterAction")).flatMap(EnterAction.init(rawValue:)) ?? .copy
        showToasts = defaults.object(forKey: "showToasts") as? Bool ?? true
        ignoredBundleIDs = defaults.stringArray(forKey: "ignoredBundleIDs") ?? Self.defaultIgnoredBundleIDs
        screenshotFolders = defaults.stringArray(forKey: "screenshotFolders") ?? [Self.systemScreenshotFolder().path]
        includeSubfolders = defaults.bool(forKey: "includeSubfolders")
        includeVideos = defaults.object(forKey: "includeVideos") as? Bool ?? true
        toggleHotKey = defaults.object(forKey: "toggleHotKey") == nil ? .defaultToggle : codable(HotKey.self, "toggleHotKey")
        sectionHotKeys = defaults.object(forKey: "sectionHotKeys") == nil ? Self.defaultSectionHotKeys : (codable([Section: HotKey].self, "sectionHotKeys") ?? [:])
        keyBindings = codable(KeyBindings.self, "keyBindings") ?? .defaults
        dictationHotKey = defaults.object(forKey: "dictationHotKey") == nil ? .defaultDictation : codable(HotKey.self, "dictationHotKey")
        holdToTalkHotKey = defaults.object(forKey: "holdToTalkHotKey") == nil ? .defaultHoldToTalk : codable(HotKey.self, "holdToTalkHotKey")
        hasMigratedDictationHistory = defaults.bool(forKey: "hasMigratedDictationHistory")
        dictationLocale = defaults.string(forKey: "dictationLocale") ?? ""
        showNotchTab = defaults.object(forKey: "showNotchTab") as? Bool ?? true
        hasConfiguredLaunchAtLogin = defaults.bool(forKey: "hasConfiguredLaunchAtLogin")
        rememberLastSection = defaults.object(forKey: "rememberLastSection") as? Bool ?? true
        lastSection = defaults.string(forKey: "lastSection").flatMap(Section.init(rawValue:)) ?? .clipboard
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        clipboardPaused = defaults.bool(forKey: "clipboardPaused")
        sectionOrder = Self.normalizedSectionOrder((defaults.stringArray(forKey: "sectionOrder") ?? []).compactMap(Section.init(rawValue:)))
        disabledFeatures = Set((defaults.stringArray(forKey: "disabledFeatures") ?? []).compactMap(AppFeature.init(rawValue:)))
        isLoading = false
        backfillAppsHotKey()
    }

    /// Anyone upgrading already has a saved shortcut dictionary, so a section added after their last
    /// launch arrives with no global shortcut at all. Fill it in once, and never fight a later edit.
    private func backfillAppsHotKey() {
        guard let wanted = Self.defaultSectionHotKeys[.apps], sectionHotKeys[.apps] == nil,
              !defaults.bool(forKey: "migratedAppsHotKey") else { return }
        defaults.set(true, forKey: "migratedAppsHotKey")
        guard !sectionHotKeys.values.contains(wanted) else { return }
        sectionHotKeys[.apps] = wanted
    }

    var enabledSections: [Section] { sectionOrder.filter { isEnabled($0.feature) } }

    func isEnabled(_ feature: AppFeature) -> Bool { !disabledFeatures.contains(feature) }

    func setEnabled(_ enabled: Bool, for feature: AppFeature) {
        if enabled { disabledFeatures.remove(feature) } else { disabledFeatures.insert(feature) }
    }

    func setSectionOrder(_ sections: [Section]) { sectionOrder = Self.normalizedSectionOrder(sections) }

    func moveSection(_ section: Section, by offset: Int) {
        guard let index = sectionOrder.firstIndex(of: section), sectionOrder.indices.contains(index + offset) else { return }
        sectionOrder.swapAt(index, index + offset)
    }

    private static func normalizedSectionOrder(_ sections: [Section]) -> [Section] {
        var seen: Set<Section> = []
        return (sections + Section.allCases).filter { seen.insert($0).inserted }
    }

    var screenshotFolderURLs: [URL] { screenshotFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } }

    // MARK: Launch at login (SMAppService)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("launch at login change failed: \(error.localizedDescription)")
            }
        }
    }

    /// Where macOS itself saves screenshots (`defaults read com.apple.screencapture location`), else ~/Desktop.
    static func systemScreenshotFolder() -> URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    // MARK: Persistence helpers

    private func set(_ value: Any?, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func setCodable<T: Encodable>(_ value: T?, _ key: String) {
        guard !isLoading else { return }
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        else { defaults.set(Data(), forKey: key) }
    }

    private func codable<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
