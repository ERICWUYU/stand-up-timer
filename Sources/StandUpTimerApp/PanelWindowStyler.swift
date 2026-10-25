import AppKit
import SwiftUI

/// 与系统菜单一致的毛玻璃背景。
///
/// 必须作为 SwiftUI 的背景使用：如果把 NSVisualEffectView 直接插进窗口的
/// contentView，它会盖在 SwiftUI 内容之上，导致面板看起来是空的。
struct PanelMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// `MenuBarExtra(.window)` 的窗口本身没有背景和描边。
/// 这里给窗口设置圆角、细描边和阴影，让面板呈现原生下拉菜单的外观。
struct PanelWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        StylingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? StylingView)?.applyStyle()
    }

    private final class StylingView: NSView {
        private static let cornerRadius: CGFloat = 12

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
        }

        /// 窗口在 Retina 与非 Retina 显示器之间移动时 backing scale 会变，
        /// 描边宽度需要按新的 scale 重算才能保持一个物理像素。
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            applyStyle()
        }

        func applyStyle() {
            guard let window, let contentView = window.contentView else { return }

            // 毛玻璃需要窗口本身透明，背景由材质视图绘制。
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true

            contentView.wantsLayer = true
            guard let layer = contentView.layer else { return }
            layer.cornerRadius = Self.cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.backgroundColor = NSColor.clear.cgColor
            // 系统菜单的描边只有 1 个物理像素。
            layer.borderWidth = 1 / window.backingScaleFactor
            layer.borderColor = NSColor.separatorColor
                .withAlphaComponent(0.5)
                .usingColorSpace(.sRGB)?.cgColor
        }
    }
}
