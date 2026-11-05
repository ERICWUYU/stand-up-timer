import AppKit
import SwiftUI

struct TimerMenuView: View {
    @ObservedObject var model: TimerModel
    /// 打开设置窗的动作，由控制器注入：先关闭面板，再展示设置窗。
    var onOpenSettings: () -> Void

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

            HStack(spacing: 8) {
                // 连续专注入口和“结束循环”都放在已有底栏里。
                // 底栏标签使用紧凑字号且禁止换行，避免英文设置按钮被挤成两行。
                if model.canStartFourRounds {
                    Button {
                        model.startFourRounds()
                    } label: {
                        bottomLabel(
                            icon: "repeat.circle",
                            title: L10n.text("action.fourRounds", language: model.language)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("action.fourRoundsHelp", language: model.language))
                    .accessibilityHint(Text(L10n.text(
                        "action.fourRoundsHelp",
                        language: model.language
                    )))
                }

                // 活动系列必须有直接退出的入口，不必一路 Skip。
                if model.isSeriesActive {
                    Button {
                        model.cancelFourRounds()
                    } label: {
                        bottomLabel(
                            icon: "xmark.circle",
                            title: L10n.text(
                                "action.cancelFourRounds",
                                language: model.language
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text(
                        "action.cancelFourRoundsHelp",
                        language: model.language
                    ))
                    .accessibilityHint(Text(L10n.text(
                        "action.cancelFourRoundsHelp",
                        language: model.language
                    )))
                }

                Spacer(minLength: 0)

                settingsButton

                Button {
                    Task {
                        await model.quit()
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    bottomLabel(
                        icon: "power",
                        title: L10n.text("action.quit", language: model.language)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        // 面板背景、圆角和描边由 StatusItemPanelController 的 NSPanel
        // 根容器统一提供；SwiftUI 内容本身保持透明，不绘制任何背景。
        // 先内边距、再固定宽度：PanelLayout.panelWidth 是含 padding 的
        // 总宽，正文宽 256pt；垂直 12pt 留白保证上下对称，并让两行 hint
        // 有足够高度不被压缩。通知权限改由控制器在每次 showPanel() 时刷新。
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: PanelLayout.panelWidth)
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            settingsLabel
        }
        .buttonStyle(.plain)
    }

    private var settingsLabel: some View {
        bottomLabel(
            icon: "gearshape",
            title: L10n.text("action.settings", language: model.language)
        )
    }

    private func bottomLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
