import SwiftUI

/// A passive recording overlay: waveform, transcript, then the same quiet action strip as the island.
struct DictationView: View {
    let controller: DictationController
    let settings: AppSettings
    let notchHeight: CGFloat
    var holdingToTalk = false
    var shortcut: String?
    /// Pointing at the transcript shrinks the meter and gives the words its room.
    @State private var hoveringTranscript = false
    var onLinesChanged: (Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight + 6)
            LevelMeter(levels: controller.levels, active: controller.phase == .recording && !controller.isEditingTranscript)
                .frame(height: hoveringTranscript || controller.isEditingTranscript ? 8 : 32)
                .padding(.horizontal, 20)
                .animation(.easeOut(duration: 0.18), value: hoveringTranscript)
                .animation(.easeOut(duration: 0.18), value: controller.isEditingTranscript)
            HStack(spacing: 8) {
                Text(status).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                if isPreparing || controller.phase == .finalizing {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                Spacer()
                Text("On-device").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Text(timerText).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 20).padding(.top, 5)

            Group {
                if showsEditor {
                    DictationTranscriptEditor(
                        document: controller.document,
                        isEditing: controller.isEditingTranscript,
                        placeholder: displayText,
                        onBeginEditing: { controller.beginEdit() },
                        onCommit: { controller.commitEdit($0) },
                        onLinesChanged: onLinesChanged)
                } else {
                    Text(displayText)
                        .font(.system(size: 14)).foregroundStyle(transcriptColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onHover { hoveringTranscript = $0 }
            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack(spacing: 12) {
                if holdingToTalk, controller.phase == .recording {
                    Text("Release to insert").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                switch controller.phase {
                case .recording where controller.isEditingTranscript:
                    action("Done", keys: "⏎") { controller.commitEdit(nil) }
                case .recording:
                    action("Copy", systemImage: "doc.on.doc") { controller.finish(.copy) }
                    action("Insert", keys: holdingToTalk ? "" : (shortcut ?? settings.dictationHotKey?.displayString ?? "")) {
                        controller.finish(.insert)
                    }
                    action("Cancel", keys: "⎋") { controller.cancel() }
                case .failed:
                    action("Retry") { controller.retry() }.disabled(!controller.canRetry)
                    action("Discard", keys: "⎋") { controller.cancel() }
                case .preparing, .finalizing:
                    action("Cancel", keys: "⎋") { controller.cancel() }
                case .idle: EmptyView()
                }
            }
            .padding(.horizontal, 16).frame(height: 38)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func action(_ title: String, keys: String = "", systemImage: String? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { KeyHint(keys: keys, label: title, systemImage: systemImage) }
            .buttonStyle(FooterHintButtonStyle())
            .accessibilityLabel(title)
    }

    private var isPreparing: Bool { if case .preparing = controller.phase { true } else { false } }
    /// The transcript is a real text field while recording, so you can fix it where it stands.
    private var showsEditor: Bool {
        switch controller.phase {
        case .recording, .finalizing: true
        default: false
        }
    }
    private var status: String {
        switch controller.phase {
        case .recording: controller.isEditingTranscript ? "Paused · editing" : "Listening"
        case .preparing: "Preparing"
        case .finalizing: "Finishing"
        case .failed: "Recording paused"
        case .idle: "Dictation"
        }
    }
    private var displayText: String {
        switch controller.phase {
        case .preparing(let message), .failed(let message): message
        case .finalizing: controller.transcript.isEmpty ? "Finishing your recording…" : controller.transcript
        case .recording, .idle: controller.transcript.isEmpty ? "Start talking…" : controller.transcript
        }
    }
    private var transcriptColor: Color {
        if case .failed = controller.phase { return Theme.warning }
        return controller.transcript.isEmpty ? Theme.textTertiary : Theme.textPrimary
    }
    private var timerText: String {
        let total = Int(controller.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct LevelMeter: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let bars = max(1, Int(size.width / 4))
            for index in 0..<bars {
                let sample = levels.isEmpty ? Float(0) : levels[min(levels.count - 1, index * levels.count / bars)]
                let height = max(2, CGFloat(sample) * size.height)
                let rect = CGRect(x: CGFloat(index) * size.width / CGFloat(bars), y: (size.height - height) / 2,
                                  width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(active ? Color(red: 0.76, green: 0.57, blue: 1) : Theme.textTertiary))
            }
        }
        .accessibilityLabel("Microphone level")
    }
}
