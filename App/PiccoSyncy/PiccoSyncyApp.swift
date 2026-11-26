import SwiftUI

@main
struct PiccoSyncyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu-bar icon: a book (filled while the Picco is plugged in), plus how many articles are waiting.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let waiting = model.waiting.count
        HStack(spacing: 3) {
            Image(systemName: model.isSyncing ? "arrow.triangle.2.circlepath" : (model.device != nil ? "book.fill" : "book.closed"))
            if waiting > 0 { Text("\(waiting)") }
        }
        .accessibilityLabel(waiting > 0 ? "Picco Syncy, \(waiting) waiting" : "Picco Syncy")
    }
}
