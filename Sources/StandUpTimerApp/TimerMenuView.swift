import AppKit
import SwiftUI

struct TimerMenuView: View {
    @ObservedObject var model: TimerModel
    /// 打开设置窗的动作，由控制器注入：先关闭面板，再展示设置窗。
    var onOpenSettings: () -> Void
    /// 打开统计窗的动作，由控制器注入：先关闭面板，再展示统计窗。
    var onOpenStatistics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.phaseSymbolName)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        model.phase == .focus ? Color.orange : Color.green
                    )
                Text(model.phaseTitle)
                    .font(.headline)
                    .fixedSize()
                if let progress = model.roundProgressText {
                    // 四轮进度单独一段，避免和阶段名一起被截断。
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityLabel(
                            Text(model.roundProgressAccessibilityLabel ?? progress)
                        )
                }
                Spacer()
                Text(model.statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Text(model.remainingText)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Text(model.phaseHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                // 提示文案随阶段和语言变长变短；固定预留两行，
                // 面板高度才不会在“未开始/运行中”之间跳动，
                // 也不会把底部按钮行挤出窗口。
                .lineLimit(2, reservesSpace: true)

            if let note = model.notificationNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(
                        model.notificationNoteIsWarning ? Color.orange : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = model.scheduleFailureNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button(model.primaryActionTitle) {
                    model.performPrimaryAction()
                }
                Spacer()
                Button(L10n.text("action.reset", language: model.language)) {
                    model.reset()
                }
                Button(L10n.text("action.skip", language: model.language)) {
                    model.skip()
                }
            }

            Divider()

            // 单行底栏：左侧模式动作（图标 + 可见文字），弹性留白，
            // 右侧三个等大纯图标工具按钮（统计 / 设置 / 退出）。
            HStack(spacing: FooterLayout.rootSpacing) {
                // 连续专注入口和“结束循环”都放在已有底栏里；
                // 状态语义与旧实现完全一致，两个条件相互独立、互不新增行。
                if model.canStartFourRounds {
                    modeActionButton(
                        systemName: "repeat.circle",
                        title: L10n.text("action.fourRounds", language: model.language),
                        help: L10n.text("action.fourRoundsHelp", language: model.language)
                    ) {
                        model.startFourRounds()
                    }
                }

                // 活动系列必须有直接退出的入口，不必一路 Skip。
                if model.isSeriesActive {
                    modeActionButton(
                        systemName: "xmark.circle",
                        title: L10n.text(
                            "action.cancelFourRounds",
                            language: model.language
                        ),
                        help: L10n.text(
                            "action.cancelFourRoundsHelp",
                            language: model.language
                        )
                    ) {
                        model.cancelFourRounds()
                    }
                }

                Spacer(minLength: 0)

                utilityButtonGroup
            }
        }
        // 面板背景、圆角和描边由 StatusItemPanelController 的 NSPanel
        // 根容器统一提供；SwiftUI 内容本身保持透明，不绘制任何背景。
        // 先内边距、再固定宽度：PanelLayout.panelWidth 是含 padding 的
        // 总宽，正文宽 256pt；垂直 12pt 留白保证上下对称，并让两行 hint
        // 有足够高度不被压缩。通知权限改由控制器在每次 showPanel() 时刷新。
        .padding(.horizontal, PanelLayout.horizontalPadding)
        .padding(.vertical, 12)
        .frame(width: PanelLayout.panelWidth)
    }

    // MARK: - 底栏部件

    /// 右侧工具组：统计 / 设置 / 退出三个等大纯图标按钮。
    private var utilityButtonGroup: some View {
        HStack(spacing: FooterLayout.utilitySpacing) {
            utilityButton(.statistics) { onOpenStatistics() }
            utilityButton(.settings) { onOpenSettings() }
            utilityButton(.quit) {
                // 保留既有异步清理行为，再终止应用。
                Task {
                    await model.quit()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    /// 等大命中区的纯图标按钮：无可见文字、无边框底色，
    /// 但每个按钮都带本地化 help 与 VoiceOver 标签，icon-only 不等于无标签。
    private func utilityButton(
        _ spec: FooterLayout.UtilityButton,
        action: @escaping () -> Void
    ) -> some View {
        let label = L10n.text(spec.titleKey, language: model.language)
        return Button(action: action) {
            Image(systemName: spec.systemName)
                .font(.system(
                    size: FooterLayout.footerFontPointSize,
                    weight: .medium
                ))
                .foregroundStyle(.secondary)
                .frame(
                    width: FooterLayout.utilityHitSize,
                    height: FooterLayout.utilityHitSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    /// 左侧模式动作：图标 + 可见本地化文字，保持原生 plain 外观与正常可读间距。
    private func modeActionButton(
        systemName: String,
        title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: FooterLayout.modeIconTextSpacing) {
                Image(systemName: systemName)
                    .font(.system(
                        size: FooterLayout.footerFontPointSize,
                        weight: .medium
                    ))
                Text(title)
                    .font(.system(
                        size: FooterLayout.footerFontPointSize,
                        weight: .medium
                    ))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, FooterLayout.modeButtonVerticalPadding)
            .padding(.horizontal, FooterLayout.modeButtonHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityHint(Text(help))
    }
}

/// Stage 6B 底栏布局（批准的单行重设计）：
/// `[repeat.circle Focus Cycle]  弹性留白  [统计] [设置] [退出]`
///
/// 左侧是图标 + 可见文字的模式动作（Focus Cycle / End Cycle，状态语义不变）；
/// 右侧是三个等命中区、等视觉权重的纯图标工具按钮。280pt 面板（正文 256pt）
/// 单行容纳，不缩字体、不裁文字、不加第二行或额外分隔线。
///
/// 这是视图与布局回归测试共用的唯一常量/测量来源。SwiftUI 在单元测试环境
/// 没有稳定的像素级布局断言，自动化只保证理想宽度与命中区约束；人工截图
/// （含 Light/Dark、中英、Focus Cycle/End Cycle）仍是最终渲染门禁。
enum FooterLayout {
    // MARK: 共享字体

    static let footerFontPointSize: CGFloat = 13
    static let footerFontWeight: NSFont.Weight = .medium

    /// 测量用字体，必须与底栏两个按钮构造器的实际字体一致。
    static var footerFont: NSFont {
        .systemFont(ofSize: footerFontPointSize, weight: footerFontWeight)
    }

    // MARK: 左侧模式按钮

    /// 图标与文字间距：正常可读间距（4–6pt 区间取 6）。
    static let modeIconTextSpacing: CGFloat = 6
    /// 模式按钮两侧内边距，保持原生手感，不使用 1pt 微型内边距。
    static let modeButtonHorizontalPadding: CGFloat = 4
    static let modeButtonVerticalPadding: CGFloat = 4

    // MARK: 右侧工具组

    /// 三个纯图标按钮共享的正方形命中区。
    static let utilityHitSize: CGFloat = 28
    /// 工具按钮之间的克制间距（4–6pt 区间取 4）。
    static let utilitySpacing: CGFloat = 4
    static let utilityButtonCount = 3

    // MARK: 整行

    /// 底栏根 HStack 间距；Spacer 理想宽度为 0，弹性吸收剩余空间。
    static let rootSpacing: CGFloat = 8

    /// 右侧工具组的理想总宽：三个等大命中区 + 按钮间间距。
    static var utilityGroupWidth: CGFloat {
        CGFloat(utilityButtonCount) * utilityHitSize
            + CGFloat(utilityButtonCount - 1) * utilitySpacing
    }

    /// SF Symbol 在当前系统上的真实布局宽度：按与生产相同的 pointSize/weight
    /// 符号配置实测，不使用固定估计；符号查不到时退回字号宽度。
    static func iconWidth(systemName: String) -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: footerFontPointSize,
            weight: footerFontWeight
        )
        guard
            let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else {
            return footerFontPointSize
        }
        return image.size.width
    }

    /// 左侧模式按钮的理想宽度：文字 + 实测图标 + 图文间距 + 两侧内边距。
    static func modeButtonWidth(systemName: String, title: String) -> CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [.font: footerFont]).width
        return ceil(textWidth)
            + iconWidth(systemName: systemName)
            + modeIconTextSpacing
            + 2 * modeButtonHorizontalPadding
    }

    /// 含左侧模式按钮时的整行理想宽度：
    /// 模式按钮 + 两个 rootSpacing（Spacer 两侧）+ 工具组。
    static func footerWidth(modeSystemName: String, modeTitle: String) -> CGFloat {
        modeButtonWidth(systemName: modeSystemName, title: modeTitle)
            + 2 * rootSpacing
            + utilityGroupWidth
    }

    /// 右侧纯图标工具按钮的稳定纯描述：视图按它构造，测试按它校验
    /// 符号、本地化键与顺序，不依赖 SwiftUI 视图内省。
    struct UtilityButton: Hashable {
        let systemName: String
        let titleKey: String

        static let statistics = UtilityButton(
            systemName: "chart.bar.xaxis",
            titleKey: "action.statistics"
        )
        static let settings = UtilityButton(
            systemName: "gearshape",
            titleKey: "action.settings"
        )
        static let quit = UtilityButton(
            systemName: "power",
            titleKey: "action.quit"
        )

        /// 视图中的真实顺序：统计 → 设置 → 退出。
        static let all = [statistics, settings, quit]
    }
}
