import AppKit
import SwiftUI

/// 唯一持有设置窗口的控制器。
///
/// 菜单栏应用（`LSUIElement`）没有 Dock 图标，系统不会自动激活它；
/// 每次点击设置都显式激活应用并复用同一个窗口，避免重复窗口和“点了没反应”。
/// 窗口使用稳定 identifier，不依赖随语言变化的标题。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    /// 稳定身份；窗口标题可以随中英文切换，但查找从不依赖标题。
    static let windowIdentifier = NSUserInterfaceItemIdentifier(
        "com.standuptimer.menubar.settings"
    )

    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?

    private init() {}

    func show(model: TimerModel) {
        let window = existingWindow ?? makeWindow(model: model)

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
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.view.layoutSubtreeIfNeeded()

        let window = NSWindow(contentViewController: hosting)
        window.identifier = Self.windowIdentifier
        window.title = SettingsView.windowTitle(for: model.language)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // 只在展示时参与正常窗口层级；切到其他应用后不保持置顶。
        window.level = .normal
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.setContentSize(hosting.view.fittingSize)
        window.center()

        self.hostingController = hosting
        self.window = window
        return window
    }
}
