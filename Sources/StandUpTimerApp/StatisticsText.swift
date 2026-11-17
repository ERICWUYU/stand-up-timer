import Foundation
import StandUpTimerCore

/// 统计面板的全部文案格式化规则。
///
/// 纯函数、无 AppKit、无单例：语言与时间区都显式注入，输出在测试中
/// 完全确定。不使用 `DateComponentsFormatter` 的本地化样式——它对零值会
/// 输出 "0 sec"，且中文缩写在不同系统版本间不稳定，无法写成确定断言。
enum StatisticsText {
    /// 紧凑时长：零值显式输出 "0 min / 0 分钟"，不足一分钟给出独立文案，
    /// 其余按小时 + 分钟拼装，单位文案走本地化字符串。
    static func duration(
        _ seconds: TimeInterval,
        language: AppLanguage
    ) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return join(0, unit: minuteUnit(language: language))
        }

        // 先按原始秒数判定不足一分钟；若先四舍五入，30 秒会被进到 1 分钟。
        if seconds < 60 {
            return L10n.text("statistics.duration.lessThanOneMinute", language: language)
        }

        // Core 允许非常大的正有限时长；Double → Int 超范围会直接 trap。
        // 用 Int(exactly:) 做可失败转换：非有限、负数或超出 Int 表示范围
        // 都返回 nil，统一给出无数据文案，不伪造 0、不截断、不崩溃。
        let scaledMinutes = (seconds / 60).rounded()
        guard
            scaledMinutes.isFinite,
            scaledMinutes >= 0,
            let totalMinutes = Int(exactly: scaledMinutes)
        else {
            return noData(language: language)
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        switch (hours, minutes) {
        case (0, let minutes):
            return join(minutes, unit: minuteUnit(language: language))
        case let (hours, 0):
            return join(hours, unit: hourUnit(language: language))
        default:
            return "\(join(hours, unit: hourUnit(language: language))) \(join(minutes, unit: minuteUnit(language: language)))"
        }
    }

    /// 休息遵守率：nil（没有任何休息结果）必须显示明确的无数据状态，
    /// 禁止伪造成 0% 或 100%。
    static func adherence(
        _ value: Double?,
        language: AppLanguage
    ) -> String {
        guard let value else {
            return noData(language: language)
        }
        let percent = Int((value * 100).rounded())
        return String(
            format: L10n.text("statistics.unit.percent", language: language),
            percent
        )
    }

    static func noData(language: AppLanguage) -> String {
        L10n.text("statistics.noData", language: language)
    }

    /// 最近活动列表的完整日期时间。
    ///
    /// 语言归属（Stage 6B 人工验收问题 2）：
    /// - 日期文字、月份、顺序、AM/PM（上午/下午）的**语言**跟随应用内
    ///   `AppLanguage`，与机器系统 Locale 无关——English 界面不得出现中文日期；
    /// - 12/24 小时制是系统级偏好，只从 `systemLocale` 探测 hour cycle，
    ///   不借用它的任何文案。
    /// - TimeZone 显式注入，不依赖机器隐式状态。
    static func dateTime(
        _ date: Date,
        language: AppLanguage,
        timeZone: TimeZone,
        systemLocale: Locale
    ) -> String {
        let locale = appLocale(for: language)

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let dateText = dateFormatter.string(from: date)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        // 小时制只取系统偏好；模板再经应用语言 Locale 本地化，
        // 因此 English 得到 AM/PM，Chinese 得到 上午/下午。
        let template = uses24HourCycle(systemLocale: systemLocale) ? "Hm" : "hm"
        timeFormatter.setLocalizedDateFormatFromTemplate(template)
        let timeText = timeFormatter.string(from: date)

        return String(
            format: L10n.text("statistics.dateTime.format", language: language),
            dateText,
            timeText
        )
    }

    /// 图表 X 轴的短日期标签。月份语言与顺序只跟随应用语言，
    /// 不读取系统 Locale；TimeZone 决定落在哪个自然日。
    static func axisDay(
        _ date: Date,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLocale(for: language)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    /// 今年窗口月度图表 X 轴标签：English → "Jan"，Chinese → "1月"。
    /// 语言只跟随 AppLanguage，与机器系统 Locale 无关；
    /// TimeZone 决定该时刻归属哪个月份。
    static func axisMonth(
        _ date: Date,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLocale(for: language)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }

    /// 记录所属阶段的展示名；长休与普通休息区分文案，不只靠颜色。
    static func phase(
        _ record: ActivityRecord,
        language: AppLanguage
    ) -> String {
        switch record.phase {
        case .focus:
            return L10n.text("phase.focus", language: language)
        case .rest:
            return record.restKind == .long
                ? L10n.text("phase.longBreak", language: language)
                : L10n.text("phase.break", language: language)
        }
    }

    static func outcome(
        _ outcome: ActivityRecord.Outcome,
        language: AppLanguage
    ) -> String {
        let key: String
        switch outcome {
        case .completed: key = "statistics.outcome.completed"
        case .skipped: key = "statistics.outcome.skipped"
        case .cancelled: key = "statistics.outcome.cancelled"
        }
        return L10n.text(key, language: language)
    }

    /// completed 记录的可见时长片段：自然完成时活动时长等于计划时长，
    /// 直接展示本地化时长，不引入新的格式分支。
    static func completedDetail(
        _ record: ActivityRecord,
        language: AppLanguage
    ) -> String {
        duration(record.activeDuration, language: language)
    }

    /// completed 记录的完整无障碍读法。
    static func completedDetailAccessibility(
        _ record: ActivityRecord,
        language: AppLanguage
    ) -> String {
        String(
            format: L10n.text(
                "statistics.recent.completedDetailAccessibility",
                language: language
            ),
            duration(record.activeDuration, language: language)
        )
    }

    /// 跳过/取消记录的“实际 / 计划”时长片段。
    static func interruptedDetail(
        active: TimeInterval,
        planned: TimeInterval,
        language: AppLanguage
    ) -> String {
        String(
            format: L10n.text("statistics.recent.detail", language: language),
            duration(active, language: language),
            duration(planned, language: language)
        )
    }

    /// 跳过/取消记录的完整无障碍读法。
    static func interruptedDetailAccessibility(
        active: TimeInterval,
        planned: TimeInterval,
        language: AppLanguage
    ) -> String {
        String(
            format: L10n.text("statistics.recent.detailAccessibility", language: language),
            duration(active, language: language),
            duration(planned, language: language)
        )
    }

    static func windowName(
        _ window: StatisticsWindow,
        language: AppLanguage
    ) -> String {
        let key: String
        switch window {
        case .today: key = "statistics.window.today"
        case .last7Days: key = "statistics.window.last7Days"
        case .last30Days: key = "statistics.window.last30Days"
        case .thisYear: key = "statistics.window.thisYear"
        }
        return L10n.text(key, language: language)
    }

    /// 整张图表的 VoiceOver 汇总：图表对子元素的默认读法只念散点数值，
    /// 这里给一个完整、确定的摘要并隐藏子元素。
    static func chartSummary(
        _ statistics: ActivityStatistics,
        language: AppLanguage
    ) -> String {
        String(
            format: L10n.text("statistics.chart.summary", language: language),
            windowName(statistics.window, language: language),
            duration(statistics.completedFocusDuration, language: language),
            statistics.completedFocusCount,
            duration(statistics.completedRestDuration, language: language),
            statistics.completedRestCount
        )
    }

    // MARK: - 内部

    /// 应用语言对应的稳定 Locale：用户可见的日期/月份/时段文案只从这里出。
    /// 不用 `.autoupdatingCurrent`，否则 English 界面在中文系统上会显示中文日期。
    private static func appLocale(for language: AppLanguage) -> Locale {
        switch language {
        case .english:
            return Locale(identifier: "en_US")
        case .chinese:
            return Locale(identifier: "zh_Hans")
        }
    }

    /// 只探测系统偏好的小时制，不取用该 Locale 的任何文案。
    /// "j" 模板按 Locale 的 hour cycle 本地化：含大写 H 表示 24 小时制，
    /// 否则为带 AM/PM（或本地化时段词）的 12 小时制。
    private static func uses24HourCycle(systemLocale: Locale) -> Bool {
        let skeleton = DateFormatter.dateFormat(
            fromTemplate: "j",
            options: 0,
            locale: systemLocale
        ) ?? "h a"
        return skeleton.contains("H")
    }

    private static func minuteUnit(language: AppLanguage) -> String {
        L10n.text("statistics.unit.minute", language: language)
    }

    private static func hourUnit(language: AppLanguage) -> String {
        L10n.text("statistics.unit.hour", language: language)
    }

    /// 数字与单位之间的间距沿用界面既有习惯：中英文都保留一个空格
    /// （设置窗时长行即 "25 分钟" 样式）。
    private static func join(_ value: Int, unit: String) -> String {
        "\(value) \(unit)"
    }
}
