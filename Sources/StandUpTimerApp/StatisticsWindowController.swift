import AppKit
import SwiftUI

/// 唯一持有统计窗口的控制器，模式与 `SettingsWindowController` 对齐。
///
/// 菜单栏应用（`LSUIElement`）没有 Dock 图标，系统不会自动激活它；
/// 每次打开都显式激活并复用同一个窗口，避免重复窗口。窗口使用稳定
/// identifier，不依赖随语言变化的标题。复用的窗口不会重新触发
/// SwiftUI 的 onAppear，因此每次 show 都显式 `reload()` 并重设标题。
@MainActor
final class StatisticsWindowController {
    static let shared = StatisticsWindowController()

    /// 稳定身份；窗口标题可以随中英文切换，但查找从不依赖标题。
    static let windowIdentifier = NSUserInterfaceItemIdentifier(
        "com.standuptimer.timer.statistics"
    )

    private var window: NSWindow?
    private var hostingController: NSHostingController<StatisticsView>?
    private var viewModel: StatisticsViewModel?

    private init() {}

    func show(model: TimerModel) {
        let window = existingWindow ?? makeWindow(model: model)

        // 重开窗口时显式刷新：记录、通知状态与语言都可能在关闭期间变化。
        viewModel?.reload()
        window.title = StatisticsView.windowTitle(for: model.language)

        NSApp.activate(ignoringOtherApps: true)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
    }

    private var existingWindow: NSWindow? {
        window
    }

    private func makeWindow(model: TimerModel) -> NSWindow {
        let viewModel = StatisticsViewModel(model: model)
        let hosting = NSHostingController(rootView: StatisticsView(viewModel: viewModel))
        hosting.view.layoutSubtreeIfNeeded()

        let window = NSWindow(contentViewController: hosting)
        window.identifier = Self.windowIdentifier
        window.title = StatisticsView.windowTitle(for: model.language)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // 只在展示时参与正常窗口层级；切到其他应用后不保持置顶。
        window.level = .normal
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.setContentSize(NSSize(width: 640, height: 600))
        window.minSize = NSSize(width: 560, height: 480)
        window.center()

        self.viewModel = viewModel
        self.hostingController = hosting
        self.window = window
        return window
    }
}
