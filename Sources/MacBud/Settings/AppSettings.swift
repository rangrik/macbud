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
    /// Global shortcuts that open the island on a chip. The key predates chips; `Chip` reads the old tab names.
    var chipHotKeys: [Chip: HotKey] = [:] { didSet { setCodable(chipHotKeys, "sectionHotKeys") } }
    var opensShelfOnHover = true { didSet { set(opensShelfOnHover, "opensShelfOnHover") } }
    var hasSeenWelcome = false { didSet { set(hasSeenWelcome, "hasSeenWelcome") } }
    var clipboardPaused = false { didSet { set(clipboardPaused, "clipboardPaused") } }
    var keyBindings: KeyBindings = .defaults { didSet { setCodable(keyBindings, "keyBindings") } }
    var dictationHotKey: HotKey? = .defaultDictation { didSet { setCodable(dictationHotKey, "dictationHotKey") } }
    var holdToTalkHotKey: HotKey? = .defaultHoldToTalk { didSet { setCodable(holdToTalkHotKey, "holdToTalkHotKey") } }
    var hasMigratedDictationHistory = false { didSet { set(hasMigratedDictationHistory, "hasMigratedDictationHistory") } }
    /// Locale identifier for dictation; empty means "follow the system language".
    var dictationLocale = "" { didSet { set(dictationLocale, "dictationLocale") } }
    /// How long the notch keeps offering "Copy transcript" after a dictation lands in an input.
    var dictationCopyPromptSeconds: Int = 15 {
        didSet { set(dictationCopyPromptSeconds, "dictationCopyPromptSeconds") }
    }
    static let copyPromptChoices = [15, 30, 45, 60]
    var showNotchTab = true { didSet { set(showNotchTab, "showNotchTab") } }
    var prediction = PredictionConfig() { didSet { setCodable(prediction, "prediction") } }
    var hasConfiguredLaunchAtLogin = false { didSet { set(hasConfiguredLaunchAtLogin, "hasConfiguredLaunchAtLogin") } }
    private(set) var disabledFeatures: Set<AppFeature> = [] {
        didSet { set(disabledFeatures.map(\.rawValue).sorted(), "disabledFeatures") }
    }

    static let defaultChipHotKeys: [Chip: HotKey] = [
        .all: HotKey(keyCode: UInt16(kVK_ANSI_V), modifiers: [.option, .shift]),
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
        chipHotKeys = defaults.object(forKey: "sectionHotKeys") == nil ? Self.defaultChipHotKeys : (codable([Chip: HotKey].self, "sectionHotKeys") ?? [:])
        keyBindings = codable(KeyBindings.self, "keyBindings") ?? .defaults
        dictationHotKey = defaults.object(forKey: "dictationHotKey") == nil ? .defaultDictation : codable(HotKey.self, "dictationHotKey")
        holdToTalkHotKey = defaults.object(forKey: "holdToTalkHotKey") == nil ? .defaultHoldToTalk : codable(HotKey.self, "holdToTalkHotKey")
        hasMigratedDictationHistory = defaults.bool(forKey: "hasMigratedDictationHistory")
        dictationLocale = defaults.string(forKey: "dictationLocale") ?? ""
        dictationCopyPromptSeconds = min(max(defaults.object(forKey: "dictationCopyPromptSeconds") as? Int ?? 15, 15), 60)
        showNotchTab = defaults.object(forKey: "showNotchTab") as? Bool ?? true
        prediction = codable(PredictionConfig.self, "prediction") ?? PredictionConfig()
        hasConfiguredLaunchAtLogin = defaults.bool(forKey: "hasConfiguredLaunchAtLogin")
        opensShelfOnHover = defaults.object(forKey: "opensShelfOnHover") as? Bool ?? true
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        clipboardPaused = defaults.bool(forKey: "clipboardPaused")
        disabledFeatures = Set((defaults.stringArray(forKey: "disabledFeatures") ?? []).compactMap(AppFeature.init(rawValue:)))
        isLoading = false
        backfillAppsHotKey()
    }

    /// Anyone upgrading already has a saved shortcut dictionary, so a section added after their last
    /// launch arrives with no global shortcut at all. Fill it in once, and never fight a later edit.
    private func backfillAppsHotKey() {
        guard let wanted = Self.defaultChipHotKeys[.apps], chipHotKeys[.apps] == nil,
              !defaults.bool(forKey: "migratedAppsHotKey") else { return }
        defaults.set(true, forKey: "migratedAppsHotKey")
        guard !chipHotKeys.values.contains(wanted) else { return }
        chipHotKeys[.apps] = wanted
    }

    /// Chips whose feature is on. All stays while anything it can show is on.
    var visibleChips: [Chip] {
        let chips = Chip.allCases.filter { $0.feature.map(isEnabled) ?? false }
        return chips.contains { $0 != .apps } ? [.all] + chips : chips
    }

    /// The kinds of item the owner can reach now; hidden features drop out.
    var visibleKinds: [IntentKind] { IntentKind.available(in: visibleChips) }

    func isEnabled(_ feature: AppFeature) -> Bool { !disabledFeatures.contains(feature) }

    func setEnabled(_ enabled: Bool, for feature: AppFeature) {
        if enabled { disabledFeatures.remove(feature) } else { disabledFeatures.insert(feature) }
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

/// Predicted landing. Stored as one value so new knobs do not each need a key.
nonisolated struct PredictionConfig: Codable, Equatable, Sendable {
    var enabled = true
    /// The kill switch for Codex; off means heuristics only.
    var useModel = true
    var driverModel = "gpt-6-luna"
    var driverEffort = "medium"
    var reviewerModel = "gpt-6-sol"
    var reviewerEffort = "high"
    var missThreshold = 10
    var reviewHours = 12
    var dailyCallCap = 100
    /// The driver starts a new Codex thread after this many turns, or once a turn's input reaches this many tokens.
    var threadTurns = 40
    var threadTokens = 30_000
    static let efforts = ["low", "medium", "high", "xhigh"]

    init() {}

    /// A value saved before a knob existed lacks its key; keep that knob's default instead of resetting them all.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) throws { value = try c.decodeIfPresent(T.self, forKey: key) ?? value }
        try read(.enabled, &enabled); try read(.useModel, &useModel); try read(.driverModel, &driverModel)
        try read(.driverEffort, &driverEffort); try read(.reviewerModel, &reviewerModel); try read(.reviewerEffort, &reviewerEffort)
        try read(.missThreshold, &missThreshold); try read(.reviewHours, &reviewHours); try read(.dailyCallCap, &dailyCallCap)
        try read(.threadTurns, &threadTurns); try read(.threadTokens, &threadTokens)
    }
}
