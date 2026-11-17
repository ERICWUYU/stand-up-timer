import XCTest
@testable import StandUpTimerApp
import StandUpTimerCore

/// Stage 6B「今年」月度归并纯函数：月桶序列、零值月、未来月份排除、
/// 求和一致性、元旦单月、DST 边界。
///
/// 日桶不手工构造（Core 的成员构造器不对外），统一由
/// `ActivityStatisticsCalculator.aggregate(.thisYear)` 产出后再归并，
/// 测试的正是生产调用链上的真实契约。Calendar/TimeZone/参考时刻全部注入。
final class MonthlyStatisticsTests: XCTestCase {
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
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func makeRecord(
        date: Date,
        phase: StandUpTimer.Phase = .focus,
        outcome: ActivityRecord.Outcome = .completed,
        active: TimeInterval = 600
    ) -> ActivityRecord {
        ActivityRecord(
            date: date,
            phase: phase,
            mode: .single,
            focusRound: 1,
            restKind: .short,
            outcome: outcome,
            plannedDuration: active,
            activeDuration: active
        )
    }

    private func makeMonthlyBuckets(
        records: [ActivityRecord],
        reference: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> [ActivityMonthBucket] {
        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .thisYear,
            reference: reference,
            calendar: calendar,
            timeZone: timeZone
        )
        return MonthlyStatistics.buckets(
            from: stats.dayBuckets,
            reference: reference,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    // MARK: 1. 月份序列、零值月与未来月份排除

    func testBucketsCoverJanuaryThroughReferenceMonthIncludingZeroMonths() {
        // 2032 是闰年；参考日 6 月 15 日，恰好 6 个月桶。
        let ref = date(2032, 6, 15, timeZone: utc)
        let records = [
            makeRecord(date: date(2032, 1, 15, timeZone: utc), active: 600),
            // 闰日记录必须正常落入 2 月桶。
            makeRecord(date: date(2032, 2, 29, timeZone: utc), active: 1_200),
            makeRecord(
                date: date(2032, 2, 20, hour: 10, timeZone: utc),
                phase: .rest,
                active: 300
            ),
            makeRecord(date: date(2032, 6, 10, timeZone: utc), active: 600)
        ]

        let buckets = makeMonthlyBuckets(
            records: records,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(buckets.map(\.month), [
            date(2032, 1, 1, hour: 0, timeZone: utc),
            date(2032, 2, 1, hour: 0, timeZone: utc),
            date(2032, 3, 1, hour: 0, timeZone: utc),
            date(2032, 4, 1, hour: 0, timeZone: utc),
            date(2032, 5, 1, hour: 0, timeZone: utc),
            date(2032, 6, 1, hour: 0, timeZone: utc)
        ])
        // 没有 7 月或更晚的未来月份桶。
        XCTAssertEqual(buckets.count, 6)
        XCTAssertEqual(buckets.last?.month, date(2032, 6, 1, hour: 0, timeZone: utc))

        // 1 月：一次 10 分钟专注。
        XCTAssertEqual(buckets[0].completedFocusDuration, 600)
        XCTAssertEqual(buckets[0].completedFocusCount, 1)
        XCTAssertEqual(buckets[0].completedRestCount, 0)

        // 2 月：专注 1200s（闰日）+ 休息 300s。
        XCTAssertEqual(buckets[1].completedFocusDuration, 1_200)
        XCTAssertEqual(buckets[1].completedFocusCount, 1)
        XCTAssertEqual(buckets[1].completedRestDuration, 300)
        XCTAssertEqual(buckets[1].completedRestCount, 1)

        // 3–5 月零记录，但桶必须保留。
        for index in 2...4 {
            XCTAssertEqual(buckets[index].completedFocusDuration, 0)
            XCTAssertEqual(buckets[index].completedFocusCount, 0)
            XCTAssertEqual(buckets[index].completedRestDuration, 0)
            XCTAssertEqual(buckets[index].completedRestCount, 0)
        }

        // 6 月：一次 10 分钟专注。
        XCTAssertEqual(buckets[5].completedFocusDuration, 600)
        XCTAssertEqual(buckets[5].completedFocusCount, 1)
    }

    // MARK: 2. 月桶求和与日窗口总量一致

    func testMonthlySumsEqualWindowTotals() {
        let ref = date(2032, 6, 15, timeZone: utc)
        let records = [
            makeRecord(date: date(2032, 1, 15, timeZone: utc), active: 600),
            makeRecord(date: date(2032, 3, 1, timeZone: utc), active: 900),
            makeRecord(
                date: date(2032, 6, 15, hour: 11, timeZone: utc),
                phase: .rest,
                active: 300
            )
        ]
        let stats = ActivityStatisticsCalculator.aggregate(
            records,
            window: .thisYear,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )
        let buckets = MonthlyStatistics.buckets(
            from: stats.dayBuckets,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(
            buckets.map(\.completedFocusDuration).reduce(0, +),
            stats.completedFocusDuration
        )
        XCTAssertEqual(
            buckets.map(\.completedFocusCount).reduce(0, +),
            stats.completedFocusCount
        )
        XCTAssertEqual(
            buckets.map(\.completedRestDuration).reduce(0, +),
            stats.completedRestDuration
        )
        XCTAssertEqual(
            buckets.map(\.completedRestCount).reduce(0, +),
            stats.completedRestCount
        )
    }

    // MARK: 3. 元旦参考日只有一个月桶

    func testJanFirstReferenceProducesSingleMonthBucket() {
        let ref = date(2032, 1, 1, timeZone: utc)
        let records = [
            makeRecord(date: date(2032, 1, 1, hour: 9, timeZone: utc), active: 600)
        ]

        let buckets = makeMonthlyBuckets(
            records: records,
            reference: ref,
            calendar: utcCalendar,
            timeZone: utc
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.month, date(2032, 1, 1, hour: 0, timeZone: utc))
        XCTAssertEqual(buckets.first?.completedFocusCount, 1)
        XCTAssertEqual(buckets.first?.completedFocusDuration, 600)
    }

    // MARK: 4. DST：月边界按本地日历，春令时当天记录归 3 月桶

    func testMonthlyBucketsFollowCalendarBoundariesAcrossDST() {
        // 纽约 2026-03-08 春令时；参考日 11 月 5 日，11 个月桶，无 12 月。
        let ref = date(2026, 11, 5, timeZone: newYork)
        let records = [
            makeRecord(date: date(2026, 3, 8, hour: 10, timeZone: newYork), active: 900),
            makeRecord(
                date: date(2026, 11, 1, hour: 10, timeZone: newYork),
                phase: .rest,
                active: 300
            )
        ]

        var calendar = Calendar(identifier: .gregorian)
        let buckets = makeMonthlyBuckets(
            records: records,
            reference: ref,
            calendar: calendar,
            timeZone: newYork
        )
        calendar.timeZone = newYork

        XCTAssertEqual(buckets.count, 11)
        XCTAssertEqual(
            buckets.first?.month,
            date(2026, 1, 1, hour: 0, timeZone: newYork)
        )
        XCTAssertEqual(
            buckets.last?.month,
            date(2026, 11, 1, hour: 0, timeZone: newYork)
        )

        let march = buckets.first {
            $0.month == date(2026, 3, 1, hour: 0, timeZone: newYork)
        }
        XCTAssertEqual(march?.completedFocusDuration, 900)
        XCTAssertEqual(march?.completedFocusCount, 1)

        let november = buckets.first {
            $0.month == date(2026, 11, 1, hour: 0, timeZone: newYork)
        }
        XCTAssertEqual(november?.completedRestDuration, 300)
        XCTAssertEqual(november?.completedRestCount, 1)

        // 月份起点互不相同且严格升序。
        XCTAssertEqual(Set(buckets.map(\.month)).count, buckets.count)
        XCTAssertEqual(buckets.map(\.month), buckets.map(\.month).sorted())
    }
}
