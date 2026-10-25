import SwiftUI

@main
struct StandUpTimerApp: App {
    @StateObject private var model = TimerModel()

    var body: some Scene {
        MenuBarExtra {
            TimerMenuView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.menuBarSymbolName)
                    .symbolRenderingMode(.hierarchical)
                if model.showsTimeInMenuBar {
                    Text(model.remainingText)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.menuBarAccessibilityLabel))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
