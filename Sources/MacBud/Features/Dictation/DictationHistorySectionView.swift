import SwiftUI

struct DictationHistorySectionView: View {
    @Bindable var controller: DictationHistorySectionController

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if controller.results.isEmpty {
                    EmptyState(symbol: "clock", title: controller.context.state.query.isEmpty ? "No dictations yet" : "No matches",
                               detail: "Completed dictations appear here. Copy them, insert them, or save them as snippets.")
                } else {
                    ResultsList(items: controller.results, selectedIndex: controller.selectedIndex,
                                onSelect: { controller.selectedIndex = $0 },
                                onActivate: { controller.use(controller.results[$0], insert: controller.context.settings.enterAction == .paste) }) { item, _ in
                        VStack(alignment: .leading, spacing: 5) {
                            HighlightedText(text: item.text, query: controller.context.state.query).lineLimit(2)
                            Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .frame(width: 300)
            Rectangle().fill(Theme.separator).frame(width: 1)
            if let item = controller.selected {
                ScrollView {
                    Text(item.text).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
