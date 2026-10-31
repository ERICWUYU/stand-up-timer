import AppKit
import StandUpTimerCore
import SwiftUI

/// 设置窗口：语言、普通计时器时长、Focus Cycle 时长、提醒声音。
struct SettingsView: View {
    @ObservedObject var model: TimerModel
    @State private var isChinese = false
    @State private var previewFailed = false

    static func windowTitle(for language: AppLanguage) -> String {
        language == .chinese ? "“番茄钟”设置" : "Pomodoro Timer Settings"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            languageCard
            durationSection(titleKey: "settings.section.normal") {
                durationRow(
                    icon: "target",
                    sectionKey: "settings.section.normal",
                    titleKey: "settings.normal.focusDuration",
                    minutes: normalFocusMinutes,
                    range: TimerSettings.focusRange
                )

                Divider().opacity(0.5)

                durationRow(
                    icon: "figure.walk",
                    sectionKey: "settings.section.normal",
                    titleKey: "settings.normal.restDuration",
                    minutes: normalRestMinutes,
                    range: TimerSettings.restRange
                )
            }
            durationSection(titleKey: "settings.section.cycle") {
                durationRow(
                    icon: "target",
                    sectionKey: "settings.section.cycle",
                    titleKey: "settings.cycle.focusDuration",
                    minutes: cycleFocusMinutes,
                    range: TimerSettings.focusRange
                )

                Divider().opacity(0.5)

                durationRow(
                    icon: "figure.walk",
                    sectionKey: "settings.section.cycle",
                    titleKey: "settings.cycle.shortRestDuration",
                    minutes: cycleShortRestMinutes,
                    range: TimerSettings.restRange
                )

                Divider().opacity(0.5)

                durationRow(
                    icon: "bed.double",
                    sectionKey: "settings.section.cycle",
                    titleKey: "settings.cycle.longRestDuration",
                    minutes: cycleLongRestMinutes,
                    range: TimerSettings.restRange
                )
            }
            soundRow
            if previewFailed {
                Text(L10n.text("sound.previewFailed", language: model.language))
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(SettingsWindowTitle(title: windowTitle))
        .onAppear {
            isChinese = model.language == .chinese
        }
        // 开关直接驱动模型，避免在设置窗口里 Binding 未提交导致语言不变。
        .onChange(of: isChinese) { newValue in
            model.setLanguage(newValue ? .chinese : .english)
        }
        .onChange(of: model.language) { newValue in
            isChinese = newValue == .chinese
        }
    }

    /// 系统标题按系统语言显示，这里改成跟随应用内语言。
    private var windowTitle: String {
        Self.windowTitle(for: model.language)
    }

    private var languageCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.green)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(L10n.text("settings.language", language: model.language))
                .font(.subheadline)
                .fixedSize()
                .accessibilityHidden(true)

            Spacer()

            Text(model.language == .english ? "English" : "中文")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Toggle(
                L10n.text("settings.language", language: model.language),
                isOn: $isChinese
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(
                Text(L10n.text("settings.language", language: model.language))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.green.opacity(0.15), lineWidth: 1)
        )
    }

    /// 两个时长分区共用的紧凑样式：浅色分组，不使用大面积彩色卡片。
    private func durationSection<Content: View>(
        titleKey: String,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(titleKey, language: model.language))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                rows()
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func durationRow(
        icon: String,
        sectionKey: String,
        titleKey: String,
        minutes: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(L10n.text(titleKey, language: model.language))
                .font(.subheadline)
                .fixedSize()
                .accessibilityHidden(true)

            Spacer()

            Stepper(value: minutes, in: range) {
                Text(
                    "\(minutes.wrappedValue) \(L10n.text("unit.minutes", language: model.language))"
                )
                .font(.subheadline)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
            }
            .fixedSize()
            .accessibilityLabel(Text(accessibilityLabel(
                sectionKey: sectionKey,
                titleKey: titleKey
            )))
            .accessibilityValue(Text(String(
                format: L10n.text(
                    "unit.minutesAccessibility",
                    language: model.language
                ),
                minutes.wrappedValue
            )))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func accessibilityLabel(sectionKey: String, titleKey: String) -> String {
        String(
            format: L10n.text(
                "settings.durationAccessibility",
                language: model.language
            ),
            L10n.text(sectionKey, language: model.language),
            L10n.text(titleKey, language: model.language)
        )
    }

    private var soundRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(L10n.text("settings.sound", language: model.language))
                .font(.subheadline)
                .fixedSize()

            Spacer()

            Button {
                previewFailed = !model.previewSound()
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.reminderSound.isEnabled)
            .help(L10n.text("action.previewSound", language: model.language))
            .accessibilityLabel(
                Text(L10n.text("action.previewSound", language: model.language))
            )

            Picker(
                L10n.text("settings.sound", language: model.language),
                selection: soundBinding
            ) {
                ForEach(NotificationSound.allCases) { sound in
                    Text(L10n.text(sound.displayNameKey, language: model.language))
                        .tag(sound)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!model.reminderSound.isEnabled)

            // 关闭后通知照常出现，只是没有声音。
            Toggle(
                L10n.text("settings.soundEnabled", language: model.language),
                isOn: soundEnabledBinding
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .help(L10n.text("settings.soundEnabled", language: model.language))
            .accessibilityLabel(
                Text(L10n.text("settings.soundEnabled", language: model.language))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 绑定

    /// 声音选择直接读写模型，不再维护一份镜像状态。
    /// 变化后立即保存并试听，让切换声音马上能听出差别。
    private var soundBinding: Binding<NotificationSound> {
        Binding(
            get: { model.reminderSound.sound },
            set: { newValue in
                guard newValue != model.reminderSound.sound else { return }
                model.setSound(newValue)
                previewFailed = !model.previewSound()
            }
        )
    }

    private var soundEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.reminderSound.isEnabled },
            set: { newValue in
                model.setSoundEnabled(newValue)
                previewFailed = false
            }
        )
    }

    private var normalFocusMinutes: Binding<Int> {
        Binding(
            get: { model.settings.focusMinutes },
            set: { model.setNormalFocusMinutes($0) }
        )
    }

    private var normalRestMinutes: Binding<Int> {
        Binding(
            get: { model.settings.restMinutes },
            set: { model.setNormalRestMinutes($0) }
        )
    }

    private var cycleFocusMinutes: Binding<Int> {
        Binding(
            get: { model.settings.cycleFocusMinutes },
            set: { model.setCycleFocusMinutes($0) }
        )
    }

    private var cycleShortRestMinutes: Binding<Int> {
        Binding(
            get: { model.settings.cycleShortRestMinutes },
            set: { model.setCycleShortRestMinutes($0) }
        )
    }

    private var cycleLongRestMinutes: Binding<Int> {
        Binding(
            get: { model.settings.cycleLongRestMinutes },
            set: { model.setCycleLongRestMinutes($0) }
        )
    }
}

/// 只负责同步窗口标题，不再承担激活或前置逻辑。
/// 窗口身份由 `SettingsWindowController` 的稳定 identifier 决定，与标题无关。
private struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = TitleView()
        view.applyTitle(title)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitleView)?.applyTitle(title)
    }

    private final class TitleView: NSView {
        private var title = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyTitle(title)
        }

        func applyTitle(_ title: String) {
            self.title = title
            window?.title = title
        }
    }
}
