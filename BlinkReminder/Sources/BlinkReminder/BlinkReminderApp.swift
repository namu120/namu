import SwiftUI

@main
struct BlinkReminderApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            StatsView()
                .environmentObject(state)
        } label: {
            if state.settings.showCountInMenuBar {
                Label("\(state.blinksLastMinute)", systemImage: state.status.symbol)
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: state.status.symbol)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
