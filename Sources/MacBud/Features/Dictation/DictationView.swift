import SwiftUI

/// Compact dictation pill under the notch: live transcript, level meter, timer and key hints.
struct DictationView: View {
    let controller: DictationController
    let settings: AppSettings
    let notchHeight: CGFloat

    var body: some View {
        let enterPastes = settings.enterAction == .paste
        VStack(spacing: 0) {
            Spacer().frame(height: notchHeight)
            HStack(alignment: .center, spacing: 14) {
                indicator
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 6) {
                    transcriptText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Text(timerText)
                            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        LevelMeter(levels: controller.levels, active: controller.phase == .recording)
                            .frame(width: 120, height: 14)
                        if let locale = controller.locale {
                            Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    switch controller.phase {
                    case .failed:
                        KeyHint(keys: "↩", label: "Retry", emphasized: true)
                        KeyHint(keys: "esc", label: "Discard")
                    default:
                        KeyHint(keys: "↩", label: enterPastes ? "Insert" : "Copy", emphasized: true)
                        KeyHint(keys: "⌘↩", label: enterPastes ? "Copy" : "Insert")
                        KeyHint(keys: "esc", label: "Cancel")
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var indicator: some View {
        switch controller.phase {
        case .recording:
            ZStack {
                Circle().fill(Color.red.opacity(0.18))
                Circle().fill(Color.red).frame(width: 12, height: 12)
                    .symbolEffect(.pulse)
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).opacity(0.0)
            }
        case .finalizing, .preparing:
            ProgressView().controlSize(.small).tint(.white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(Theme.warning)
        case .idle:
            Image(systemName: "mic").font(.system(size: 18)).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var transcriptText: some View {
        switch controller.phase {
        case .preparing(let message):
            Text(message).font(Theme.body).foregroundStyle(Theme.textSecondary)
        case .failed(let message):
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.warning).lineLimit(2)
        case .finalizing:
            Text(controller.transcript.isEmpty ? "Finishing…" : controller.transcript)
                .font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(2).truncationMode(.head)
        case .recording, .idle:
            if controller.transcript.isEmpty {
                Text("Listening… start talking").font(Theme.body).foregroundStyle(Theme.textTertiary)
            } else {
                Text(controller.transcript)
                    .font(Theme.body).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).truncationMode(.head)
            }
        }
    }

    private var timerText: String {
        let total = Int(controller.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Bars that follow the recent microphone level, newest on the right.
struct LevelMeter: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(active ? Color.red.opacity(0.85) : Theme.textTertiary)
                    .frame(width: 2.4, height: max(2, CGFloat(level) * 14))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}
