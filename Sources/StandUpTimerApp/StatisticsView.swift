import AppKit
import Charts
import StandUpTimerCore
import SwiftUI

/// 本地统计窗口内容：窗口选择、2×2 指标卡、每日时长柱状图、最近活动。
///
/// 所有数据来自 `StatisticsViewModel`（最终来自 Core 的纯聚合器），
/// 视图层不做任何统计计算。颜色只使用语义色与固定的专注橙/休息绿，
/// 不指定 appearance，Light/Dark 全部跟随系统。
struct StatisticsView: View {
    @ObservedObject var viewModel: StatisticsViewModel

    static func windowTitle(for language: AppLanguage) -> String {
        L10n.text("statistics.window.title", language: language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                noticeBanner
                statCards
                if viewModel.recentRecords.isEmpty {
                    emptyState
                } else {
                    chartSection
                    recentSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(StatisticsWindowTitle(title: windowTitle))
    }

    private var language: AppLanguage {
        viewModel.language
    }

    private var windowTitle: String {
        Self.windowTitle(for: language)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Text(L10n.text("statistics.heading", language: language))
                .font(.headline)
            Spacer()
            Picker(
                L10n.text("statistics.heading", language: language),
                selection: windowBinding
            ) {
                Text(StatisticsText.windowName(.today, language: language))
                    .tag(StatisticsWindow.today)
                Text(StatisticsText.windowName(.last7Days, language: language))
                    .tag(StatisticsWindow.last7Days)
                Text(StatisticsText.windowName(.last30Days, language: language))
                    .tag(StatisticsWindow.last30Days)
                Text(StatisticsText.windowName(.thisYear, language: language))
                    .tag(StatisticsWindow.thisYear)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel(Text(L10n.text(
                "statistics.picker.accessibility",
                language: language
            )))
        }
    }

    private var windowBinding: Binding<StatisticsWindow> {
        Binding(
            get: { viewModel.selectedWindow },
            set: { viewModel.select($0) }
        )
    }

    // MARK: - 通知横幅

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = viewModel.notice {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)

                Text(noticeMessage(notice))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if case let .corruptFileQuarantined(backup: backupURL) = notice {
                    Button(L10n.text(
                        "statistics.notice.revealBackup",
                        language: language
                    )) {
                        NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                    }
                    .font(.caption)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
        }
    }

    private func noticeMessage(_ notice: HistoryNotice) -> String {
        let key: String
        switch notice {
        case .corruptFileQuarantined:
            key = "statistics.notice.corrupt"
        case .storageUnavailable:
            key = "statistics.notice.storageUnavailable"
        case .writeFailed:
            key = "statistics.notice.writeFailed"
        }
        return L10n.text(key, language: language)
    }

    // MARK: - 指标卡

    private var statCards: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        return LazyVGrid(columns: columns, spacing: 12) {
            statCard(
                icon: "target",
                color: .orange,
                title: L10n.text("statistics.card.focusTime", language: language),
                value: StatisticsText.duration(
                    viewModel.statistics.completedFocusDuration,
                    language: language
                )
            )
            statCard(
                icon: "checkmark.circle",
                color: .orange,
                title: L10n.text("statistics.card.focusSessions", language: language),
                value: "\(viewModel.statistics.completedFocusCount)"
            )
            statCard(
                icon: "clock",
                color: .green,
                title: L10n.text("statistics.card.longestFocus", language: language),
                value: viewModel.statistics.longestCompletedFocusDuration > 0
                    ? StatisticsText.duration(
                        viewModel.statistics.longestCompletedFocusDuration,
                        language: language
                    )
                    : StatisticsText.noData(language: language)
            )
            statCard(
                icon: "figure.walk",
                color: .green,
                title: L10n.text("statistics.card.breakAdherence", language: language),
                value: StatisticsText.adherence(
                    viewModel.statistics.breakAdherence,
                    language: language
                )
            )
        }
    }

    private func statCard(
        icon: String,
        color: Color,
        title: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 84)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - 图表

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
        }
    }

    /// 今年窗口按月聚合，其余窗口按自然日。
    private var isMonthly: Bool {
        viewModel.selectedWindow == .thisYear
    }

    private var chart: some View {
        let entries = chartEntries
        let focusName = L10n.text("statistics.chart.series.focus", language: language)
        let restName = L10n.text("statistics.chart.series.rest", language: language)
        let xUnit: Calendar.Component = isMonthly ? .month : .day
        let xAxisName = L10n.text(
            isMonthly ? "statistics.chart.month" : "statistics.chart.day",
            language: language
        )

        return Chart(entries) { entry in
            BarMark(
                x: .value(xAxisName, entry.date, unit: xUnit),
                y: .value(
                    L10n.text("statistics.chart.minutes", language: language),
                    entry.minutes
                )
            )
            .foregroundStyle(by: .value(
                L10n.text("statistics.chart.series", language: language),
                entry.seriesName
            ))
            .position(by: .value(
                L10n.text("statistics.chart.series", language: language),
                entry.seriesName
            ))
        }
        .chartForegroundStyleScale([
            focusName: Color.orange,
            restName: Color.green
        ])
        .chartXAxis {
            AxisMarks(values: .stride(by: xUnit, count: axisStride)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        if isMonthly {
                            Text(StatisticsText.axisMonth(
                                date,
                                language: language,
                                timeZone: .autoupdatingCurrent
                            ))
                        } else {
                            Text(StatisticsText.axisDay(
                                date,
                                language: language,
                                timeZone: .autoupdatingCurrent
                            ))
                        }
                    }
                }
            }
        }
        .frame(height: 220)
        // 整张图表给一个完整、确定的 VoiceOver 摘要，隐藏逐柱默认读法。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            StatisticsText.chartSummary(viewModel.statistics, language: language)
        ))
    }

    /// 日图：30 天窗口每 5 天一个刻度避免重叠，其余逐日；
    /// 月图：超过 6 个月时每 2 个月一个刻度，保证 560pt 最小窗宽下
    /// 标签不重叠、不需要横向滚动。全部为确定性刻度，不依赖自动避让。
    private var axisStride: Int {
        switch viewModel.selectedWindow {
        case .today, .last7Days:
            return 1
        case .last30Days:
            return 5
        case .thisYear:
            return viewModel.monthlyBuckets.count > 6 ? 2 : 1
        }
    }

    private struct ChartEntry: Identifiable {
        let id: String
        let date: Date
        let seriesName: String
        let minutes: Double
    }

    private var chartEntries: [ChartEntry] {
        isMonthly ? monthlyChartEntries : dailyChartEntries
    }

    /// 每个自然日两条数据（专注/休息），零值日也保留，
    /// 与 Core 给出的 dayBuckets 一一对应。
    private var dailyChartEntries: [ChartEntry] {
        let focusName = L10n.text("statistics.chart.series.focus", language: language)
        let restName = L10n.text("statistics.chart.series.rest", language: language)

        return viewModel.statistics.dayBuckets.flatMap { bucket in
            [
                ChartEntry(
                    id: "day-\(bucket.day.timeIntervalSinceReferenceDate)-focus",
                    date: bucket.day,
                    seriesName: focusName,
                    minutes: (bucket.completedFocusDuration / 60).rounded()
                ),
                ChartEntry(
                    id: "day-\(bucket.day.timeIntervalSinceReferenceDate)-rest",
                    date: bucket.day,
                    seriesName: restName,
                    minutes: (bucket.completedRestDuration / 60).rounded()
                )
            ]
        }
    }

    /// 每个月两条数据（专注/休息），零值月也保留，
    /// 与 `MonthlyStatistics` 产出的月桶一一对应；归并逻辑在纯函数 helper 中。
    private var monthlyChartEntries: [ChartEntry] {
        let focusName = L10n.text("statistics.chart.series.focus", language: language)
        let restName = L10n.text("statistics.chart.series.rest", language: language)

        return viewModel.monthlyBuckets.flatMap { bucket in
            [
                ChartEntry(
                    id: "month-\(bucket.month.timeIntervalSinceReferenceDate)-focus",
                    date: bucket.month,
                    seriesName: focusName,
                    minutes: (bucket.completedFocusDuration / 60).rounded()
                ),
                ChartEntry(
                    id: "month-\(bucket.month.timeIntervalSinceReferenceDate)-rest",
                    date: bucket.month,
                    seriesName: restName,
                    minutes: (bucket.completedRestDuration / 60).rounded()
                )
            ]
        }
    }

    // MARK: - 最近活动

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("statistics.recent.heading", language: language))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(viewModel.recentRecords) { record in
                    recentRow(record)
                    if record.id != viewModel.recentRecords.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func recentRow(_ record: ActivityRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(StatisticsText.phase(record, language: language))
                    .font(.subheadline)
                Text(StatisticsText.dateTime(
                    record.date,
                    language: language,
                    timeZone: .autoupdatingCurrent,
                    systemLocale: .autoupdatingCurrent
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(StatisticsText.outcome(record.outcome, language: language))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(outcomeColor(record.outcome))
                // completed 与中断记录都展示时长，只是语义不同：
                // 前者是实际用时，后者是 实际 / 计划。
                Text(recentDetailText(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(Text(recentDetailAccessibilityText(record)))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func recentDetailText(_ record: ActivityRecord) -> String {
        if record.outcome == .completed {
            return StatisticsText.completedDetail(record, language: language)
        }
        return StatisticsText.interruptedDetail(
            active: record.activeDuration,
            planned: record.plannedDuration,
            language: language
        )
    }

    private func recentDetailAccessibilityText(_ record: ActivityRecord) -> String {
        if record.outcome == .completed {
            return StatisticsText.completedDetailAccessibility(record, language: language)
        }
        return StatisticsText.interruptedDetailAccessibility(
            active: record.activeDuration,
            planned: record.plannedDuration,
            language: language
        )
    }

    private func outcomeColor(_ outcome: ActivityRecord.Outcome) -> Color {
        switch outcome {
        case .completed: return .green
        case .skipped: return .orange
        case .cancelled: return .secondary
        }
    }

    // MARK: - 空状态

    /// macOS 13 没有 ContentUnavailableView，使用等价的自定义空状态。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L10n.text("statistics.empty.title", language: language))
                .font(.headline)
            Text(L10n.text("statistics.empty.body", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
    }
}

/// 只负责同步窗口标题：窗口身份由控制器的稳定 identifier 决定，与标题无关。
/// 语言在窗口打开期间切换时，SwiftUI 重绘会经由这里更新 NSWindow.title。
private struct StatisticsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = TitleView()
        view.applyTitle(title)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitleView)?.applyTitle(title)
    }

    private final class TitleView: NSView {
        private var title = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyTitle(title)
        }

        func applyTitle(_ title: String) {
            self.title = title
            window?.title = title
        }
    }
}
