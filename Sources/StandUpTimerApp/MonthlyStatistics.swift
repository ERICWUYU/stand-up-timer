import Foundation
import StandUpTimerCore

/// Stage 6B「今年」窗口的月度聚合桶。
///
/// Core 只负责日历年窗口边界与日桶；按月展示是 App 图表层的呈现决策，
/// 因此月度归并放在这里而不是 Core：无 AppKit、无 SwiftUI、无单例，
/// Calendar/TimeZone/参考时刻全部显式注入，输出在测试中完全确定。
struct ActivityMonthBucket: Identifiable, Equatable, Sendable {
    /// 该月 1 日 00:00（注入时区下的 startOfDay）。
    let month: Date
    let completedFocusDuration: TimeInterval
    let completedFocusCount: Int
    let completedRestDuration: TimeInterval
    let completedRestCount: Int

    var id: Date { month }
}

/// 把 Core 的日桶归并为月桶的纯函数。
enum MonthlyStatistics {
    /// 基于 `.thisYear` 聚合出的日桶，生成 1 月到参考日所在月的月桶：
    /// 每月恰好一个（含零值月），不生成任何未来月份。
    ///
    /// 输入日桶已由 Core 过滤到今年窗口内，这里只做日历归并，
    /// 不重新读取或筛选历史记录。DST 与闰年全部交由 Calendar 处理。
    static func buckets(
        from dayBuckets: [ActivityDayBucket],
        reference: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> [ActivityMonthBucket] {
        var calendar = calendar
        calendar.timeZone = timeZone

        let todayStart = calendar.startOfDay(for: reference)
        let yearComponents = calendar.dateComponents([.year], from: todayStart)
        guard let yearStart = calendar.date(from: yearComponents) else {
            preconditionFailure("日历计算年初边界失败")
        }

        // 先按月份顺序建满 1 月 → 参考日所在月的零值桶。
        // 循环上界是参考日当天，结构上不可能产生未来月份。
        var monthStarts: [Date] = []
        var cursor = yearStart
        while cursor <= todayStart {
            monthStarts.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else {
                preconditionFailure("日历计算月度边界失败")
            }
            cursor = next
        }

        var accumulation: [Date: ActivityMonthBucket] = [:]
        for monthStart in monthStarts {
            accumulation[monthStart] = ActivityMonthBucket(
                month: monthStart,
                completedFocusDuration: 0,
                completedFocusCount: 0,
                completedRestDuration: 0,
                completedRestCount: 0
            )
        }

        for dayBucket in dayBuckets {
            let monthComponents = calendar.dateComponents(
                [.year, .month],
                from: dayBucket.day
            )
            guard let monthStart = calendar.date(from: monthComponents) else {
                preconditionFailure("日历计算月度边界失败")
            }
            // 调用约定：日桶必须来自今年窗口（1 月 → 参考月）。
            // 越界属于程序员错误，直接停止而不是静默丢数据。
            guard let existing = accumulation[monthStart] else {
                preconditionFailure("日桶落在今年窗口月份范围之外")
            }
            accumulation[monthStart] = ActivityMonthBucket(
                month: monthStart,
                completedFocusDuration: existing.completedFocusDuration
                    + dayBucket.completedFocusDuration,
                completedFocusCount: existing.completedFocusCount
                    + dayBucket.completedFocusCount,
                completedRestDuration: existing.completedRestDuration
                    + dayBucket.completedRestDuration,
                completedRestCount: existing.completedRestCount
                    + dayBucket.completedRestCount
            )
        }

        return monthStarts.map { accumulation[$0]! }
    }
}
