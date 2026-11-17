import Foundation

/// 统计窗口：全部按日历日计算，边界由注入的 Calendar/TimeZone 决定，
/// 不使用环境当前时间或系统默认时区，保证测试确定、DST 行为可复现。
public enum StatisticsWindow: String, Sendable {
    /// 参考日期所在的自然日（00:00 到次日 00:00，半开区间）。
    case today
    /// 含参考日在内的最近 7 个自然日。
    case last7Days
    /// 含参考日在内的最近 30 个自然日。
    case last30Days
    /// 参考日所在公历年的年初（1 月 1 日 00:00）到参考日结束。
    /// 这是固定日历年窗口（year-to-date），不是滚动 365 天；
    /// 覆盖天数随参考日期变化，由 Calendar 按参考日推导，闰年自动正确。
    case thisYear

    /// 固定长度窗口覆盖的自然日数；`.thisYear` 没有固定天数，返回 nil。
    var fixedDayCount: Int? {
        switch self {
        case .today: return 1
        case .last7Days: return 7
        case .last30Days: return 30
        case .thisYear: return nil
        }
    }
}

/// 一个自然日的聚合桶，按时间升序排列且窗口内每天一个（含零值天），
/// 可直接喂给 Swift Charts 柱状图。
public struct ActivityDayBucket: Identifiable, Equatable, Sendable {
    /// 该日 00:00（注入时区下的 startOfDay）。
    public let day: Date
    public let completedFocusDuration: TimeInterval
    public let completedFocusCount: Int
    public let completedRestDuration: TimeInterval
    public let completedRestCount: Int

    public var id: Date { day }
}

/// 单个窗口的聚合结果。只描述“完成的专注/休息”这一健康视角，
/// 不包含 streak、评分或任何屏幕时间语义。
public struct ActivityStatistics: Equatable, Sendable {
    public let window: StatisticsWindow
    /// 半开时间区间 [start, end)，记录按 date 落入。
    public let range: DateInterval
    public let completedFocusDuration: TimeInterval
    public let completedFocusCount: Int
    public let completedRestDuration: TimeInterval
    public let completedRestCount: Int
    public let skippedFocusCount: Int
    public let skippedRestCount: Int
    /// 最长的一次自然完成专注时长；无完成记录时为 0。
    public let longestCompletedFocusDuration: TimeInterval
    /// 休息遵守率 = 完成的休息 /（完成 + 跳过的休息）。
    /// 分母为 0（没有任何休息结果）时为 nil，调用方必须展示明确的无数据状态，
    /// 禁止除零或伪造 0%/100%。
    public let breakAdherence: Double?
    /// 窗口内每天一个桶，按日升序。
    public let dayBuckets: [ActivityDayBucket]
}

/// 纯聚合逻辑：无 I/O、无单例、无当前时间依赖。
public enum ActivityStatisticsCalculator {
    /// 计算指定窗口的统计。
    ///
    /// - Parameters:
    ///   - records: 任意顺序的历史记录，内部只做筛选，不修改入参。
    ///   - window: 今天 / 近 7 日 / 近 30 日 / 今年（日历年年初到参考日）。
    ///   - reference: “现在”的参考时刻，测试注入固定日期。
    ///   - calendar: 日历（其 timeZone 会被显式替换为传入时区）。
    ///   - timeZone: 计算自然日边界使用的时区。
    public static func aggregate(
        _ records: [ActivityRecord],
        window: StatisticsWindow,
        reference: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> ActivityStatistics {
        var calendar = calendar
        calendar.timeZone = timeZone

        let todayStart = calendar.startOfDay(for: reference)
        guard let exclusiveEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: todayStart
        ) else {
            preconditionFailure("日历计算自然日边界失败")
        }
        let base = windowBase(for: window, todayStart: todayStart, calendar: calendar)
        let range = DateInterval(start: base.start, end: exclusiveEnd)

        let inWindow = records.filter { record in
            record.date >= range.start && record.date < range.end
        }

        var completedFocusDuration: TimeInterval = 0
        var completedFocusCount = 0
        var completedRestDuration: TimeInterval = 0
        var completedRestCount = 0
        var skippedFocusCount = 0
        var skippedRestCount = 0
        var longestCompletedFocus: TimeInterval = 0

        // 先建满窗口内每一天的零值桶，保证无记录的日子也出现在图表里，
        // DST 切换日由 Calendar 负责 23/25 小时的边界。
        var buckets: [Date: ActivityDayBucket] = [:]
        var orderedDays: [Date] = []
        orderedDays.reserveCapacity(base.dayCount)
        for offset in 0..<base.dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: base.start) else {
                preconditionFailure("日历计算桶日期失败")
            }
            orderedDays.append(day)
            buckets[day] = ActivityDayBucket(
                day: day,
                completedFocusDuration: 0,
                completedFocusCount: 0,
                completedRestDuration: 0,
                completedRestCount: 0
            )
        }

        for record in inWindow {
            let day = calendar.startOfDay(for: record.date)
            let existing = buckets[day]
            var focusDuration = existing?.completedFocusDuration ?? 0
            var focusCount = existing?.completedFocusCount ?? 0
            var restDuration = existing?.completedRestDuration ?? 0
            var restCount = existing?.completedRestCount ?? 0

            switch record.phase {
            case .focus:
                if record.outcome == .completed {
                    completedFocusDuration += record.activeDuration
                    completedFocusCount += 1
                    longestCompletedFocus = max(longestCompletedFocus, record.activeDuration)
                    focusDuration += record.activeDuration
                    focusCount += 1
                } else if record.outcome == .skipped {
                    skippedFocusCount += 1
                }
            case .rest:
                if record.outcome == .completed {
                    completedRestDuration += record.activeDuration
                    completedRestCount += 1
                    restDuration += record.activeDuration
                    restCount += 1
                } else if record.outcome == .skipped {
                    skippedRestCount += 1
                }
            }

            buckets[day] = ActivityDayBucket(
                day: day,
                completedFocusDuration: focusDuration,
                completedFocusCount: focusCount,
                completedRestDuration: restDuration,
                completedRestCount: restCount
            )
        }

        let restDecisions = completedRestCount + skippedRestCount
        let adherence: Double? = restDecisions > 0
            ? Double(completedRestCount) / Double(restDecisions)
            : nil

        return ActivityStatistics(
            window: window,
            range: range,
            completedFocusDuration: completedFocusDuration,
            completedFocusCount: completedFocusCount,
            completedRestDuration: completedRestDuration,
            completedRestCount: completedRestCount,
            skippedFocusCount: skippedFocusCount,
            skippedRestCount: skippedRestCount,
            longestCompletedFocusDuration: longestCompletedFocus,
            breakAdherence: adherence,
            dayBuckets: orderedDays.map { buckets[$0]! }
        )
    }

    /// 计算窗口起点（含）与覆盖的自然日数。
    ///
    /// 固定窗口从参考日往前数 `dayCount - 1` 天；今年窗口取公历年
    /// 1 月 1 日 00:00，桶数为年初到参考日（含当天）之间的日历日数。
    /// 所有日期数学都经由 Calendar 完成，不假设一天 86400 秒，
    /// 因此闰年与 DST 切换日（23/25 小时）都能得到恰好一个桶。
    private static func windowBase(
        for window: StatisticsWindow,
        todayStart: Date,
        calendar: Calendar
    ) -> (start: Date, dayCount: Int) {
        switch window {
        case .today, .last7Days, .last30Days:
            let dayCount = window.fixedDayCount!
            guard let start = calendar.date(
                byAdding: .day,
                value: -(dayCount - 1),
                to: todayStart
            ) else {
                preconditionFailure("日历计算自然日边界失败")
            }
            return (start, dayCount)
        case .thisYear:
            // 只保留年份组件再构造日期：在注入时区下得到今年 1 月 1 日 00:00。
            let yearComponents = calendar.dateComponents([.year], from: todayStart)
            guard let yearStart = calendar.date(from: yearComponents) else {
                preconditionFailure("日历计算年初边界失败")
            }
            // 两个本地午夜之间的 .day 差即跨过的日历日数；+1 把参考日当天计入。
            let elapsedDays = calendar.dateComponents(
                [.day],
                from: yearStart,
                to: todayStart
            ).day ?? 0
            return (yearStart, elapsedDays + 1)
        }
    }

    /// 最近历史，按日期降序（newest first）；同一时刻按 id 字典序兜底，
    /// 保证输出完全确定。不限制条数时传 nil。
    public static func recentRecords(
        _ records: [ActivityRecord],
        limit: Int? = nil
    ) -> [ActivityRecord] {
        let sorted = records.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
        guard let limit, limit >= 0 else { return sorted }
        return Array(sorted.prefix(limit))
    }
}
