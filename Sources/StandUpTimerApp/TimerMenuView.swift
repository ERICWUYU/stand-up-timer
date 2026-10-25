import AppKit
import SwiftUI

struct TimerMenuView: View {
    @ObservedObject var model: TimerModel

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
        .padding(.horizontal, 12)
        // 下面的负 padding 抵消 MenuBarExtra 的 16pt 内边距；
        // 这里用 16 与之相抵，净边距为 0，内容不会超出窗口被裁掉。
        .padding(.vertical, 16)
        .frame(width: 280)
        // 毛玻璃背景铺在内容之下；圆角和描边由窗口图层绘制，
        // 下面的负 padding 会把方形背景裁成窗口的圆角。
        .background {
            ZStack {
                PanelMaterialBackground()
                // 叠一层浅色，让背景比系统菜单更亮一些。
                Color.white.opacity(0.18)
            }
        }
        .background(PanelWindowStyler())
        // MenuBarExtra(.window) 会在内容上下各留一段内边距，
        // 用负值抵消，让面板紧贴菜单栏和内容，不留空白。
        .padding(.vertical, -16)
        .onAppear {
            model.refreshNotificationPermission()
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                settingsLabel
            }
            .buttonStyle(.plain)
        } else {
            Button {
                openSettings()
            } label: {
                settingsLabel
            }
            .buttonStyle(.plain)
        }
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

    /// macOS 13 没有 SettingsLink，用窗口选择器打开 Settings scene。
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // 两个选择器都没有响应时说明系统不提供设置窗口，
        // 记录日志，避免按钮看起来“点了没反应”。
        let opened = NSApp.sendAction(
            Selector(("showSettingsWindow:")), to: nil, from: nil
        ) || NSApp.sendAction(
            Selector(("showPreferencesWindow:")), to: nil, from: nil
        )
        if !opened {
            NSLog("无法打开设置窗口：系统未响应 showSettingsWindow:/showPreferencesWindow:")
        }
    }
}
