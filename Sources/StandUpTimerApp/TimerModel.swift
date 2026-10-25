import Combine
import Foundation
import StandUpTimerCore

/// 界面适配层：向核心传入时间点，并把状态转换成可显示的文字。
/// 计时规则全部由 `StandUpTimer` 决定，这里不复制任何计时逻辑。
@MainActor
final class TimerModel: ObservableObject {
    private static let languageKey = "standUpTimer.language"

    @Published private(set) var now: Date
    @Published private(set) var language: AppLanguage
    @Published private(set) var settings: TimerSettings
    @Published private(set) var reminderSound: ReminderSoundPreference
    @Published private(set) var notificationPermission: NotificationManager.Permission = .unknown
    /// 提醒排程失败时置位，界面据此显示可理解的提示，而不是静默失败。
    @Published private(set) var notificationScheduleFailed = false

    private var timer: StandUpTimer
    private var ticker: AnyCancellable?
    private let notifications = NotificationManager()
    private let soundPlayer = SoundPreviewPlayer()
    private let store: TimerSettingsStore
    private let storage: TimerStorage
    /// `--test-durations` 模式不恢复、也不写回任何持久化数据。
    private let persistsState: Bool
    private var notificationSyncTask: Task<Void, Never>?
    /// 退出流程开始后不再接受新的排程，避免清空提醒之后又被排上新的。
    private var isQuitting = false

    init(now: Date = Date(), storage: TimerStorage = UserDefaultsTimerStorage()) {
        self.now = now
        self.storage = storage

        let store = TimerSettingsStore(storage: storage)
        self.store = store

        self.language = storage.readString(Self.languageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault

        let settings = store.settings
        let startup = TimerStartup.timer(
            settings: settings,
            restored: store.snapshot,
            overrideDuration: LaunchOptions.overrideDuration,
            now: now
        )
        self.settings = settings
        self.reminderSound = store.reminderSound
        self.timer = startup.timer
        self.persistsState = startup.persistsState

        // 启动时立即清理上一次运行遗留的提醒。
        notifications.cancelPending()

        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                Task { @MainActor [weak self] in
                    self?.update(at: date)
                }
            }

        // 恢复为运行状态时，重新查询权限并按真实截止时间安排提醒。
        // 已经过期的阶段在上面结算掉了，不会补发成一串通知。
        if timer.status == .running, persistsState {
            notificationsDidChange(requestAuthorization: false)
        }
    }

    var phase: StandUpTimer.Phase {
        timer.phase
    }

    var status: StandUpTimer.Status {
        timer.status
    }

    var mode: StandUpTimer.Mode {
        timer.mode
    }

    var focusRound: Int {
        timer.focusRound
    }

    var restKind: StandUpTimer.RestKind {
        timer.restKind
    }

    /// 是否处于活动中的四轮系列。
    var isSeriesActive: Bool {
        timer.isSeriesActive
    }

    /// 只有普通模式的空闲专注才提供“四轮”入口。
    var canStartFourRounds: Bool {
        !isSeriesActive && phase == .focus && status == .idle
    }

    /// 四轮运行中的进度文案；普通模式为 nil。
    var roundProgressText: String? {
        guard isSeriesActive else { return nil }
        return String(
            format: t("round.progress"),
            focusRound,
            StandUpTimer.focusRoundCount
        )
    }

    /// 进度文案的完整读法，供 VoiceOver 使用。
    var roundProgressAccessibilityLabel: String? {
        guard isSeriesActive else { return nil }
        return String(
            format: t("round.progressAccessibility"),
            focusRound,
            StandUpTimer.focusRoundCount
        )
    }

    var remaining: TimeInterval {
        timer.remaining(at: now)
    }

    var menuBarSymbolName: String {
        if status == .paused {
            return "pause.circle.fill"
        }
        return phaseSymbolName
    }

    /// 专注计时中菜单栏只显示图标；休息或暂停时显示剩余时间。
    var showsTimeInMenuBar: Bool {
        phase == .rest || status == .paused
    }

    var menuBarAccessibilityLabel: String {
        String(
            format: t("menu.accessibility"),
            phaseTitle,
            statusTitle,
            remainingText
        )
    }

    var remainingText: String {
        Self.format(remaining)
    }

    var phaseTitle: String {
        if timer.isLongRest {
            return t("phase.longBreak")
        }
        return phase == .focus ? t("phase.focus") : t("phase.break")
    }

    /// 长休用独立图标和文字，不只靠颜色区分。
    var phaseSymbolName: String {
        if timer.isLongRest {
            return "bed.double"
        }
        return phase == .focus ? "target" : "figure.walk"
    }

    var statusTitle: String {
        switch status {
        case .idle:
            return t("status.idle")
        case .running:
            return t("status.running")
        case .paused:
            return t("status.paused")
        }
    }

    var phaseHint: String {
        if timer.isLongRest {
            switch status {
            case .idle:
                return t("hint.longBreak.idle")
            case .running:
                return t("hint.longBreak.running")
            case .paused:
                return t("hint.longBreak.paused")
            }
        }
        switch (phase, status) {
        case (.focus, .idle):
            return t("hint.focus.idle")
        case (.focus, .running):
            return t("hint.focus.running")
        case (.focus, .paused):
            return t("hint.focus.paused")
        case (.rest, .idle):
            return t("hint.break.idle")
        case (.rest, .running):
            return t("hint.break.running")
        case (.rest, .paused):
            return t("hint.break.paused")
        }
    }

    var primaryActionTitle: String {
        switch status {
        case .idle:
            return t("action.start")
        case .running:
            return t("action.pause")
        case .paused:
            return t("action.resume")
        }
    }

    var notificationNote: String? {
        switch notificationPermission {
        case .authorized:
            return nil
        case .unknown:
            return t("notification.note.unknown")
        case .denied:
            return t("notification.note.denied")
        case .unavailable:
            return t("notification.note.unavailable")
        }
    }

    var notificationNoteIsWarning: Bool {
        notificationPermission == .denied || notificationPermission == .unavailable
    }

    var scheduleFailureNote: String? {
        notificationScheduleFailed ? t("notification.note.scheduleFailed") : nil
    }

    // MARK: - 设置

    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        storage.writeString(language.rawValue, forKey: Self.languageKey)
        // 计时进行中时按原截止时间重排提醒，让通知文案也换成新语言。
        notificationsDidChange(requestAuthorization: false)
    }

    func setSound(_ sound: NotificationSound) {
        guard sound != reminderSound.sound else { return }
        reminderSound.sound = sound
        store.save(reminderSound)
        // 计时进行中时按原截止时间重排两条提醒，让它们立即使用新声音。
        notificationsDidChange(requestAuthorization: false)
    }

    /// 关闭后通知照常送达，但内容不带声音；重新开启沿用先前选择的音效。
    func setSoundEnabled(_ isEnabled: Bool) {
        guard isEnabled != reminderSound.isEnabled else { return }
        reminderSound.isEnabled = isEnabled
        store.save(reminderSound)
        notificationsDidChange(requestAuthorization: false)
    }

    func setFocusMinutes(_ minutes: Int) {
        updateSettings(
            TimerSettings(focusMinutes: minutes, restMinutes: settings.restMinutes)
        )
    }

    func setRestMinutes(_ minutes: Int) {
        updateSettings(
            TimerSettings(focusMinutes: settings.focusMinutes, restMinutes: minutes)
        )
    }

    private func updateSettings(_ newSettings: TimerSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        // 空闲时立即采用新时长；运行中或暂停中保持当前截止点。
        timer.updateDurations(
            focusDuration: newSettings.focusDuration,
            restDuration: newSettings.restDuration
        )
        if persistsState {
            store.save(newSettings)
        }

        let date = Date()
        now = date
        saveState(at: date)
        // 按当前截止点重排受影响的后续提醒，不会把当前截止点向后拖。
        notificationsDidChange(requestAuthorization: false)
    }

    /// 试听当前声音；关闭声音时不播放。
    @discardableResult
    func previewSound() -> Bool {
        guard let sound = reminderSound.notificationSound else { return true }
        return soundPlayer.play(sound)
    }

    // MARK: - 计时操作

    func performPrimaryAction() {
        let date = Date()
        switch timer.status {
        case .idle:
            timer.start(at: date)
        case .running:
            timer.pause(at: date)
        case .paused:
            timer.resume(at: date)
        }
        now = date
        saveState(at: date)
        notificationsDidChange(requestAuthorization: timer.status == .running)
    }

    func reset() {
        timer.reset()
        let date = Date()
        now = date
        saveState(at: date)
        notificationsDidChange(requestAuthorization: false)
    }

    func skip() {
        let date = Date()
        timer.skip(at: date)
        now = date
        saveState(at: date)
        notificationsDidChange(requestAuthorization: timer.status == .running)
    }

    /// 从普通空闲专注一键开始四轮系列。
    func startFourRounds() {
        let date = Date()
        timer.startFourRounds(at: date)
        now = date
        saveState(at: date)
        notificationsDidChange(requestAuthorization: true)
    }

    /// 取消四轮系列：清除系列提醒并回到普通空闲专注。
    func cancelFourRounds() {
        guard timer.isSeriesActive else { return }
        timer.cancelFourRounds()
        let date = Date()
        now = date
        saveState(at: date)
        notificationsDidChange(requestAuthorization: false)
    }

    /// 由界面定时器调用：先结算到期阶段，再刷新显示时间。
    func update(at date: Date) {
        if timer.refresh(at: date) {
            // 阶段自然结束只保存状态，不重排提醒：
            // 重排会把已经过期的截止点当成一条新提醒再发一次。
            saveState(at: date)
        }
        now = date
    }

    func refreshNotificationPermission() {
        Task {
            notificationPermission = await notifications.currentPermission()
        }
    }

    /// 退出前先保存最终状态，再等待提醒真正清除。
    func quit() async {
        // 先封锁后续排程，再等排程链跑完，最后清空提醒。
        isQuitting = true
        saveState(at: Date())
        await notificationSyncTask?.value
        await notifications.cancelPendingAndWait()
    }

    // MARK: - 内部

    /// 只在有意义的状态变化后写入，不按秒落盘。
    private func saveState(at date: Date) {
        guard persistsState else { return }
        store.save(snapshot: timer.snapshot(at: date))
    }

    private func notificationsDidChange(requestAuthorization: Bool) {
        guard !isQuitting else { return }
        // 串行化权限请求和通知写入，避免暂停/跳过后被迟到的旧写入覆盖。
        let previous = notificationSyncTask
        notificationSyncTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.syncNotifications(requestAuthorization: requestAuthorization)
        }
    }

    private func syncNotifications(requestAuthorization: Bool) async {
        let permission = requestAuthorization
            ? await notifications.requestAuthorizationIfNeeded()
            : await notifications.currentPermission()
        notificationPermission = permission
        notificationScheduleFailed = false

        guard permission == .authorized, timer.status == .running else {
            await notifications.cancelPendingAndWait()
            return
        }

        // 时间线由核心按绝对时间点一次算好：等待通知中心期间的延迟
        // 不会把后续提醒整体推后，四轮系列也只写入一次。
        let date = Date()
        let events = ReminderTimeline.events(for: timer, now: date)
        let scheduled = await notifications.replacePending(
            events: events,
            sound: reminderSound,
            language: language
        )

        notificationScheduleFailed = !scheduled
    }

    private func t(_ key: String) -> String {
        L10n.text(key, language: language)
    }

    private static func format(_ remaining: TimeInterval) -> String {
        let totalSeconds = max(0, Int(remaining.rounded(.up)))
        return String(
            format: "%02d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }
}
