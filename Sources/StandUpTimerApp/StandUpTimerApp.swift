import AppKit
import StandUpTimerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: TimerModel?
    private var statusItemController: StatusItemPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须先迁移再建模：模型启动时会立刻读取并回写设置。
        LegacyPreferences.migrateIfNeeded()
        let model = TimerModel()
        self.model = model
        statusItemController = StatusItemPanelController(model: model)
    }

    // 代理型应用（LSUIElement）没有常规窗口，关闭最后一个窗口
    // （设置窗）不应终止进程，菜单栏图标和计时继续运行。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
enum StandUpTimerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 双保险：即使 Info.plist 的 LSUIElement 缺失（如 swift run 调试），
        // 也不在 Dock 显示图标，保持纯菜单栏应用形态。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
