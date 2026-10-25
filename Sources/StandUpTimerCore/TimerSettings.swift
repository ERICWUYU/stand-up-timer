import Foundation

/// 用户可调的专注与休息时长（分钟）。
///
/// 任何缺失、超出范围或损坏的值都会回退到默认值，
/// 避免把坏数据带进核心的时长前置条件。
public struct TimerSettings: Equatable, Sendable {
    public static let focusRange = 1...180
    public static let restRange = 1...60
    public static let defaultFocusMinutes = 25
    public static let defaultRestMinutes = 5

    public let focusMinutes: Int
    public let restMinutes: Int

    public init(focusMinutes: Int?, restMinutes: Int?) {
        self.focusMinutes = Self.validated(
            focusMinutes,
            in: Self.focusRange,
            fallback: Self.defaultFocusMinutes
        )
        self.restMinutes = Self.validated(
            restMinutes,
            in: Self.restRange,
            fallback: Self.defaultRestMinutes
        )
    }

    public static let standard = TimerSettings(
        focusMinutes: defaultFocusMinutes,
        restMinutes: defaultRestMinutes
    )

    public var focusDuration: TimeInterval {
        TimeInterval(focusMinutes) * 60
    }

    public var restDuration: TimeInterval {
        TimeInterval(restMinutes) * 60
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
