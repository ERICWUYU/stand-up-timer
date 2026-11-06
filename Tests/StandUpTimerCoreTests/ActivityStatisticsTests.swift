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
}
