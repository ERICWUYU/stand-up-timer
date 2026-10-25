import Foundation

/// 启动决策的结果。
public struct TimerStartupResult: Sendable {
    public let timer: StandUpTimer
    /// 本次进程是否由 `--test-durations` 覆盖了时长。
    public let usesOverride: Bool
    /// 覆盖模式下不写持久化状态，避免测试时长污染用户数据。
    public let persistsState: Bool
}

/// 决定应用启动时使用哪个计时器，以及是否需要持久化状态。
///
/// 纯函数：时间由调用方注入，不读取系统时钟、`UserDefaults` 或通知框架。
public enum TimerStartup {
    public static func timer(
        settings: TimerSettings,
        restored: StandUpTimerSnapshot?,
        overrideDuration: TimeInterval?,
        now: Date
    ) -> TimerStartupResult {
        // 人工测试时长只覆盖本次进程：专注、短休和长休同时缩短。
        if let overrideDuration,
           overrideDuration.isFinite,
           overrideDuration > 0 {
            return TimerStartupResult(
                timer: StandUpTimer(
                    focusDuration: overrideDuration,
                    restDuration: overrideDuration,
                    longRestDuration: overrideDuration
                ),
                usesOverride: true,
                persistsState: false
            )
        }

        if let restored, var timer = StandUpTimer(snapshot: restored) {
            // 设置里的时长优先于旧快照；运行中或暂停中不会因此跳时。
            timer.updateDurations(
                focusDuration: settings.focusDuration,
                restDuration: settings.restDuration
            )
            // 用注入的当前时间连续结算关闭期间跨过的阶段，
            // 不会重新得到一整段完整时长。
            timer.refresh(at: now)
            return TimerStartupResult(
                timer: timer,
                usesOverride: false,
                persistsState: true
            )
        }

        return TimerStartupResult(
            timer: StandUpTimer(
                focusDuration: settings.focusDuration,
                restDuration: settings.restDuration
            ),
            usesOverride: false,
            persistsState: true
        )
    }
}
