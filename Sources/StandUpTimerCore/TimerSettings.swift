import Foundation

/// 用户可调的时长设置（分钟）。
///
/// 普通计时器与 Focus Cycle 各有独立时长；四轮系列的专注和短休
/// 在首次迁移时会沿用旧的普通时长，长休则从 15 分钟开始。
/// 任何缺失、超出范围或损坏的值都会回退到默认值，
/// 避免把坏数据带进核心的时长前置条件。
public struct TimerSettings: Equatable, Sendable {
    public static let focusRange = 1...180
    public static let restRange = 1...60

    public static let defaultFocusMinutes = 25
    public static let defaultRestMinutes = 5
    public static let defaultCycleFocusMinutes = 25
    public static let defaultCycleShortRestMinutes = 5
    public static let defaultCycleLongRestMinutes = 15

    /// 普通计时器的专注时长。
    public let focusMinutes: Int
    /// 普通计时器的休息时长。
    public let restMinutes: Int
    /// Focus Cycle 每次专注的时长。
    public let cycleFocusMinutes: Int
    /// Focus Cycle 的短休时长。
    public let cycleShortRestMinutes: Int
    /// Focus Cycle 第 4 次专注后的长休时长。
    public let cycleLongRestMinutes: Int

    public init(
        focusMinutes: Int?,
        restMinutes: Int?,
        cycleFocusMinutes: Int? = nil,
        cycleShortRestMinutes: Int? = nil,
        cycleLongRestMinutes: Int? = nil
    ) {
        let normalFocus = Self.validated(
            focusMinutes,
            in: Self.focusRange,
            fallback: Self.defaultFocusMinutes
        )
        let normalRest = Self.validated(
            restMinutes,
            in: Self.restRange,
            fallback: Self.defaultRestMinutes
        )

        self.focusMinutes = normalFocus
        self.restMinutes = normalRest
        // 未提供 Focus Cycle 值时沿用普通模式，保持旧设置升级后的节奏不变。
        self.cycleFocusMinutes = Self.validated(
            cycleFocusMinutes ?? normalFocus,
            in: Self.focusRange,
            fallback: Self.defaultCycleFocusMinutes
        )
        self.cycleShortRestMinutes = Self.validated(
            cycleShortRestMinutes ?? normalRest,
            in: Self.restRange,
            fallback: Self.defaultCycleShortRestMinutes
        )
        self.cycleLongRestMinutes = Self.validated(
            cycleLongRestMinutes,
            in: Self.restRange,
            fallback: Self.defaultCycleLongRestMinutes
        )
    }

    public static let standard = TimerSettings(
        focusMinutes: defaultFocusMinutes,
        restMinutes: defaultRestMinutes
    )

    // MARK: - 普通计时器

    public var focusDuration: TimeInterval {
        TimeInterval(focusMinutes) * 60
    }

    public var restDuration: TimeInterval {
        TimeInterval(restMinutes) * 60
    }

    // MARK: - Focus Cycle

    public var cycleFocusDuration: TimeInterval {
        TimeInterval(cycleFocusMinutes) * 60
    }

    public var cycleShortRestDuration: TimeInterval {
        TimeInterval(cycleShortRestMinutes) * 60
    }

    public var cycleLongRestDuration: TimeInterval {
        TimeInterval(cycleLongRestMinutes) * 60
    }

    private static func validated(
        _ value: Int?,
        in range: ClosedRange<Int>,
        fallback: Int
    ) -> Int {
        guard let value, range.contains(value) else { return fallback }
        return value
    }
}
