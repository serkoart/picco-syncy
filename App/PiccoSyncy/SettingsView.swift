import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("When the Picco is connected") {
                Toggle("Sync automatically", isOn: $model.autoSync)
                Toggle("Eject after delivering new articles", isOn: $model.autoEject)
            }
            Section("New articles") {
                Toggle("Include images", isOn: $model.includeImages)
                Text("Images are converted to greyscale and sized for the Picco’s screen. Turn this off for smaller, text-only articles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }
}
