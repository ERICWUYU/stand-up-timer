import AppKit
import Combine
import SwiftUI

/// 自管的状态栏入口与下拉面板。
///
/// 用 `NSStatusItem` + 自管 `NSPanel` 取代 SwiftUI 的
/// `MenuBarExtra(.window)`：后者的窗口由系统持有，会在安全区内再绘制
/// 一层自带背景，与自定义背景叠加产生无法消除的上下色差，且替换其
/// contentView 会触发 SwiftUI 前置条件崩溃。这里窗口、背景层级和内容
/// 全部由本控制器拥有，整个面板只有一套连续背景。
///
/// 窗口层级（根容器负责唯一的圆角裁剪，所有子视图都在其内部）：
///   PanelWindow (NSPanel, borderless / nonactivating)
///   └─ contentView = PanelRootView（透明 NSView，唯一圆角裁剪，不绘制描边）
///      ├─ NSVisualEffectView（.menu 系统材质，maskImage 显式裁掉 backdrop 圆角）
///      └─ NSHostingView<TimerMenuView>（透明背景，铺满）
///
/// 面板不指定 NSAppearance，随系统 Light/Dark 自动切换；材质和
/// SwiftUI 语义色均按当前 effectiveAppearance 实时解析，面板边缘
/// 只由系统材质与窗口自然阴影定义。
@MainActor
final class StatusItemPanelController {
    private let model: TimerModel
    private let statusItem: NSStatusItem

    private var panel: PanelWindow?
    private var sizeObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?

    init(model: TimerModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        refreshStatusItem()

        // 模型每秒 tick 及任何状态变化都同步到状态栏。objectWillChange
        // 在下一个主线程周期取值，确保读到的是已更新的属性。
        model.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshStatusItem()
                }
            }
            .store(in: &cancellables)

        installEventMonitors()
        installScreenChangeObserver()
    }

    /// 显式清理入口。控制器与进程同生命周期，init 只注册一次监听，
    /// 不存在重复注册；仅在需要提前拆除（如测试）时调用。
    func shutdown() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        sizeObservation?.invalidate()
        sizeObservation = nil
        panel?.orderOut(nil)
    }

    // MARK: - 状态栏按钮

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.imagePosition = .imageLeading
        button.font = NSFont.menuBarFont(ofSize: 0)
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }

        let symbol = NSImage(
            systemSymbolName: model.menuBarSymbolName,
            accessibilityDescription: nil
        )
        let config = NSImage.SymbolConfiguration(
            pointSize: NSFont.menuBarFont(ofSize: 0).pointSize + 1,
            weight: .medium
        )
        button.image = symbol?.withSymbolConfiguration(config)
        button.image?.isTemplate = true

        if model.showsTimeInMenuBar {
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
                weight: .regular
            )
            button.attributedTitle = NSAttributedString(
                string: model.remainingText,
                attributes: [.font: font]
            )
        } else {
            button.attributedTitle = NSAttributedString()
        }
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)
    }

    // MARK: - 面板显隐

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // 每次展示都重新读取通知权限：NSHostingView 会被复用，
        // SwiftUI 的 onAppear 只在首次出现时触发，无法覆盖重开场景。
        model.refreshNotificationPermission()
        let panel = panel ?? makePanel()
        positionPanel(panel)
        // nonactivating 面板可以取得 key 状态而不激活整个应用，
        // 面板内按钮和 Escape 键盘事件因此可用，且不抢其他 App 的焦点。
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.isHighlighted = true
    }

    private func closePanel() {
        panel?.orderOut(nil)
        statusItem.button?.isHighlighted = false
    }

    /// 面板内 Settings 按钮的动作：先关面板再展示设置窗，
    /// 避免 .statusBar 级面板浮在设置窗之上。
    private func openSettings() {
        closePanel()
        SettingsWindowController.shared.show(model: model)
    }

    /// 面板内统计按钮的动作：先关面板再展示统计窗，
    /// 避免 .statusBar 级面板浮在统计窗之上。
    private func openStatistics() {
        closePanel()
        StatisticsWindowController.shared.show(model: model)
    }

    // MARK: - 面板构建

    private func makePanel() -> PanelWindow {
        let hosting = NSHostingView(rootView: TimerMenuView(
            model: model,
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onOpenStatistics: { [weak self] in
                self?.openStatistics()
            }
        ))
        // 保留默认 intrinsicContentSize 行为：SwiftUI 的固定宽度
        // （.frame(width: 280)）和内容自身的垂直理想尺寸都经它输出，
        // 面板尺寸只由这个理想尺寸驱动，不读取面板当前尺寸，无反馈回路。
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // 毛玻璃层：.behindWindow 的 backdrop 由特殊合成层绘制，
        // 父视图 layer 的 cornerRadius/masksToBounds 裁不住它，
        // 必须通过 maskImage 的 alpha 通道显式给出圆角 mask。
        let effectView = NSVisualEffectView()
        // 使用系统 .menu 材质：与原生 NSMenu/状态栏菜单同一套自适应表面，
        // Light/Dark 由系统材质自行处理，不再叠加任何自定义着色层。
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = PanelMask.roundedRectImage(radius: PanelLayout.cornerRadius)
        effectView.translatesAutoresizingMaskIntoConstraints = false

        let panel = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: PanelLayout.panelWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 不显式指定 appearance：窗口继承 App/系统的 effective appearance，
        // 系统切换 Light/Dark 时窗口与所有子视图（含 SwiftUI）自动跟随。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // 根容器作为 contentView：唯一负责圆角裁剪，不绘制描边。
        // 作为 NSWindow.contentView，其 frame 由窗口管理，
        // 不要设置 translatesAutoresizingMaskIntoConstraints = false。
        let rootView = PanelRootView()
        rootView.addSubview(effectView)
        rootView.addSubview(hosting)
        panel.contentView = rootView

        // 两个子视图全部钉在根容器内部，z-order 按 addSubview 顺序：
        // effect（底）→ hosting（顶）。
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: rootView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            hosting.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: rootView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.intrinsicContentSize
        panel.setContentSize(NSSize(
            width: ceil(fitting.width),
            height: ceil(fitting.height)
        ))

        // 内容理想尺寸变化（通知提示出现/消失、语言切换、Focus Cycle
        // 状态变化）时，在下一个主线程布局周期按理想高度调整窗口，
        // 顶边保持锚定在状态栏按钮下方，再做屏幕边界夹取。
        sizeObservation = hosting.observe(
            \.intrinsicContentSize,
            options: [.new]
        ) { [weak self] _, change in
            // KVO 回调在非隔离上下文，只取 Sendable 的 CGSize，
            // 再跳主线程执行窗口调整。
            guard let size = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.panelContentIntrinsicSizeDidChange(size)
            }
        }

        self.panel = panel
        // 根裁剪与 backdrop mask 就绪后，让系统按圆角透明区域重算阴影，
        // 避免残留矩形表面的投影。
        panel.invalidateShadow()
        return panel
    }

    private func panelContentIntrinsicSizeDidChange(_ size: CGSize) {
        guard let panel else { return }
        let target = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard target.width > 0, target.height > 0, panel.frame.size != target else { return }
        let frame = panel.frame
        // 顶边不动、向下生长。
        panel.setFrame(
            NSRect(
                x: frame.minX,
                y: frame.maxY - target.height,
                width: target.width,
                height: target.height
            ),
            display: true
        )
        positionPanel(panel)
        // 尺寸改变后按新的圆角透明区域重算自然阴影。
        panel.invalidateShadow()
    }

    // MARK: - 定位

    /// 把面板锚定在状态栏按钮下方、水平居中，并夹取到屏幕可见区内。
    private func positionPanel(_ panel: NSPanel) {
        guard
            let button = statusItem.button,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen ?? NSScreen.main
        else { return }

        let buttonFrame = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let size = panel.frame.size
        let visible = screen.visibleFrame
        // 面板与状态栏按钮之间的锚定间距：0 让面板顶边紧贴菜单栏底边，
        // 消除整条 4pt 空带（圆角外的透明像素除外）。
        let anchorGap: CGFloat = 0
        // 面板与屏幕可见区边缘的安全边距，仅用于边界夹取。
        let screenMargin: CGFloat = 4

        var origin = CGPoint(
            x: buttonFrame.midX - size.width / 2,
            y: buttonFrame.minY - size.height - anchorGap
        )
        origin.x = max(
            visible.minX + screenMargin,
            min(origin.x, visible.maxX - size.width - screenMargin)
        )
        if origin.y < visible.minY + screenMargin {
            // 下方空间不足时翻到按钮上方：与按钮之间仍用 anchorGap，
            // 屏幕顶边的夹取继续使用 screenMargin。
            origin.y = min(
                buttonFrame.maxY + anchorGap,
                visible.maxY - size.height - screenMargin
            )
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - 事件监听

    private func installEventMonitors() {
        // 全局监听：点击本应用以外的区域时关闭面板。面板内部点击属于
        // 本应用事件，不会出现在全局监听里，因此不会误关。
        // 面板隐藏时直接返回，不创建 MainActor Task。
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.panel?.isVisible == true else { return }
            self.closePanel()
        }

        // 本地鼠标监听：点击落在本应用其他窗口（典型：设置窗）时关闭面板。
        // 只观察、不吞事件：事件始终原样返回，点击照常派发给目标窗口。
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleLocalClick(event)
            return event
        }

        // 本地键盘监听：仅在面板可见时拦截 Escape，其余事件原样放行，
        // 避免影响设置窗等其他窗口的 Escape 行为。
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self, self.panel?.isVisible == true, event.keyCode == 53 else {
                return event
            }
            self.closePanel()
            return nil
        }
    }

    /// 处理本应用内部点击：仅当面板可见，且点击落在面板与状态栏按钮
    /// 之外的本应用窗口（典型：设置窗）时关闭面板。
    private func handleLocalClick(_ event: NSEvent) {
        guard let panel, panel.isVisible else { return }
        guard let clickWindow = event.window else { return }
        // 面板内部点击：交给面板自身处理，保持打开。
        if clickWindow === panel { return }
        // 状态栏按钮所在窗口：按钮的 action 自己会 toggle 面板，
        // 这里若先关一次会造成“先关后开”的回归。
        if clickWindow === statusItem.button?.window { return }
        closePanel()
    }

    private func installScreenChangeObserver() {
        // 显示器增减、分辨率或菜单栏变化时，若面板开着则重新定位。
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.positionPanel(panel)
            }
        }
    }
}

/// 可成为 key 的无边框非激活面板：接收按钮与键盘事件，但不激活应用。
private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PanelLayout {
    static let cornerRadius: CGFloat = 12
    /// 面板固定宽度（含 SwiftUI 内边距的总宽），窗口初始尺寸与
    /// TimerMenuView 的 .frame(width:) 共用这一个来源。
    static let panelWidth: CGFloat = 280
    /// SwiftUI 内容两侧水平内边距；正文可用宽度 = 280 - 2×12 = 256。
    static let horizontalPadding: CGFloat = 12
    static var contentWidth: CGFloat { panelWidth - 2 * horizontalPadding }
}

/// 面板唯一的裁剪根容器：透明、layer-backed，只负责 continuous 圆角和
/// masksToBounds，不绘制任何描边。面板边缘完全由 .menu 系统材质与
/// 窗口自然阴影定义。毛玻璃材质与 SwiftUI 全部是它的子视图，普通图层
/// 在 masksToBounds 下被同一圆角裁掉，圆角外只有窗口阴影，不会有任何
/// 填充或方形边线溢出。
private final class PanelRootView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = PanelLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 生成给 `NSVisualEffectView.maskImage` 用的不透明圆角矩形 mask。
///
/// `.behindWindow` 毛玻璃的 backdrop 合成层不受父视图圆角裁剪，
/// 必须用 maskImage 的 alpha 通道显式裁掉圆角外的 backdrop。
/// capInsets + stretch 让 mask 随窗口 bounds 任意拉伸，
/// 尺寸变化时圆角半径始终保持 `radius`，无需随 layout 重设。
enum PanelMask {
    static func roundedRectImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        // mask 只看 alpha 通道：圆角内 alpha=1，圆角外保持透明。
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
            xRadius: radius,
            yRadius: radius
        ).fill()
        image.unlockFocus()
        image.capInsets = NSEdgeInsets(
            top: radius,
            left: radius,
            bottom: radius,
            right: radius
        )
        image.resizingMode = .stretch
        return image
    }
}
