import SwiftUI

struct FeaturesSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(settings.sectionOrder) { section in
                    HStack(spacing: 10) {
                        FeatureBadge(kind: section.artwork, size: 22)
                        Toggle(section.title, isOn: enabled(section.feature)).toggleStyle(.checkbox)
                        Spacer()
                        Button { settings.moveSection(section, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(settings.sectionOrder.first == section)
                            .help("Move \(section.title) earlier")
                            .accessibilityLabel("Move \(section.title) earlier")
                        Button { settings.moveSection(section, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(settings.sectionOrder.last == section)
                            .help("Move \(section.title) later")
                            .accessibilityLabel("Move \(section.title) later")
                    }
                }
            } header: {
                Text("Section tabs")
            } footer: {
                Text("Use the arrows to set the tab order. Uncheck a section to hide it. Saved content is kept.")
            }
            SwiftUI.Section("Tools") {
                Toggle("Dictation", isOn: enabled(.dictation)).toggleStyle(.checkbox)
                Toggle("Keep Alive", isOn: enabled(.keepAwake)).toggleStyle(.checkbox)
            }
            SwiftUI.Section {
                Text("Disabled features stop their background work and shortcuts. History can stay available with Dictation off; turning History off stops saving new dictations.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func enabled(_ feature: AppFeature) -> Binding<Bool> {
        Binding(get: { settings.isEnabled(feature) }, set: { settings.setEnabled($0, for: feature) })
    }
}
