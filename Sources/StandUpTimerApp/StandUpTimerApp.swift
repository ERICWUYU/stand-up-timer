import SwiftUI
import StandUpTimerCore

@main
struct StandUpTimerApp: App {
    @StateObject private var model: TimerModel

    init() {
        // 必须先迁移再建模：模型启动时会立刻读取并回写设置。
        LegacyPreferences.migrateIfNeeded()
        _model = StateObject(wrappedValue: TimerModel())
    }

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
    }
}
