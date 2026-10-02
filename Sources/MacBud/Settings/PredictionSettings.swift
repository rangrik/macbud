import AppKit
import SwiftUI

/// Settings → Prediction: the switches and the numbers. What the models read and wrote is in Prediction Activity.
struct PredictionSettings: View {
    @Bindable var settings: AppSettings
    let predictor: SectionPredictor
    @State private var confirmReset = false
    @State private var accessibilityTrusted = Paster.isAccessibilityTrusted

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Every call, prediction and outcome, with the full prompt and reply") {
                    Button("Open Prediction Activity") { PredictionActivityWindow.show(predictor: predictor, settings: settings) }
                }
            }
            SwiftUI.Section {
                Toggle("Predict what you want when MacBud opens", isOn: $settings.prediction.enabled)
                Toggle("Ask Jev and Codex", isOn: $settings.prediction.useModel).disabled(!settings.prediction.enabled)
                status
            } footer: {
                Text("The ring lands on the predicted card; an app opens its card or the Apps filter. With no current pick, opening may wait up to 0.3 s for Jev. Without a pick, rules choose: a screenshot or dictation from the last minute, else text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Activity context") {
                activity
            }
            SwiftUI.Section("Models and limits") {
                LabeledContent("Driver (picks the landing)", value: "Jev (\(SectionPredictor.jevModel)) on TypeSafe")
                modelRow("Luna (in the shadow)", model: $settings.prediction.lunaModel, effort: $settings.prediction.lunaEffort)
                modelRow("Reviewer (learns)", model: $settings.prediction.reviewerModel, effort: $settings.prediction.reviewerEffort)
                LabeledContent("Codex CLI, for Luna and the reviewer",
                               value: predictor.codexPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not found yet")
                Text(CodexRunner.signedIn
                     ? "Luna runs on MacBud's own Codex sign-in and resumes one thread, so each call sends only what changed. Nothing lands in your Codex history; MacBud keeps its own ledger in Prediction Activity."
                     : "Each Luna call starts a new session on your Codex login. To keep one thread instead, so most of each call comes from Codex's cache, sign MacBud in once in Terminal:\nCODEX_HOME=\"\(CodexRunner.home.path)\" codex login --device-auth")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Stepper("Review after \(settings.prediction.missThreshold) misses", value: $settings.prediction.missThreshold, in: 1...50)
                Stepper("Or every \(settings.prediction.reviewHours) hours when a miss is waiting", value: $settings.prediction.reviewHours, in: 1...48)
                Stepper("At most \(settings.prediction.dailyCallCap) Jev and reviewer calls a day", value: $settings.prediction.dailyCallCap, in: 10...300, step: 10)
                Text("Jev warms up at most every 10 minutes when what you are doing changes, and is asked when an open has no current pick. Luna is asked only with an open's Jev call, outside the cap.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("New Luna thread after \(settings.prediction.threadTurns) calls", value: $settings.prediction.threadTurns, in: 5...200, step: 5)
                Stepper("Or once a call sends \(settings.prediction.threadTokens / 1000)k tokens", value: $settings.prediction.threadTokens,
                        in: 10_000...100_000, step: 5_000)
            }
            ForEach(predictor.cohorts, id: \.title) { cohort in
                SwiftUI.Section(cohort.title) {
                    ForEach(cohort.rows, id: \.label) { LabeledContent($0.label, value: $0.rate.text) }
                }
            }
            SwiftUI.Section {
                Text(caveat).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Misses waiting for review", value: "\(predictor.unreviewedMisses.count)")
                let usage = PredictionActivity.usageToday(predictor.calls)
                if usage.isEmpty { LabeledContent("Today", value: "No calls") }
                ForEach(usage, id: \.model) { LabeledContent($0.model, value: "\($0.calls) calls · \($0.tokens.formatted()) tokens (\($0.cached.formatted()) cached) today") }
            }
            SwiftUI.Section {
                HStack {
                    Button("Review now") { Task { await predictor.review() } }
                        .disabled(predictor.isBusy || !settings.prediction.useModel || predictor.sessions.isEmpty)
                    Button("Open memory folder") {
                        try? FileManager.default.createDirectory(at: predictor.memory.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(predictor.memory.directory)
                    }
                    Spacer()
                    Button("Reset memory…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget all predictions, events, activity and strategies?", isPresented: $confirmReset) {
            Button("Reset memory", role: .destructive) { Task { await predictor.resetMemory() } }
        } message: {
            Text("The call ledger stays, so today's usage and the daily cap stay accurate. It and MacBud's Codex sessions keep copies of what was sent, activity included.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = Paster.isAccessibilityTrusted
        }
    }

    /// Comparisons on the same opens appear only once there are such opens.
    private var caveat: String {
        let jev = predictor.rates.jev
        var text = "Each period counts only its own opens, so old results never count as Jev's. Different weeks are not a fair test: a gap between periods does not show the swap helped. Luna answers only the opens that asked Jev, so it has fewer samples."
        if jev.rulesWhereModel.total > 0 { text += " On the opens Jev answered, the rules would have hit \(jev.rulesWhereModel.text)." }
        if jev.landedWhereShadow.total > 0 { text += " On the opens Luna answered, the landing hit \(jev.landedWhereShadow.text)." }
        return text
    }

    private var activity: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: settings.prediction.enabled && accessibilityTrusted)
            if !settings.prediction.enabled {
                Text("Off while prediction is off.")
            } else if accessibilityTrusted {
                Text("On. The last 10 minutes of apps, window titles, web addresses and the focused field's kind go with every model call. Kept on this Mac for a day, never field text or screen pixels.")
            } else {
                Text("Activity context is paused until Accessibility is allowed.")
                Spacer()
                Button("Open System Settings") { Paster.promptForAccessibility(); Paster.openAccessibilitySettings() }
            }
        }
    }

    private var status: some View {
        let (ok, text) = statusText
        return HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: ok)
            Text(text)
        }
    }

    private var statusText: (Bool, String) {
        guard settings.prediction.enabled else { return (false, "Off: opening follows General › Reopen the last used section.") }
        guard settings.prediction.useModel else { return (false, "Models are off: rules pick the landing.") }
        return switch predictor.status {
        case .waiting: (true, "Waiting for Jev's first call.")
        case .ready: (true, "Jev is ready. Rules cover any moment without a current pick.")
        case .off: (false, "Models are off: rules pick the landing.")
        case .missingKey: (false, "No TypeSafe API key for Jev: rules only.")
        case .capReached: (false, "Daily cap of \(settings.prediction.dailyCallCap) calls reached: rules only until tomorrow.")
        case .failed(let message): (false, "Jev's last call failed: \(message). Rules until it works.")
        }
    }

    private func modelRow(_ title: String, model: Binding<String>, effort: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: model).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 140)
                Picker(title, selection: effort) { ForEach(PredictionConfig.efforts, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 90)
            }
        }
    }
}
