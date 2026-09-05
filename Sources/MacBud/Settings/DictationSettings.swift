import Speech
import SwiftUI

struct DictationSettings: View {
    @Bindable var settings: AppSettings
    @State private var supported: [Locale] = []
    @State private var installed: Set<String> = []
    @State private var status: String = "Checking…"
    @State private var downloading = false
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            SwiftUI.Section("Language") {
                Picker("Recognize", selection: $settings.dictationLocale) {
                    Text("System language").tag("")
                    ForEach(supported, id: \.identifier) { locale in
                        Text(label(for: locale)).tag(locale.identifier)
                    }
                }
                LabeledContent("Speech model") {
                    HStack {
                        Text(status)
                        if downloading { ProgressView().controlSize(.small) }
                        Button("Download now") { download() }.disabled(downloading || status.hasPrefix("Installed"))
                    }
                }
                Text("Recognition runs entirely on this Mac. The model for a language is downloaded once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("How it works") {
                LabeledContent("Start") { Text(settings.dictationHotKey?.displayString ?? "No shortcut set — add one in Shortcuts") }
                LabeledContent("While recording") { Text("↩ \(settings.enterAction == .paste ? "inserts into the active app" : "copies to the clipboard") · ⌘↩ does the other · esc cancels") }
                LabeledContent("Microphone") {
                    HStack {
                        StatusDot(ok: microphone == .authorized)
                        Text(microphoneText)
                        if microphone != .authorized {
                            Button("Open Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: settings.dictationLocale) { Task { await refreshStatus() } }
    }

    private var microphoneText: String {
        switch microphone {
        case .authorized: "Allowed"
        case .notDetermined: "macOS will ask the first time you dictate"
        default: "Not allowed"
        }
    }

    private func label(for locale: Locale) -> String {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return installed.contains(locale.identifier(.bcp47)) ? "\(name)  ✓" : name
    }

    private func refresh() async {
        supported = await DictationEngine.supportedLocales().sorted { ($0.identifier) < ($1.identifier) }
        installed = Set(await DictationEngine.installedLocales().map { $0.identifier(.bcp47) })
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        await refreshStatus()
    }

    private func refreshStatus() async {
        guard let locale = await DictationEngine.resolveLocale(preferred: settings.dictationLocale) else { status = "No supported language"; return }
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        switch await DictationEngine.assetStatus(for: locale) {
        case .installed: status = "Installed (\(name))"
        case .downloading: status = "Downloading (\(name))"
        case .supported: status = "Not downloaded yet (\(name))"
        case .unsupported: status = "Unsupported (\(name))"
        @unknown default: status = "Unknown"
        }
    }

    private func download() {
        downloading = true
        Task {
            if let locale = await DictationEngine.resolveLocale(preferred: settings.dictationLocale) {
                do { try await DictationEngine.ensureAssets(for: locale) { fraction in status = "Downloading… \(Int(fraction * 100))%" } }
                catch { status = error.localizedDescription }
            }
            downloading = false
            await refreshStatus()
        }
    }
}
