import SwiftUI

/// A saved dictation, whole.
struct DictationPreview: View {
    let item: DictationHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    WaveBars(count: 60, height: 28, barWidth: 3)
                    Text(item.text)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
            Text("Dictation · \(item.createdAt.relativeDescription) · \(item.text.split(whereSeparator: \.isWhitespace).count) words")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
    }
}
