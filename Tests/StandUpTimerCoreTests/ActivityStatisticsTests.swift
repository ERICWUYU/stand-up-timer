import XCTest
@testable import StandUpTimerCore

/// Stage 6A：纯聚合逻辑的窗口边界、DST、休息遵守率无数据态、日桶与最近历史。
/// Calendar、TimeZone、参考日期全部注入，不依赖机器本地设置。
final class ActivityStatisticsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private lazy var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0,
        second: Int = 0,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    private func makeRecord(
        date: Date,
        phase: StandUpTimer.Phase = .focus,
        outcome: ActivityRecord.Outcome = .completed,
        active: TimeInterval = 600,
        planned: TimeInterval? = nil,
        mode: StandUpTimer.Mode = .single,
        round: Int = 1,
        restKind: StandUpTimer.RestKind = .short
    ) -> ActivityRecord {
        ActivityRecord(
            date: date,
            phase: phase,
            mode: mode,
            focusRound: round,
            restKind: restKind,
            outcome: outcome,
            plannedDuration: planned ?? active,
            activeDuration: active
        )
    }

    // MARK: 1. 窗口边界（注入 UTC）

    func testTodayWindowIncludesOnlyCalendarDayRecords() {
        let ref = date(2026, 1, 15, hour: 12, timeZone: utc)
        let records = [
            makeRecord(date: date(2026, 1, 15, hour: 0, minute: 0, second: 0, timeZone: utc)),
            makeRecord(date: date(2026, 1, 15, hour: 23, minute: 59, second: 59, timeZone: utc)),
            makeRecord(date: date(2026, 1, 14, hour: 23, minute: 59, second: 59, timeZone: utc)),
            makeRecord(date: date(2026, 1, 16, hour: 0, minute: 0, second: 0, timeZone: utc))
        ]

        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .today,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.completedFocusCount, 2)
        XCTAssertEqual(stats.range.start, date(2026, 1, 15, hour: 0, timeZone: utc))
        XCTAssertEqual(stats.range.end, date(2026, 1, 16, hour: 0, timeZone: utc))
        XCTAssertEqual(stats.dayBuckets.count, 1)
    }

    func testSevenDayWindowBoundariesAreHalfOpenOnCalendarDays() {
        let ref = date(2026, 1, 15, hour: 12, timeZone: utc)
        let windowStart = date(2026, 1, 9, hour: 0, timeZone: utc)
        let windowEnd = date(2026, 1, 16, hour: 0, timeZone: utc)

        let records = [
            makeRecord(date: windowStart),                                            // 恰好包含
            makeRecord(date: windowStart.addingTimeInterval(-1)),                    // 早一秒排除
            makeRecord(date: windowEnd.addingTimeInterval(-1)),                      // 末秒包含
            makeRecord(date: windowEnd)                                              // 半开端点排除
        ]

        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .last7Days,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.range.start, windowStart)
        XCTAssertEqual(stats.range.end, windowEnd)
        XCTAssertEqual(stats.completedFocusCount, 2)
        XCTAssertEqual(stats.dayBuckets.count, 7)
    }

    func testThirtyDayWindowIncludesExactlyThirtyCalendarDays() {
        let ref = date(2026, 1, 15, hour: 12, timeZone: utc)
        let windowStart = date(2025, 12, 17, hour: 0, timeZone: utc)

        let records = [
            makeRecord(date: windowStart),                         // 第 30 天前的 00:00，包含
            makeRecord(date: windowStart.addingTimeInterval(-1))   // 再早一秒排除
        ]

        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .last30Days,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.range.start, windowStart)
        XCTAssertEqual(stats.completedFocusCount, 1)
        XCTAssertEqual(stats.dayBuckets.count, 30)
        // 桶按日升序，零记录日也保留，图表不需要补洞。
        XCTAssertEqual(stats.dayBuckets.first?.day, windowStart)
        XCTAssertEqual(
            stats.dayBuckets.last?.day,
            date(2026, 1, 15, hour: 0, timeZone: utc)
        )
    }

    // MARK: 2. DST 边界

    func testDayBucketsRemainOnePerDayAcrossDSTBoundary() {
        // 2026-03-08 02:00 纽约春令时切换，当天只有 23 小时。
        let ref = date(2026, 3, 11, hour: 12, timeZone: newYork)
        let recordOnShortDay = makeRecord(
            date: date(2026, 3, 8, hour: 10, timeZone: newYork),
            active: 900
        )

        let stats = ActivityStatisticsCalculator.aggregate(
            [recordOnShortDay],
            window: .last7Days,
            reference: ref,
            calendar: utcCalendar,
            timeZone: newYork
        )

        XCTAssertEqual(stats.dayBuckets.count, 7)
        let shortDay = date(2026, 3, 8, hour: 0, timeZone: newYork)
        let nextDay = date(2026, 3, 9, hour: 0, timeZone: newYork)
        // 本地午夜之间只有 23 小时，证明桶按本地日历日而不是固定 86400 秒切分。
        XCTAssertEqual(nextDay.timeIntervalSince(shortDay), 23 * 3_600)

        let bucket = stats.dayBuckets.first { $0.day == shortDay }
        XCTAssertEqual(bucket?.completedFocusDuration, 900)
        XCTAssertEqual(bucket?.completedFocusCount, 1)
        XCTAssertEqual(stats.completedFocusDuration, 900)
    }

    // MARK: 3. 聚合数值与休息遵守率

    func testAggregatesCountsDurationsAndLongestFocus() {
        let ref = date(2026, 1, 15, hour: 12, timeZone: utc)
        let records = [
            makeRecord(date: ref.addingTimeInterval(-60), active: 600),
            makeRecord(date: ref.addingTimeInterval(-120), active: 1_500),
            makeRecord(date: ref.addingTimeInterval(-180), active: 300),
            makeRecord(date: ref.addingTimeInterval(-240), outcome: .skipped, active: 100),
            makeRecord(date: ref.addingTimeInterval(-300), outcome: .skipped, active: 200),
            makeRecord(date: ref.addingTimeInterval(-360), outcome: .cancelled, active: 400),
            makeRecord(
                date: ref.addingTimeInterval(-420),
                phase: .rest,
                outcome: .completed,
                active: 300
            ),
            makeRecord(
                date: ref.addingTimeInterval(-480),
                phase: .rest,
                outcome: .completed,
                active: 300
            ),
            makeRecord(
                date: ref.addingTimeInterval(-510),
                phase: .rest,
                outcome: .completed,
                active: 300
            ),
            makeRecord(
                date: ref.addingTimeInterval(-540),
                phase: .rest,
                outcome: .skipped,
                active: 60
            )
        ]

        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .today,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.completedFocusCount, 3)
        XCTAssertEqual(stats.completedFocusDuration, 2_400)
        XCTAssertEqual(stats.longestCompletedFocusDuration, 1_500)
        XCTAssertEqual(stats.skippedFocusCount, 2)
        XCTAssertEqual(stats.completedRestCount, 3)
        XCTAssertEqual(stats.completedRestDuration, 900)
        XCTAssertEqual(stats.skippedRestCount, 1)
        // 3 完成 / (3 完成 + 1 跳过)。
        XCTAssertEqual(stats.breakAdherence ?? 0, 0.75, accuracy: 0.000_001)
    }

    func testBreakAdherenceIsNilWhenNoRestDecisionsExist() {
        let ref = date(2026, 1, 15, hour: 12, timeZone: utc)
        let onlyFocus = [
            makeRecord(date: ref, active: 600),
            makeRecord(date: ref.addingTimeInterval(-60), outcome: .cancelled, active: 30)
        ]

        let stats = ActivityStatisticsCalculator.aggregate(
            onlyFocus,
            window: .today,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertNil(stats.breakAdherence)
        XCTAssertEqual(stats.completedRestCount, 0)
        XCTAssertEqual(stats.skippedRestCount, 0)
    }

    func testEmptyHistoryProducesZeroValuesAndNilAdherence() {
        let ref = date(2026, 1, 15, hour: 12, timeZone: utc)
        let stats = ActivityStatisticsCalculator.aggregate(
            [],
            window: .last7Days,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.completedFocusCount, 0)
        XCTAssertEqual(stats.completedFocusDuration, 0)
        XCTAssertEqual(stats.longestCompletedFocusDuration, 0)
        XCTAssertNil(stats.breakAdherence)
        XCTAssertEqual(stats.dayBuckets.count, 7)
        XCTAssertTrue(stats.dayBuckets.allSatisfy { $0.completedFocusCount == 0 })
    }

    // MARK: 4. 最近历史

    func testRecentRecordsNewestFirstWithDeterministicTiebreakAndLimit() {
        let d1 = date(2026, 1, 10, hour: 9, timeZone: utc)
        let d2 = date(2026, 1, 11, hour: 9, timeZone: utc)
        let focusAtD1 = makeRecord(date: d1, phase: .focus)
        let focusAtD2 = makeRecord(date: d2, phase: .focus)
        let restAtD2 = makeRecord(date: d2, phase: .rest)
        let records = [focusAtD1, restAtD2, focusAtD2]

        let recent = ActivityStatisticsCalculator.recentRecords(records, limit: 2)
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent.allSatisfy { $0.date == d2 })
        // 同时刻按 id 字典序，输出确定。
        XCTAssertEqual(recent.map(\.id), recent.map(\.id).sorted())

        let all = ActivityStatisticsCalculator.recentRecords(records)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first?.date, d2)
        XCTAssertEqual(all.last?.date, d1)

        XCTAssertEqual(ActivityStatisticsCalculator.recentRecords(records, limit: 0), [])
    }

    // MARK: 5. 今年窗口（日历年 year-to-date，半开区间）

    func testThisYearWindowRunsFromJanFirstToTomorrowMidnight() {
        let ref = date(2026, 6, 15, hour: 12, timeZone: utc)

        let stats = ActivityStatisticsCalculator.aggregate(
            [],
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(
            stats.range.start,
            date(2026, 1, 1, hour: 0, timeZone: utc)
        )
        // 半开右端：参考日次日 00:00，而不是下一年元旦。
        XCTAssertEqual(
            stats.range.end,
            date(2026, 6, 16, hour: 0, timeZone: utc)
        )
        // 1/1 到 6/15（含）：31+28+31+30+31+15 = 166 个自然日，2026 非闰年。
        XCTAssertEqual(stats.dayBuckets.count, 166)
        XCTAssertEqual(
            stats.dayBuckets.first?.day,
            date(2026, 1, 1, hour: 0, timeZone: utc)
        )
        XCTAssertEqual(
            stats.dayBuckets.last?.day,
            date(2026, 6, 15, hour: 0, timeZone: utc)
        )
        // 零值桶：空历史下每天一个且全为零，没有未来日期的桶。
        XCTAssertTrue(stats.dayBuckets.allSatisfy { $0.completedFocusCount == 0 })
    }

    func testThisYearHalfOpenBoundariesIncludeEndpointsAndExcludeOutside() {
        let ref = date(2026, 6, 15, hour: 12, timeZone: utc)
        let yearStart = date(2026, 1, 1, hour: 0, timeZone: utc)
        let exclusiveEnd = date(2026, 6, 16, hour: 0, timeZone: utc)

        let records = [
            makeRecord(date: yearStart),                         // 恰好年初，包含
            makeRecord(date: yearStart.addingTimeInterval(-1)), // 早一秒（上一年），排除
            makeRecord(date: date(2026, 6, 15, hour: 23, minute: 59, second: 59, timeZone: utc)), // 末秒包含
            makeRecord(date: exclusiveEnd),                     // 半开端点（次日 00:00），排除
            makeRecord(date: date(2025, 12, 31, hour: 23, minute: 59, second: 59, timeZone: utc)) // 上一年，排除
        ]

        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.range.start, yearStart)
        XCTAssertEqual(stats.range.end, exclusiveEnd)
        XCTAssertEqual(stats.completedFocusCount, 2)
    }

    func testThisYearOnJanFirstProducesExactlyOneBucket() {
        let ref = date(2026, 1, 1, hour: 12, timeZone: utc)

        let stats = ActivityStatisticsCalculator.aggregate(
            [makeRecord(date: ref)],
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.dayBuckets.count, 1)
        XCTAssertEqual(
            stats.dayBuckets.first?.day,
            date(2026, 1, 1, hour: 0, timeZone: utc)
        )
        XCTAssertEqual(stats.range.start, date(2026, 1, 1, hour: 0, timeZone: utc))
        XCTAssertEqual(stats.range.end, date(2026, 1, 2, hour: 0, timeZone: utc))
        XCTAssertEqual(stats.completedFocusCount, 1)
    }

    func testThisYearLeapYearCountsFeb29AndAllDaysThroughReference() {
        // 2024 是闰年；参考日 3 月 1 日：31 + 29 + 1 = 61 个桶。
        let ref = date(2024, 3, 1, hour: 12, timeZone: utc)

        let stats = ActivityStatisticsCalculator.aggregate(
            [],
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.dayBuckets.count, 61)
        XCTAssertEqual(
            stats.dayBuckets.first?.day,
            date(2024, 1, 1, hour: 0, timeZone: utc)
        )
        XCTAssertEqual(
            stats.dayBuckets.last?.day,
            date(2024, 3, 1, hour: 0, timeZone: utc)
        )
        // 2 月 29 日必须真实占一个桶，而不是被 86400 秒算术跳过或重复。
        let feb29 = date(2024, 2, 29, hour: 0, timeZone: utc)
        XCTAssertTrue(stats.dayBuckets.contains { $0.day == feb29 })
        XCTAssertEqual(
            Set(stats.dayBuckets.map(\.day)).count,
            stats.dayBuckets.count,
            "桶日期必须互不相同"
        )
    }

    func testThisYearNonLeapYearLastDayHas365Buckets() {
        // 2026 非闰年；参考日为全年最后一天，恰好 365 个桶、无第 366 天。
        let ref = date(2026, 12, 31, hour: 12, timeZone: utc)

        let stats = ActivityStatisticsCalculator.aggregate(
            [],
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.dayBuckets.count, 365)
        XCTAssertEqual(
            stats.dayBuckets.first?.day,
            date(2026, 1, 1, hour: 0, timeZone: utc)
        )
        XCTAssertEqual(
            stats.dayBuckets.last?.day,
            date(2026, 12, 31, hour: 0, timeZone: utc)
        )
        // 半开右端是下一年元旦。
        XCTAssertEqual(stats.range.end, date(2027, 1, 1, hour: 0, timeZone: utc))
    }

    func testThisYearBucketsFollowCalendarDaysAcrossDST() {
        // 纽约 2026-03-08 春令时（23 小时）、2026-11-01 秋令时（25 小时）。
        // 参考日 11 月 5 日：非闰年第 309 天（1–10 月共 304 天 + 5）。
        let ref = date(2026, 11, 5, hour: 12, timeZone: newYork)
        let recordOnShortDay = makeRecord(
            date: date(2026, 3, 8, hour: 10, timeZone: newYork),
            active: 900
        )

        let stats = ActivityStatisticsCalculator.aggregate(
            [recordOnShortDay],
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: newYork
        )

        XCTAssertEqual(stats.dayBuckets.count, 309)

        let novFirst = date(2026, 11, 1, hour: 0, timeZone: newYork)
        let novSecond = date(2026, 11, 2, hour: 0, timeZone: newYork)
        // 秋令时本地午夜间隔 25 小时，证明桶按本地日历日而非固定秒数切分。
        XCTAssertEqual(novSecond.timeIntervalSince(novFirst), 25 * 3_600)
        XCTAssertTrue(stats.dayBuckets.contains { $0.day == novFirst })
        XCTAssertTrue(stats.dayBuckets.contains { $0.day == novSecond })

        let shortDay = date(2026, 3, 8, hour: 0, timeZone: newYork)
        let bucket = stats.dayBuckets.first { $0.day == shortDay }
        XCTAssertEqual(bucket?.completedFocusDuration, 900)
        XCTAssertEqual(bucket?.completedFocusCount, 1)
        XCTAssertEqual(stats.completedFocusDuration, 900)
    }

    func testThisYearExcludesPreviousYearAndKeepsAggregationSemantics() {
        let ref = date(2026, 6, 15, hour: 12, timeZone: utc)
        let records = [
            // 上一年的专注与休息全部排除。
            makeRecord(date: date(2025, 12, 31, hour: 23, timeZone: utc), active: 999),
            makeRecord(
                date: date(2025, 12, 30, hour: 10, timeZone: utc),
                phase: .rest,
                active: 999
            ),
            // 今年的记录参与聚合，遵守率语义与其他窗口完全一致。
            makeRecord(date: date(2026, 1, 1, hour: 9, timeZone: utc), active: 1_500),
            makeRecord(
                date: date(2026, 6, 15, hour: 10, timeZone: utc),
                phase: .rest,
                outcome: .completed,
                active: 300
            ),
            makeRecord(
                date: date(2026, 6, 14, hour: 10, timeZone: utc),
                phase: .rest,
                outcome: .skipped,
                active: 60
            )
        ]

        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(stats.completedFocusCount, 1)
        XCTAssertEqual(stats.completedFocusDuration, 1_500)
        XCTAssertEqual(stats.longestCompletedFocusDuration, 1_500)
        XCTAssertEqual(stats.completedRestCount, 1)
        XCTAssertEqual(stats.completedRestDuration, 300)
        XCTAssertEqual(stats.skippedRestCount, 1)
        // 1 完成 /（1 完成 + 1 跳过）。
        XCTAssertEqual(stats.breakAdherence ?? 0, 0.5, accuracy: 0.000_001)
    }
}
