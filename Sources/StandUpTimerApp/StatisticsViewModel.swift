import Combine
import Foundation
import StandUpTimerCore

/// 统计窗口的界面状态。
///
/// 自身不做任何聚合运算：窗口计算全部委托给 Core 的
/// `ActivityStatisticsCalculator`，这里只负责订阅 `TimerModel` 的发布数据、
/// 持有当前窗口选择，并把“现在 / 日历 / 时区”作为可注入闭包保存，
/// 使测试在固定参考时刻下完全确定。
@MainActor
final class StatisticsViewModel: ObservableObject {
    /// 最近活动列表的固定上限；始终基于完整历史截取，与窗口选择无关。
    static let recentLimit = 20

    @Published private(set) var selectedWindow: StatisticsWindow = .today
    @Published private(set) var statistics: ActivityStatistics
    /// 今年窗口的月桶快照：只在聚合事件中随 `statistics` 一起更新，
    /// 绝不在 SwiftUI 渲染期重新读取时间/日历/时区提供方。
    /// 非今年窗口恒为空数组，避免旧的月桶残留到其他窗口。
    @Published private(set) var monthlyBuckets: [ActivityMonthBucket] = []
    @Published private(set) var recentRecords: [ActivityRecord] = []
    @Published private(set) var notice: HistoryNotice?
    @Published private(set) var language: AppLanguage

    /// 弱引用模型：窗口控制器与 App 生命周期持有模型，视图模型不形成环。
    private weak var model: TimerModel?
    private var cancellables = Set<AnyCancellable>()

    private let nowProvider: () -> Date
    private let calendarProvider: () -> Calendar
    private let timeZoneProvider: () -> TimeZone

    init(
        model: TimerModel,
        now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.model = model
        self.nowProvider = now
        self.calendarProvider = calendar
        self.timeZoneProvider = timeZone
        self.language = model.language
        self.notice = model.historyNotice
        // 初始快照与后续刷新走同一条一致路径：同一组提供方采样
        // 同时产出统计与月桶，初始窗口是 .today，月桶为空。
        let initial = Self.makeSnapshot(
            records: model.activityRecords,
            window: .today,
            now: now(),
            calendar: calendar(),
            timeZone: timeZone()
        )
        self.statistics = initial.statistics
        self.monthlyBuckets = initial.monthlyBuckets
        bind(model: model)
        // 订阅在绑定之后建立，初始值由这里显式装载一次。
        reload()
    }

    /// 切换统计窗口；最近活动列表与窗口无关，不重新截取。
    func select(_ window: StatisticsWindow) {
        guard window != selectedWindow else { return }
        selectedWindow = window
        guard let model else { return }
        refresh(records: model.activityRecords, window: selectedWindow)
    }

    /// 每次窗口展示时显式刷新。复用的 NSWindow 不会重新触发 onAppear，
    /// 因此重开窗口必须走这个入口而不是依赖 SwiftUI 生命周期。
    func reload() {
        guard let model else { return }
        language = model.language
        notice = model.historyNotice
        refresh(records: model.activityRecords, window: selectedWindow)
        recentRecords = ActivityStatisticsCalculator.recentRecords(
            model.activityRecords,
            limit: Self.recentLimit
        )
    }

    // MARK: - 订阅

    /// 三个发布者各绑定一次，weak self 防止保留环；
    /// 不订阅 `$now`，避免每秒 tick 触发整窗重算。
    private func bind(model: TimerModel) {
        // @Published 在 willSet 时发值：回调里同步回读 model 属性会拿到
        // 旧值，因此记录变化直接使用发布者给出的新数组参数，不做回读。
        model.$activityRecords
            .sink { [weak self] records in
                self?.handleRecordsChange(records)
            }
            .store(in: &cancellables)

        model.$historyNotice
            .sink { [weak self] notice in
                self?.notice = notice
            }
            .store(in: &cancellables)

        model.$language
            .sink { [weak self] language in
                self?.language = language
            }
            .store(in: &cancellables)
    }

    /// 历史记录变化：重算当前窗口统计并刷新最近活动，
    /// 不触碰 language/notice，避免一次变化产生重复赋值。
    private func handleRecordsChange(_ records: [ActivityRecord]) {
        refresh(records: records, window: selectedWindow)
        recentRecords = ActivityStatisticsCalculator.recentRecords(
            records,
            limit: Self.recentLimit
        )
    }

    /// 唯一的聚合刷新入口：一次刷新只采样一次 now/calendar/timeZone，
    /// 卡片统计与月桶共用同一上下文，从同一组日桶派生，
    /// 因此窗口跨过月界/年界或提供方本身变化时两者不可能漂移。
    private func refresh(
        records: [ActivityRecord],
        window: StatisticsWindow
    ) {
        let reference = nowProvider()
        let calendar = calendarProvider()
        let timeZone = timeZoneProvider()
        let snapshot = Self.makeSnapshot(
            records: records,
            window: window,
            now: reference,
            calendar: calendar,
            timeZone: timeZone
        )
        statistics = snapshot.statistics
        monthlyBuckets = snapshot.monthlyBuckets
    }

    /// 用同一组 reference/calendar/timeZone 产出统计与匹配的月桶。
    /// 非今年窗口月桶恒为空；今年窗口的月桶直接归并本次新建的日桶，
    /// 不再二次采样提供方。
    private static func makeSnapshot(
        records: [ActivityRecord],
        window: StatisticsWindow,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> AggregationSnapshot {
        let statistics = ActivityStatisticsCalculator.aggregate(
            records,
            window: window,
            reference: now,
            calendar: calendar,
            timeZone: timeZone
        )
        let monthlyBuckets: [ActivityMonthBucket]
        if window == .thisYear {
            monthlyBuckets = MonthlyStatistics.buckets(
                from: statistics.dayBuckets,
                reference: now,
                calendar: calendar,
                timeZone: timeZone
            )
        } else {
            monthlyBuckets = []
        }
        return AggregationSnapshot(
            statistics: statistics,
            monthlyBuckets: monthlyBuckets
        )
    }

    /// 一次聚合事件的一致快照：两个成员必须来自同一组提供方采样。
    private struct AggregationSnapshot {
        let statistics: ActivityStatistics
        let monthlyBuckets: [ActivityMonthBucket]
    }
}
