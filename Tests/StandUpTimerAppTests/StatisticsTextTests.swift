import XCTest
import SwiftUI
@testable import StandUpTimerApp
import StandUpTimerCore

/// Stage 6B：统计面板纯文案格式化规则。
/// 不依赖系统时间与本地化环境：语言显式传入，时区固定 UTC。
@MainActor
final class StatisticsTextTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let utc = TimeZone(identifier: "UTC")!

    private func makeRecord(
        date: Date,
        phase: StandUpTimer.Phase = .focus,
        mode: StandUpTimer.Mode = .single,
        round: Int = 1,
        restKind: StandUpTimer.RestKind = .short,
        outcome: ActivityRecord.Outcome = .completed,
        planned: TimeInterval = 600,
        active: TimeInterval? = nil
    ) -> ActivityRecord {
        ActivityRecord(
            date: date,
            phase: phase,
            mode: mode,
            focusRound: round,
            restKind: restKind,
            outcome: outcome,
            plannedDuration: planned,
            activeDuration: active ?? planned
        )
    }

    // MARK: 1. 时长：显式零值与不足一分钟

    func testZeroDurationHasExplicitMinuteText() {
        XCTAssertEqual(StatisticsText.duration(0, language: .english), "0 min")
        XCTAssertEqual(StatisticsText.duration(0, language: .chinese), "0 分钟")
        // 非有限值同样走零分支，不输出 NaN/inf。
        XCTAssertEqual(StatisticsText.duration(.nan, language: .english), "0 min")
        XCTAssertEqual(StatisticsText.duration(-30, language: .chinese), "0 分钟")
    }

    func testSubMinuteDuration() {
        XCTAssertEqual(StatisticsText.duration(30, language: .english), "<1 min")
        XCTAssertEqual(StatisticsText.duration(30, language: .chinese), "不足 1 分钟")
    }

    // MARK: 2. 时长：分钟、小时、混合

    func testMinuteAndHourDurationFormatting() {
        XCTAssertEqual(StatisticsText.duration(45 * 60, language: .english), "45 min")
        XCTAssertEqual(StatisticsText.duration(45 * 60, language: .chinese), "45 分钟")

        XCTAssertEqual(StatisticsText.duration(60 * 60, language: .english), "1 h")
        XCTAssertEqual(StatisticsText.duration(60 * 60, language: .chinese), "1 小时")

        XCTAssertEqual(StatisticsText.duration(90 * 60, language: .english), "1 h 30 min")
        XCTAssertEqual(
            StatisticsText.duration(90 * 60, language: .chinese),
            "1 小时 30 分钟"
        )

        XCTAssertEqual(StatisticsText.duration(2 * 60 * 60, language: .english), "2 h")
        XCTAssertEqual(StatisticsText.duration(2 * 60 * 60, language: .chinese), "2 小时")
    }

    // MARK: 2b. 超大有限时长：不得 trap，返回无数据文案

    func testHugeFiniteDurationsReturnNoDataWithoutTrapping() {
        // 前置条件文档化：越过 Int.max 的运行时值确实无法由 Int(exactly:) 表示。
        // 经 nextUp 与变量传递，避免编译器把常量折叠成编译期溢出诊断。
        let boundary = Double(Int.max).nextUp
        XCTAssertNil(Int(exactly: boundary))

        // Double 域内最大有限值；若直接 Int(...) 转换会立即 fatal error。
        XCTAssertEqual(
            StatisticsText.duration(.greatestFiniteMagnitude, language: .english),
            "No data"
        )
        XCTAssertEqual(
            StatisticsText.duration(.greatestFiniteMagnitude, language: .chinese),
            "暂无数据"
        )

        // 刚越过安全转换边界的有限值：分钟数超过 Int.max。
        let overBoundarySeconds = Double(Int.max) * 60
        XCTAssertTrue(overBoundarySeconds.isFinite)
        XCTAssertEqual(
            StatisticsText.duration(overBoundarySeconds, language: .english),
            "No data"
        )
        XCTAssertEqual(
            StatisticsText.duration(overBoundarySeconds, language: .chinese),
            "暂无数据"
        )
    }

    func testLargeButRepresentableDurationsDoNotRegress() {
        // 一整年：525,600 分钟 → 8,760 小时。
        let oneYear: TimeInterval = 60 * 60 * 24 * 365
        XCTAssertEqual(
            StatisticsText.duration(oneYear, language: .english),
            "8760 h"
        )
        XCTAssertEqual(
            StatisticsText.duration(oneYear, language: .chinese),
            "8760 小时"
        )

        // 10,000 分钟 = 166 小时 40 分。
        XCTAssertEqual(
            StatisticsText.duration(10_000 * 60, language: .english),
            "166 h 40 min"
        )
        XCTAssertEqual(
            StatisticsText.duration(10_000 * 60, language: .chinese),
            "166 小时 40 分钟"
        )
    }

    // MARK: 3. 休息遵守率：nil 与百分比

    func testAdherenceNilShowsNoData() {
        XCTAssertEqual(
            StatisticsText.adherence(nil, language: .english),
            "No data"
        )
        XCTAssertEqual(
            StatisticsText.adherence(nil, language: .chinese),
            "暂无数据"
        )
    }

    func testAdherencePercentRounding() {
        XCTAssertEqual(StatisticsText.adherence(0.75, language: .english), "75%")
        XCTAssertEqual(StatisticsText.adherence(0.75, language: .chinese), "75%")
        XCTAssertEqual(StatisticsText.adherence(1.0 / 3.0, language: .english), "33%")
        XCTAssertEqual(StatisticsText.adherence(0, language: .english), "0%")
    }

    // MARK: 4. 阶段文案：专注 / 休息 / 长休，双语

    func testPhaseTextBilingual() {
        let focus = makeRecord(date: t0, phase: .focus)
        XCTAssertEqual(StatisticsText.phase(focus, language: .english), "Focus")
        XCTAssertEqual(StatisticsText.phase(focus, language: .chinese), "专注")

        let shortRest = makeRecord(
            date: t0,
            phase: .rest,
            mode: .fourRound,
            round: 2,
            restKind: .short
        )
        XCTAssertEqual(StatisticsText.phase(shortRest, language: .english), "Break")
        XCTAssertEqual(StatisticsText.phase(shortRest, language: .chinese), "休息")

        let longRest = makeRecord(
            date: t0,
            phase: .rest,
            mode: .fourRound,
            round: 4,
            restKind: .long,
            planned: 900
        )
        XCTAssertEqual(StatisticsText.phase(longRest, language: .english), "Long break")
        XCTAssertEqual(StatisticsText.phase(longRest, language: .chinese), "长休")
    }

    // MARK: 5. 结果文案，双语

    func testOutcomeTextBilingual() {
        XCTAssertEqual(
            StatisticsText.outcome(.completed, language: .english),
            "Completed"
        )
        XCTAssertEqual(
            StatisticsText.outcome(.completed, language: .chinese),
            "已完成"
        )
        XCTAssertEqual(
            StatisticsText.outcome(.skipped, language: .english),
            "Skipped"
        )
        XCTAssertEqual(
            StatisticsText.outcome(.skipped, language: .chinese),
            "已跳过"
        )
        XCTAssertEqual(
            StatisticsText.outcome(.cancelled, language: .english),
            "Cancelled"
        )
        XCTAssertEqual(
            StatisticsText.outcome(.cancelled, language: .chinese),
            "已取消"
        )
    }

    // MARK: 6. 日期时间：语言跟随 AppLanguage，小时制跟随系统 Locale

    /// 12 小时制系统偏好（en_US 的 ICU hour cycle 固定为 12 小时）。
    private let twelveHourSystem = Locale(identifier: "en_US")
    /// 24 小时制系统偏好（en_GB 的 ICU hour cycle 固定为 24 小时）。
    private let twentyFourHourSystem = Locale(identifier: "en_GB")

    // macOS 在分钟与 AM/PM 之间使用窄不换行空格（U+202F），断言前规范化为普通空格。
    private func normalized(_ string: String) -> String {
        let narrowSpace = String(UnicodeScalar(0x202F)!)
        return string.replacingOccurrences(of: narrowSpace, with: " ")
    }

    /// 应用语言 × 系统小时制四象限：文案语言只看 AppLanguage，
    /// 12/24 小时只看 systemLocale。
    func testDateTimeLanguageAndHourCycleMatrix() {
        let morning = t0.addingTimeInterval(9 * 3_600)
        let afternoon = t0.addingTimeInterval(13 * 3_600)

        // English + 12 小时系统：英文日期 + AM/PM。
        var morningText = normalized(StatisticsText.dateTime(
            morning, language: .english, timeZone: utc, systemLocale: twelveHourSystem
        ))
        XCTAssertTrue(morningText.contains("Jan 1, 2001"), "实际：\(morningText)")
        XCTAssertTrue(morningText.contains("9:00 AM"), "实际：\(morningText)")
        var afternoonText = normalized(StatisticsText.dateTime(
            afternoon, language: .english, timeZone: utc, systemLocale: twelveHourSystem
        ))
        XCTAssertTrue(afternoonText.contains("1:00 PM"), "实际：\(afternoonText)")
        XCTAssertFalse(afternoonText.contains("13:00"))

        // English + 24 小时系统：英文日期 + 09/13，无 AM/PM。
        morningText = StatisticsText.dateTime(
            morning, language: .english, timeZone: utc, systemLocale: twentyFourHourSystem
        )
        XCTAssertTrue(morningText.contains("Jan 1, 2001"), "实际：\(morningText)")
        XCTAssertTrue(morningText.contains("09:00"), "实际：\(morningText)")
        afternoonText = StatisticsText.dateTime(
            afternoon, language: .english, timeZone: utc, systemLocale: twentyFourHourSystem
        )
        XCTAssertTrue(afternoonText.contains("13:00"), "实际：\(afternoonText)")
        XCTAssertFalse(afternoonText.contains("PM"))

        // Chinese + 12 小时系统：中文日期 + 上午/下午（时段词来自应用语言 Locale）。
        morningText = normalized(StatisticsText.dateTime(
            morning, language: .chinese, timeZone: utc, systemLocale: twelveHourSystem
        ))
        XCTAssertTrue(morningText.contains("2001年1月1日"), "实际：\(morningText)")
        XCTAssertTrue(morningText.contains("上午9:00"), "实际：\(morningText)")
        afternoonText = normalized(StatisticsText.dateTime(
            afternoon, language: .chinese, timeZone: utc, systemLocale: twelveHourSystem
        ))
        XCTAssertTrue(afternoonText.contains("下午1:00"), "实际：\(afternoonText)")
        XCTAssertFalse(afternoonText.contains("PM"))

        // Chinese + 24 小时系统：中文日期 + 09/13，无时段词。
        morningText = StatisticsText.dateTime(
            morning, language: .chinese, timeZone: utc, systemLocale: twentyFourHourSystem
        )
        XCTAssertTrue(morningText.contains("2001年1月1日"), "实际：\(morningText)")
        XCTAssertTrue(morningText.contains("09:00"), "实际：\(morningText)")
        afternoonText = StatisticsText.dateTime(
            afternoon, language: .chinese, timeZone: utc, systemLocale: twentyFourHourSystem
        )
        XCTAssertTrue(afternoonText.contains("13:00"), "实际：\(afternoonText)")
        XCTAssertFalse(afternoonText.contains("下午"))
    }

    /// 复现验收问题 2：系统 Locale 为中文时，English 界面的日期与时段仍必须全英文，
    /// 不得出现任何年/月/日或中文时段词；小时制仍取系统偏好（zh_CN 为 24 小时）。
    func testEnglishInterfaceStaysEnglishUnderChineseSystemLocale() {
        let chineseSystem = Locale(identifier: "zh_CN")
        let midnight = StatisticsText.dateTime(
            t0, language: .english, timeZone: utc, systemLocale: chineseSystem
        )
        XCTAssertTrue(midnight.contains("Jan 1, 2001"), "实际：\(midnight)")
        XCTAssertTrue(midnight.contains("00:00"), "实际：\(midnight)")
        for chineseMarker in ["年", "月", "日", "上午", "下午", "凌晨", "中午"] {
            XCTAssertFalse(midnight.contains(chineseMarker), "实际：\(midnight)")
        }

        let afternoon = StatisticsText.dateTime(
            t0.addingTimeInterval(13 * 3_600),
            language: .english,
            timeZone: utc,
            systemLocale: chineseSystem
        )
        XCTAssertTrue(afternoon.contains("13:00"), "实际：\(afternoon)")
        XCTAssertFalse(afternoon.contains("下午"))
    }

    /// 对称保证：系统 Locale 为英文时，Chinese 界面的日期与时段词仍必须是中文。
    func testChineseInterfaceStaysChineseUnderEnglishSystemLocale() {
        let morning = StatisticsText.dateTime(
            t0.addingTimeInterval(9 * 3_600),
            language: .chinese,
            timeZone: utc,
            systemLocale: twelveHourSystem
        )
        XCTAssertTrue(morning.contains("2001年1月1日"), "实际：\(morning)")
        XCTAssertTrue(morning.contains("上午9:00"), "实际：\(morning)")
        XCTAssertFalse(morning.contains("AM"))

        // 同一应用语言、24 小时系统偏好：时段词消失，数字制跟随系统。
        let afternoon = StatisticsText.dateTime(
            t0.addingTimeInterval(13 * 3_600),
            language: .chinese,
            timeZone: utc,
            systemLocale: twentyFourHourSystem
        )
        XCTAssertTrue(afternoon.contains("13:00"), "实际：\(afternoon)")
        XCTAssertFalse(afternoon.contains("下午"))
    }

    // MARK: 6b. 时区与轴标签

    func testDateTimeAndAxisDayRespectInjectedTimeZone() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")! // 固定 UTC+8，无 DST

        // 同一 UTC 午夜时刻，在 UTC+8 是当天 08:00；应用语言英文 + 24 小时系统。
        let shifted = StatisticsText.dateTime(
            t0,
            language: .english,
            timeZone: shanghai,
            systemLocale: twentyFourHourSystem
        )
        XCTAssertTrue(shifted.contains("08:00"), "实际：\(shifted)")
        XCTAssertTrue(shifted.contains("Jan 1, 2001"), "实际：\(shifted)")

        // 轴标签同样按时区取自然日：UTC 20:00 在 UTC+8 已是次日，双语各自表达。
        let evening = t0.addingTimeInterval(20 * 3_600)
        XCTAssertEqual(
            StatisticsText.axisDay(evening, language: .english, timeZone: shanghai),
            "Jan 2"
        )
        XCTAssertEqual(
            StatisticsText.axisDay(evening, language: .chinese, timeZone: shanghai),
            "1月2日"
        )
    }

    /// 轴标签月份语言只跟随 AppLanguage，与机器当前 Locale 无关。
    func testAxisDayFollowsAppLanguageNotMachineLocale() {
        XCTAssertEqual(
            StatisticsText.axisDay(t0, language: .english, timeZone: utc),
            "Jan 1"
        )
        XCTAssertEqual(
            StatisticsText.axisDay(t0, language: .chinese, timeZone: utc),
            "1月1日"
        )
    }

    // MARK: 6c. 今年窗口的月度轴标签：语言归属与时区

    func testAxisMonthFollowsAppLanguageNotMachineLocale() {
        // t0 = 2001-01-01 UTC；再取一个 3 月的时刻验证非首月。
        let march = t0.addingTimeInterval(59 * 24 * 3_600) // 2001-03-01 UTC

        XCTAssertEqual(
            StatisticsText.axisMonth(t0, language: .english, timeZone: utc),
            "Jan"
        )
        XCTAssertEqual(
            StatisticsText.axisMonth(t0, language: .chinese, timeZone: utc),
            "1月"
        )
        XCTAssertEqual(
            StatisticsText.axisMonth(march, language: .english, timeZone: utc),
            "Mar"
        )
        XCTAssertEqual(
            StatisticsText.axisMonth(march, language: .chinese, timeZone: utc),
            "3月"
        )
    }

    func testAxisMonthRespectsInjectedTimeZone() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")! // 固定 UTC+8，无 DST
        // UTC 1 月 31 日 20:00 在 UTC+8 已是 2 月 1 日 04:00。
        let utcEvening = t0.addingTimeInterval(30 * 24 * 3_600 + 20 * 3_600)

        XCTAssertEqual(
            StatisticsText.axisMonth(utcEvening, language: .english, timeZone: utc),
            "Jan"
        )
        XCTAssertEqual(
            StatisticsText.axisMonth(utcEvening, language: .english, timeZone: shanghai),
            "Feb"
        )
        XCTAssertEqual(
            StatisticsText.axisMonth(utcEvening, language: .chinese, timeZone: shanghai),
            "2月"
        )
    }

    // MARK: 7. 中断记录的实际/计划时长

    func testInterruptedDetailBilingual() {
        XCTAssertEqual(
            StatisticsText.interruptedDetail(
                active: 120,
                planned: 600,
                language: .english
            ),
            "2 min / 10 min"
        )
        XCTAssertEqual(
            StatisticsText.interruptedDetail(
                active: 120,
                planned: 600,
                language: .chinese
            ),
            "2 分钟 / 10 分钟"
        )
        XCTAssertEqual(
            StatisticsText.interruptedDetailAccessibility(
                active: 120,
                planned: 600,
                language: .english
            ),
            "Active 2 min, planned 10 min"
        )
        XCTAssertEqual(
            StatisticsText.interruptedDetailAccessibility(
                active: 120,
                planned: 600,
                language: .chinese
            ),
            "实际 2 分钟，计划 10 分钟"
        )
    }

    // MARK: 7b. completed 记录的时长与无障碍读法

    func testCompletedDetailBilingual() {
        let record = makeRecord(
            date: t0,
            outcome: .completed,
            planned: 600,
            active: 600
        )

        XCTAssertEqual(
            StatisticsText.completedDetail(record, language: .english),
            "10 min"
        )
        XCTAssertEqual(
            StatisticsText.completedDetail(record, language: .chinese),
            "10 分钟"
        )
        XCTAssertEqual(
            StatisticsText.completedDetailAccessibility(record, language: .english),
            "Completed in 10 min"
        )
        XCTAssertEqual(
            StatisticsText.completedDetailAccessibility(record, language: .chinese),
            "已完成，用时 10 分钟"
        )
    }

    // MARK: 8. 窗口名称与图表摘要

    func testWindowNamesBilingual() {
        XCTAssertEqual(
            StatisticsText.windowName(.today, language: .english),
            "Today"
        )
        XCTAssertEqual(
            StatisticsText.windowName(.last7Days, language: .chinese),
            "近 7 天"
        )
        XCTAssertEqual(
            StatisticsText.windowName(.last30Days, language: .chinese),
            "近 30 天"
        )
        XCTAssertEqual(
            StatisticsText.windowName(.thisYear, language: .english),
            "This Year"
        )
        XCTAssertEqual(
            StatisticsText.windowName(.thisYear, language: .chinese),
            "今年"
        )
    }

    func testChartSummaryNamesThisYearWindowBilingually() {
        let records = [
            makeRecord(date: t0.addingTimeInterval(600), planned: 600),
            makeRecord(
                date: t0.addingTimeInterval(1_200),
                phase: .rest,
                mode: .fourRound,
                round: 2,
                restKind: .short,
                planned: 300
            )
        ]
        // 参考日 2001-01-02：今年窗口覆盖元旦与参考日，两条记录都在窗内。
        let statistics = ActivityStatisticsCalculator.aggregate(
            records,
            window: .thisYear,
            reference: t0.addingTimeInterval(24 * 3_600),
            calendar: Calendar(identifier: .gregorian),
            timeZone: utc
        )

        let english = StatisticsText.chartSummary(statistics, language: .english)
        XCTAssertTrue(english.hasPrefix("This Year:"), "实际：\(english)")
        XCTAssertTrue(english.contains("focus time 10 min"), "实际：\(english)")
        XCTAssertTrue(english.contains("completed breaks 1"), "实际：\(english)")

        let chinese = StatisticsText.chartSummary(statistics, language: .chinese)
        XCTAssertTrue(chinese.hasPrefix("今年："), "实际：\(chinese)")
        XCTAssertTrue(chinese.contains("专注 1 次"), "实际：\(chinese)")
        XCTAssertTrue(chinese.contains("完成休息 1 次"), "实际：\(chinese)")
    }

    func testChartSummaryIsLabelStyleWithoutPluralErrors() {
        let single = [
            makeRecord(date: t0.addingTimeInterval(600), planned: 600),
            makeRecord(
                date: t0.addingTimeInterval(1_200),
                phase: .rest,
                mode: .fourRound,
                round: 2,
                restKind: .short,
                planned: 300
            )
        ]
        let statistics = ActivityStatisticsCalculator.aggregate(
            single,
            window: .today,
            reference: t0.addingTimeInterval(1_800),
            calendar: Calendar(identifier: .gregorian),
            timeZone: utc
        )

        let english = StatisticsText.chartSummary(statistics, language: .english)
        // 标签式表达：名词在数字前，任何数量都不触发复数错误。
        XCTAssertFalse(english.contains("1 sessions"), "实际：\(english)")
        XCTAssertFalse(english.contains("1 breaks"), "实际：\(english)")
        XCTAssertTrue(english.hasPrefix("Today:"), "实际：\(english)")
        XCTAssertTrue(english.contains("focus time 10 min"), "实际：\(english)")
        XCTAssertTrue(english.contains("focus sessions 1"), "实际：\(english)")
        XCTAssertTrue(english.contains("break time 5 min"), "实际：\(english)")
        XCTAssertTrue(english.contains("completed breaks 1"), "实际：\(english)")

        let chinese = StatisticsText.chartSummary(statistics, language: .chinese)
        XCTAssertTrue(chinese.hasPrefix("今天："), "实际：\(chinese)")
        XCTAssertTrue(chinese.contains("专注 1 次"), "实际：\(chinese)")
        XCTAssertTrue(chinese.contains("完成休息 1 次"), "实际：\(chinese)")
        XCTAssertTrue(chinese.contains("10 分钟"))
        XCTAssertTrue(chinese.contains("5 分钟"))
    }

    func testChartSummaryStaysNaturalWithMultipleRecords() {
        let multiple = [
            makeRecord(date: t0.addingTimeInterval(600), planned: 600),
            makeRecord(date: t0.addingTimeInterval(1_200), planned: 600),
            makeRecord(
                date: t0.addingTimeInterval(1_800),
                phase: .rest,
                mode: .fourRound,
                round: 1,
                restKind: .short,
                planned: 300
            ),
            makeRecord(
                date: t0.addingTimeInterval(2_400),
                phase: .rest,
                mode: .fourRound,
                round: 2,
                restKind: .short,
                planned: 300
            ),
            makeRecord(
                date: t0.addingTimeInterval(3_000),
                phase: .rest,
                mode: .fourRound,
                round: 3,
                restKind: .short,
                planned: 300
            )
        ]
        let statistics = ActivityStatisticsCalculator.aggregate(
            multiple,
            window: .today,
            reference: t0.addingTimeInterval(3_600),
            calendar: Calendar(identifier: .gregorian),
            timeZone: utc
        )

        let english = StatisticsText.chartSummary(statistics, language: .english)
        XCTAssertFalse(english.contains("1 sessions"), "实际：\(english)")
        XCTAssertFalse(english.contains("1 breaks"), "实际：\(english)")
        XCTAssertTrue(english.contains("focus sessions 2"), "实际：\(english)")
        XCTAssertTrue(english.contains("completed breaks 3"), "实际：\(english)")
        XCTAssertTrue(english.contains("focus time 20 min"), "实际：\(english)")
        XCTAssertTrue(english.contains("break time 15 min"), "实际：\(english)")
    }

    // MARK: 9. 无数据文案

    func testNoDataText() {
        XCTAssertEqual(StatisticsText.noData(language: .english), "No data")
        XCTAssertEqual(StatisticsText.noData(language: .chinese), "暂无数据")
    }

    // MARK: 10. 统计窗口标题走本地化键，不再硬编码可见字符串

    func testWindowTitleComesFromLocalization() {
        XCTAssertEqual(StatisticsView.windowTitle(for: .english), "Focus Statistics")
        XCTAssertEqual(StatisticsView.windowTitle(for: .chinese), "专注统计")
    }
}
