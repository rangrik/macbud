import AppKit
import SwiftUI

/// Settings → Prediction: the switches, the numbers, and everything the models read and wrote.
struct PredictionSettings: View {
    @Bindable var settings: AppSettings
    let predictor: SectionPredictor
    @State private var confirmReset = false

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Open on the predicted section", isOn: $settings.prediction.enabled)
                Toggle("Learn with Codex", isOn: $settings.prediction.useModel).disabled(!settings.prediction.enabled)
                status
            } footer: {
                Text("Opening never waits for a model. Without a fresh pick, rules choose: a screenshot or dictation from the last minute, else Clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Models and limits") {
                modelRow("Driver (predicts)", model: $settings.prediction.driverModel, effort: $settings.prediction.driverEffort)
                modelRow("Reviewer (learns)", model: $settings.prediction.reviewerModel, effort: $settings.prediction.reviewerEffort)
                LabeledContent("Codex CLI", value: predictor.codexPath ?? "Not found yet")
                Text("Runs on your Codex login with nothing saved to your Codex history; MacBud keeps its own ledger below.")
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
                let usage = usageToday
                if usage.isEmpty { LabeledContent("Today", value: "No calls") }
                ForEach(usage, id: \.model) { LabeledContent($0.model, value: "\($0.calls) calls · \($0.tokens) tokens today") }
            }
            SwiftUI.Section {
                if predictor.strategies.isEmpty {
                    Text("None yet. The reviewer writes these once misses build up.").foregroundStyle(.secondary)
                } else {
                    Text(predictor.strategies).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            } header: {
                Text("Strategies the driver reads" + (predictor.lastReview.map { " · written \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
            }
            SwiftUI.Section("Recent opens") {
                if predictor.sessions.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(predictor.sessions.suffix(10).reversed()) { sessionRow($0) }
            }
            SwiftUI.Section("Activity: what each call sent and received") {
                if predictor.calls.isEmpty { Text("No calls yet.").foregroundStyle(.secondary) }
                ForEach(predictor.calls.suffix(20).reversed()) { PredictionCallRow(call: $0) }
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
                TextField(title, text: model).labelsHidden().frame(width: 140)
                Picker(title, selection: effort) { ForEach(PredictionConfig.efforts, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 90)
            }
        }
    }

    private var usageToday: [(model: String, calls: Int, tokens: Int)] {
        let today = predictor.calls.filter { Calendar.current.isDateInToday($0.t) }
        return Dictionary(grouping: today, by: \.model)
            .map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + ($1.tokens?.input ?? 0) + ($1.tokens?.output ?? 0) }) }
            .sorted { $0.model < $1.model }
    }

    private func describe(_ intent: LandingIntent) -> String { PredictionPrompts.describe(intent) }

    private func sessionRow(_ s: SessionRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: s.hit == true ? "checkmark.circle.fill" : s.hit == false ? "xmark.circle.fill" : "circle.dashed")
                .foregroundStyle(s.hit == true ? .green : s.hit == false ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.t.formatted(date: .omitted, time: .shortened)) · opened \(s.opened.title) for \(describe(s.landed)) by \(s.source == "model" ? "model" : "rules") · "
                     + (s.outcome.map { "used \($0.kind.rawValue)" + ($0.newest.map { $0 ? " (newest)" : " (older)" } ?? "") } ?? "used nothing"))
                Text("app \(s.context.app ?? "–") · rules said \(s.heuristic.map(describe) ?? "–") · model said \(s.model.map { describe($0.intent) } ?? "–")"
                     + (s.model.map { ": \($0.note)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One model call; expands to the exact prompt and reply.
struct PredictionCallRow: View {
    let call: CallRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sent").font(.caption.bold())
                Text(call.prompt).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text(call.error.map { "Received · \($0)" } ?? "Received").font(.caption.bold())
                Text(call.reply ?? "Nothing").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        } label: {
            HStack {
                StatusDot(ok: call.status == "ok")
                Text("\(call.t.formatted(date: .omitted, time: .shortened)) · \(call.purpose) · \(call.model) \(call.effort)")
                Spacer()
                Text(String(format: "%.1f s", Double(call.ms) / 1000) + " · \((call.tokens?.input ?? 0) + (call.tokens?.output ?? 0)) tokens")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
