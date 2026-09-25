import SwiftUI

struct FeaturesSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(Self.items, id: \.feature) { item in
                    HStack(spacing: 10) {
                        FeatureBadge(kind: item.art, size: 22)
                        Toggle(item.feature.title, isOn: enabled(item.feature)).toggleStyle(.checkbox)
                        Spacer()
                        Text(item.chips).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What the shelf shows")
            } footer: {
                Text("Unchecking a feature hides its filters and its items. Saved content is kept.")
            }
            SwiftUI.Section("Tools") {
                Toggle("Dictation", isOn: enabled(.dictation)).toggleStyle(.checkbox)
                Toggle("Keep Alive", isOn: enabled(.keepAwake)).toggleStyle(.checkbox)
                Toggle("Clock", isOn: enabled(.clock)).toggleStyle(.checkbox)
            }
            SwiftUI.Section {
                Text("Disabled features stop their background work and shortcuts. History can stay available with Dictation off; turning History off stops saving new dictations.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static let items: [(feature: AppFeature, art: FeatureArt, chips: String)] = [
        (.clipboard, .clipboard, "Text, Links, Images"), (.screenshots, .screenshots, "Screenshots"),
        (.dictationHistory, .dictation, "Dictations"), (.snippets, .snippets, "Snippets"), (.apps, .apps, "Apps"),
    ]

    private func enabled(_ feature: AppFeature) -> Binding<Bool> {
        Binding(get: { settings.isEnabled(feature) }, set: { settings.setEnabled($0, for: feature) })
    }
}
