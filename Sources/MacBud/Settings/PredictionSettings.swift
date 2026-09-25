import AppKit
import SwiftUI

/// Settings → Prediction: the switches and the numbers. What the models read and wrote is in Prediction Activity.
struct PredictionSettings: View {
    @Bindable var settings: AppSettings
    let predictor: SectionPredictor
    @State private var confirmReset = false

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Every call, prediction and outcome, with the full prompt and reply") {
                    Button("Open Prediction Activity") { PredictionActivityWindow.show(predictor: predictor, settings: settings) }
                }
            }
            SwiftUI.Section {
                Toggle("Predict what you want when MacBud opens", isOn: $settings.prediction.enabled)
                Toggle("Learn with Codex", isOn: $settings.prediction.useModel).disabled(!settings.prediction.enabled)
                status
            } footer: {
                Text("The ring lands on the predicted card; an app opens the Apps filter. Opening never waits for a model. Without a fresh pick, rules choose: a screenshot or dictation from the last minute, else text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Models and limits") {
                modelRow("Driver (predicts)", model: $settings.prediction.driverModel, effort: $settings.prediction.driverEffort)
                modelRow("Reviewer (learns)", model: $settings.prediction.reviewerModel, effort: $settings.prediction.reviewerEffort)
                LabeledContent("Codex CLI", value: predictor.codexPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not found yet")
                Text("Runs on your Codex login with nothing saved to your Codex history; MacBud keeps its own ledger in Prediction Activity.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Review after \(settings.prediction.missThreshold) misses", value: $settings.prediction.missThreshold, in: 1...50)
                Stepper("Or every \(settings.prediction.reviewHours) hours when a miss is waiting", value: $settings.prediction.reviewHours, in: 1...48)
                Stepper("At most \(settings.prediction.dailyCallCap) calls a day", value: $settings.prediction.dailyCallCap, in: 10...300, step: 10)
            }
            SwiftUI.Section("How it is doing") {
                let rates = predictor.rates
                LabeledContent("Model, last 7 days", value: rates.model.text)
                LabeledContent("Rules, last 7 days", value: rates.heuristic.text)
                if rates.model.total > 0 {
                    Text("On the opens the model answered, the rules would have hit \(rates.heuristicWhereModel.text).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Misses waiting for review", value: "\(predictor.unreviewedMisses.count)")
                let usage = PredictionActivity.usageToday(predictor.calls)
                if usage.isEmpty { LabeledContent("Today", value: "No calls") }
                ForEach(usage, id: \.model) { LabeledContent($0.model, value: "\($0.calls) calls · \($0.tokens.formatted()) tokens today") }
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
        .confirmationDialog("Forget all predictions, events and strategies?", isPresented: $confirmReset) {
            Button("Reset memory", role: .destructive) { Task { await predictor.resetMemory() } }
        } message: {
            Text("The call ledger stays, so today's usage and the daily cap stay accurate.")
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
        guard settings.prediction.useModel else { return (false, "Codex is off: rules pick the section.") }
        return switch predictor.status {
        case .waiting: (true, "Waiting for the first call.")
        case .ready: (true, "Ready. Rules cover any moment without a fresh pick.")
        case .off: (false, "Codex is off: rules pick the section.")
        case .missingCLI: (false, "Codex CLI not found in your login shell: rules only.")
        case .capReached: (false, "Daily cap of \(settings.prediction.dailyCallCap) calls reached: rules only until tomorrow.")
        case .failed(let message): (false, "Last call failed: \(message). Rules until it works.")
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
