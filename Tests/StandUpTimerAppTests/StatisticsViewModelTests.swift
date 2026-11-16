import Combine
import XCTest
@testable import StandUpTimerApp
import StandUpTimerCore

/// Stage 6B：StatisticsViewModel 的订阅、窗口切换与注入提供方行为。
///
/// 时间提供方全部注入固定值，日历用格里高利、时区用 UTC，
/// 断言不依赖系统当前时间或测试执行时区。
@MainActor
final class StatisticsViewModelTests: XCTestCase {
    private enum Boom: Error { case injected }

    /// 2032-01-01 00:00:00 UTC，午夜参考点让自然日边界推导最简单。
    private let reference = Date(timeIntervalSinceReferenceDate: 978_307_200)

    // MARK: - 辅助

    private struct StorageHarness {
        let storage: TimerStorage
        let cleanup: () -> Void
    }

    /// 独立 suite + 清理闭包；调用方在用例里 `defer { harness.cleanup() }`。
    private func makeStorageHarness() -> StorageHarness {
        let suite = "standup-vm-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return StorageHarness(
            storage: UserDefaultsTimerStorage(defaults: defaults),
            cleanup: {
                defaults.removePersistentDomain(forName: suite)
            }
        )
    }

    private func makeRecord(
        date: Date,
        phase: StandUpTimer.Phase = .focus,
        outcome: ActivityRecord.Outcome = .completed,
        planned: TimeInterval = 600,
        active: TimeInterval? = nil
    ) -> ActivityRecord {
        ActivityRecord(
            date: date,
            phase: phase,
            mode: .single,
            focusRound: 1,
            restKind: .short,
            outcome: outcome,
            plannedDuration: planned,
            activeDuration: active ?? planned
        )
    }

    private func makeModel(
        storage: TimerStorage,
        now: Date? = nil,
        store: ActivityHistoryStoring? = nil
    ) -> TimerModel {
        TimerModel(
            now: now ?? reference,
            storage: storage,
            historyStore: store ?? InMemoryActivityHistory()
        )
    }

    private func makeViewModel(
        model: TimerModel,
        now: Date? = nil
    ) -> StatisticsViewModel {
        StatisticsViewModel(
            model: model,
            now: { now ?? self.reference },
            calendar: { Calendar(identifier: .gregorian) },
            timeZone: { TimeZone(identifier: "UTC")! }
        )
    }

    /// 可在测试中途变更的时间/时区提供方，并统计每次刷新的采样次数，
    /// 用来复现窗口跨过月界/年界或提供方本身变化时的上下文漂移缺陷。
    private final class MutableProviders {
        var now: Date
        var timeZone: TimeZone
        var nowSamples = 0
        var calendarSamples = 0
        var timeZoneSamples = 0

        /// 日历始终从当前 timeZone 现取，模拟生产的
        /// `Calendar.autoupdatingCurrent` 提供方。
        var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar
        }

        init(now: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) {
            self.now = now
            self.timeZone = timeZone
        }
    }

    private func makeMutableViewModel(
        model: TimerModel,
        providers: MutableProviders
    ) -> StatisticsViewModel {
        StatisticsViewModel(
            model: model,
            now: {
                providers.nowSamples += 1
                return providers.now
            },
            calendar: {
                providers.calendarSamples += 1
                return providers.calendar
            },
            timeZone: {
                providers.timeZoneSamples += 1
                return providers.timeZone
            }
        )
    }

    private func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    @discardableResult
    private func driveFocusToCompletion(_ model: TimerModel) -> ActivityRecord {
        let start = Date()
        model.performPrimaryAction()
        model.update(at: start.addingTimeInterval(25 * 60 + 60))
        let record = model.activityRecords.last
        XCTAssertNotNil(record)
        return record!
    }

    // MARK: 1. 聚合使用注入的现在/日历/时区，窗口切换重算

    func testAggregateUsesInjectedProvidersAndWindowSelection() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let store = InMemoryActivityHistory()
        try? store.append([
            makeRecord(date: reference.addingTimeInterval(3_600), planned: 600),
            makeRecord(date: reference.addingTimeInterval(-86_400), planned: 900)
        ])
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeViewModel(model: model)

        // 期望值使用与注入提供方相同的 UTC 日历，不能用机器本地时区。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        XCTAssertEqual(vm.selectedWindow, .today)
        XCTAssertEqual(vm.statistics.completedFocusCount, 1)
        XCTAssertEqual(vm.statistics.completedFocusDuration, 600)
        XCTAssertEqual(
            vm.statistics.range.start,
            calendar.startOfDay(for: reference)
        )

        vm.select(.last7Days)
        XCTAssertEqual(vm.statistics.window, .last7Days)
        XCTAssertEqual(vm.statistics.completedFocusCount, 2)
        XCTAssertEqual(vm.statistics.completedFocusDuration, 1500)
        XCTAssertEqual(vm.statistics.dayBuckets.count, 7)
        XCTAssertEqual(
            vm.statistics.range.start,
            calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: reference))
        )

        // 重复选择同一窗口不触发多余重算（至少结果保持不变）。
        vm.select(.last7Days)
        XCTAssertEqual(vm.statistics.completedFocusCount, 2)
    }

    // MARK: 2. 窗口打开期间记录变化自动刷新

    func testRecordChangeRefreshesWhileWindowOpen() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let model = makeModel(storage: harness.storage, now: Date())
        let vm = StatisticsViewModel(model: model)
        XCTAssertTrue(vm.recentRecords.isEmpty)

        let record = driveFocusToCompletion(model)

        XCTAssertEqual(vm.recentRecords.map(\.id), [record.id])
        XCTAssertEqual(vm.statistics.completedFocusCount, 1)
    }

    // MARK: 3. 最近活动固定上限 20，与窗口选择无关

    func testRecentCappedAtTwentyAndUnaffectedByWindow() {
        let store = InMemoryActivityHistory()
        let records = (0..<25).map { index in
            makeRecord(date: reference.addingTimeInterval(-TimeInterval(index) * 3_600))
        }
        try? store.append(records)
        let harness = makeStorageHarness()
        defer { harness.cleanup() }
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeViewModel(model: model)

        XCTAssertEqual(vm.recentRecords.count, 20)
        // newest first：最新一条是 index 0（reference 时刻）。
        XCTAssertEqual(vm.recentRecords.first?.date, reference)

        for window in [
            StatisticsWindow.today,
            .last7Days,
            .last30Days,
            .thisYear
        ] {
            vm.select(window)
            XCTAssertEqual(vm.recentRecords.count, 20, "窗口 \(window) 不应影响最近活动上限")
            XCTAssertEqual(vm.recentRecords.first?.date, reference)
        }
    }

    // MARK: 4. 无休息决策时遵守率为 nil；30 天窗口满桶

    func testNilBreakAdherenceAndThirtyDayBuckets() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let store = InMemoryActivityHistory()
        try? store.append([
            makeRecord(date: reference.addingTimeInterval(3_600))
        ])
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeViewModel(model: model)

        XCTAssertNil(vm.statistics.breakAdherence)

        vm.select(.last30Days)
        XCTAssertEqual(vm.statistics.dayBuckets.count, 30)
        XCTAssertNil(vm.statistics.breakAdherence)
        XCTAssertEqual(vm.statistics.completedFocusCount, 1)
    }

    // MARK: 5. 一次记录变化只产生一次发布（无重复绑定）

    func testSinglePublishedEmissionPerRecordChange() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let model = makeModel(storage: harness.storage, now: Date())
        let vm = StatisticsViewModel(model: model)

        var emissions = 0
        var cancellables = Set<AnyCancellable>()
        vm.$recentRecords
            .sink { _ in emissions += 1 }
            .store(in: &cancellables)
        let emissionsAfterSubscribe = emissions
        XCTAssertEqual(emissionsAfterSubscribe, 1)

        driveFocusToCompletion(model)

        XCTAssertEqual(
            emissions,
            emissionsAfterSubscribe + 1,
            "一次追加只能触发一次最近活动发布"
        )
    }

    // MARK: 6. 语言与历史通知沿发布链传递

    func testLanguageAndNoticePropagate() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let failingStore = InMemoryActivityHistory(appendError: Boom.injected)
        let model = makeModel(storage: harness.storage, now: Date(), store: failingStore)
        let vm = StatisticsViewModel(model: model)

        model.setLanguage(.chinese)
        XCTAssertEqual(vm.language, .chinese)

        // 写入必败：核心仍会结算阶段，但发布数组与最近活动必须保持旧值。
        let start = Date()
        model.performPrimaryAction()
        model.update(at: start.addingTimeInterval(25 * 60 + 60))
        XCTAssertEqual(model.phase, .rest, "阶段应已结算到休息，证明写入失败没有打断计时")
        XCTAssertEqual(vm.notice, .writeFailed)
        // 失败时旧数组不变，视图模型同样不更新。
        XCTAssertTrue(vm.recentRecords.isEmpty)
    }

    // MARK: 7. 显式 reload 保持窗口选择并重新读取模型状态

    func testReloadKeepsWindowAndRefreshesRecords() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        // 使用生产默认提供方（真实当前时间/自动更新日历时区），
        // 保证刚结算出的记录一定落在“今天”。
        let model = makeModel(storage: harness.storage, now: Date())
        let vm = StatisticsViewModel(model: model)
        vm.select(.last30Days)

        let record = driveFocusToCompletion(model)
        // 窗口控制器每次 show 都会调用 reload；窗口选择必须保留。
        vm.reload()

        XCTAssertEqual(vm.statistics.window, .last30Days)
        XCTAssertEqual(vm.statistics.completedFocusCount, 1)
        XCTAssertEqual(vm.recentRecords.map(\.id), [record.id])
    }

    // MARK: 8. 今年窗口：边界、月桶、reload/语言保持与单次发布

    func testThisYearSelectionBucketsReloadLanguageAndSingleEmission() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // 固定参考时刻是 UTC 午夜；年初/年末边界全部由注入日历推导，
        // 不硬编码具体年月日，避免对 reference 常量做易错的手工换算。
        XCTAssertEqual(calendar.startOfDay(for: reference), reference)
        let janFirst = calendar.date(byAdding: .day, value: -1, to: reference)!
        let dayAfterReference = calendar.date(
            byAdding: .day,
            value: 1,
            to: reference
        )!
        let priorYearDay = calendar.date(byAdding: .day, value: -2, to: reference)!

        let store = InMemoryActivityHistory()
        try? store.append([
            makeRecord(date: reference, planned: 600),                          // 窗内
            makeRecord(date: reference.addingTimeInterval(3_600), planned: 900), // 窗内
            makeRecord(date: priorYearDay, planned: 999)                       // 上一年：排除
        ])
        let harness = makeStorageHarness()
        defer { harness.cleanup() }
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeViewModel(model: model)

        vm.select(.thisYear)
        XCTAssertEqual(vm.statistics.window, .thisYear)
        XCTAssertEqual(vm.statistics.range.start, janFirst)
        XCTAssertEqual(vm.statistics.range.end, dayAfterReference)
        // 参考日落在 1 月 2 日：两个日桶（元旦 + 参考日）、一个月桶，
        // 上一年记录不计入。
        XCTAssertEqual(vm.statistics.dayBuckets.count, 2)
        XCTAssertEqual(vm.statistics.completedFocusCount, 2)
        XCTAssertEqual(vm.statistics.completedFocusDuration, 1_500)
        XCTAssertEqual(vm.monthlyBuckets.count, 1)
        XCTAssertEqual(vm.monthlyBuckets.first?.month, janFirst)
        XCTAssertEqual(vm.monthlyBuckets.first?.completedFocusCount, 2)
        // 最近活动仍基于完整历史，不受窗口裁剪。
        XCTAssertEqual(vm.recentRecords.count, 3)

        // 窗口控制器每次 show 调 reload：今年选择必须保留并重新聚合。
        vm.reload()
        XCTAssertEqual(vm.statistics.window, .thisYear)
        XCTAssertEqual(vm.statistics.completedFocusCount, 2)

        // 今年窗口打开期间切换语言照常沿发布链传递。
        model.setLanguage(.chinese)
        XCTAssertEqual(vm.language, .chinese)

        // 一次记录变化只产生一次 statistics 发布（无重复绑定）。
        var emissions = 0
        var cancellables = Set<AnyCancellable>()
        vm.$statistics
            .sink { _ in emissions += 1 }
            .store(in: &cancellables)
        let baseline = emissions
        XCTAssertEqual(baseline, 1)

        driveFocusToCompletion(model)

        XCTAssertEqual(
            emissions,
            baseline + 1,
            "今年窗口下一次追加只能触发一次统计发布"
        )
        // 窗口选择不被记录刷新打断。
        XCTAssertEqual(vm.statistics.window, .thisYear)
    }

    // MARK: 9. 一致上下文快照回归（独立评审确认的缺陷修复）

    /// 一次刷新只采样一次提供方，统计与月桶共用同一上下文，
    /// 且月桶求和必须等于已发布统计的窗口总量。
    func testRefreshCapturesOneCoherentContextAndMonthlySumsMatch() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let providers = MutableProviders(now: utcDate(2032, 1, 15))
        let store = InMemoryActivityHistory()
        try? store.append([
            makeRecord(date: utcDate(2032, 1, 10), planned: 600),
            makeRecord(date: utcDate(2032, 1, 15, hour: 9), planned: 900),
            makeRecord(
                date: utcDate(2032, 1, 15, hour: 10),
                phase: .rest,
                planned: 300
            )
        ])
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeMutableViewModel(model: model, providers: providers)

        let before = (
            providers.nowSamples,
            providers.calendarSamples,
            providers.timeZoneSamples
        )
        vm.select(.thisYear)

        // 一次 select 恰好触发一次刷新，三个提供方各采样一次。
        XCTAssertEqual(providers.nowSamples, before.0 + 1)
        XCTAssertEqual(providers.calendarSamples, before.1 + 1)
        XCTAssertEqual(providers.timeZoneSamples, before.2 + 1)

        XCTAssertEqual(vm.monthlyBuckets.count, 1)
        XCTAssertEqual(
            vm.monthlyBuckets.map(\.completedFocusDuration).reduce(0, +),
            vm.statistics.completedFocusDuration
        )
        XCTAssertEqual(
            vm.monthlyBuckets.map(\.completedFocusCount).reduce(0, +),
            vm.statistics.completedFocusCount
        )
        XCTAssertEqual(
            vm.monthlyBuckets.map(\.completedRestDuration).reduce(0, +),
            vm.statistics.completedRestDuration
        )
        XCTAssertEqual(
            vm.monthlyBuckets.map(\.completedRestCount).reduce(0, +),
            vm.statistics.completedRestCount
        )

        // 再做一次 reload，仍然各只采样一次，证明没有隐藏的二次采样。
        let beforeReload = (
            providers.nowSamples,
            providers.calendarSamples,
            providers.timeZoneSamples
        )
        vm.reload()
        XCTAssertEqual(providers.nowSamples, beforeReload.0 + 1)
        XCTAssertEqual(providers.calendarSamples, beforeReload.1 + 1)
        XCTAssertEqual(providers.timeZoneSamples, beforeReload.2 + 1)
    }

    /// 跨过月界但不触发刷新：视图状态必须保持已发布的快照，
    /// 不能静默长出新的零值月桶，统计区间也保持不变。
    func testMonthRolloverWithoutRefreshKeepsPublishedSnapshot() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let providers = MutableProviders(now: utcDate(2032, 1, 15))
        let store = InMemoryActivityHistory()
        try? store.append([
            makeRecord(date: utcDate(2032, 1, 10), planned: 600)
        ])
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeMutableViewModel(model: model, providers: providers)
        vm.select(.thisYear)

        XCTAssertEqual(vm.monthlyBuckets.count, 1)
        let frozenRange = vm.statistics.range
        let frozenMonth = vm.monthlyBuckets.first?.month
        let samplesAtSnapshot = (
            providers.nowSamples,
            providers.calendarSamples,
            providers.timeZoneSamples
        )

        // 时间提供方跨入 2 月：不 reload、不发布记录。
        providers.now = utcDate(2032, 2, 1)

        // 读取存储属性不触发任何提供方采样，状态仍是 1 月快照。
        XCTAssertEqual(vm.monthlyBuckets.count, 1)
        XCTAssertEqual(vm.monthlyBuckets.first?.month, frozenMonth)
        XCTAssertEqual(vm.statistics.range, frozenRange)
        XCTAssertEqual(providers.nowSamples, samplesAtSnapshot.0)
        XCTAssertEqual(providers.calendarSamples, samplesAtSnapshot.1)
        XCTAssertEqual(providers.timeZoneSamples, samplesAtSnapshot.2)
    }

    /// 跨月后的显式 reload：区间/卡片与月桶原子地一起进入新月。
    func testReloadAfterMonthRolloverAtomicallyAddsNewMonth() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let providers = MutableProviders(now: utcDate(2032, 1, 15))
        let store = InMemoryActivityHistory()
        try? store.append([
            makeRecord(date: utcDate(2032, 1, 10), planned: 600)
        ])
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeMutableViewModel(model: model, providers: providers)
        vm.select(.thisYear)

        providers.now = utcDate(2032, 2, 1)
        vm.reload()

        // 月桶：1 月（有数据）+ 2 月（零值），无未来月份。
        XCTAssertEqual(vm.monthlyBuckets.map(\.month), [
            utcDate(2032, 1, 1, hour: 0),
            utcDate(2032, 2, 1, hour: 0)
        ])
        XCTAssertEqual(vm.monthlyBuckets.first?.completedFocusDuration, 600)
        XCTAssertEqual(vm.monthlyBuckets.last?.completedFocusCount, 0)

        // 区间与卡片同步推进到 2 月 1 日所在窗口。
        XCTAssertEqual(vm.statistics.range.start, utcDate(2032, 1, 1, hour: 0))
        XCTAssertEqual(vm.statistics.range.end, utcDate(2032, 2, 2, hour: 0))
        XCTAssertEqual(vm.statistics.completedFocusCount, 1)
        // 月桶总量仍与统计一致。
        XCTAssertEqual(
            vm.monthlyBuckets.map(\.completedFocusDuration).reduce(0, +),
            vm.statistics.completedFocusDuration
        )
    }

    /// 跨年回归：旧实现会在读取月桶时用新年的月份映射归并旧年日桶，
    /// 触发 helper 的 preconditionFailure。现在读取状态必须安全，
    /// reload 后统计与月桶都只属于新年。
    func testNewYearRolloverDoesNotCrashAndReloadEntersNewYear() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let providers = MutableProviders(now: utcDate(2032, 12, 31))
        let store = InMemoryActivityHistory()
        try? store.append([
            makeRecord(date: utcDate(2032, 12, 31, hour: 10), planned: 600)
        ])
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeMutableViewModel(model: model, providers: providers)
        vm.select(.thisYear)

        XCTAssertEqual(vm.monthlyBuckets.count, 12)
        XCTAssertEqual(vm.statistics.range.start, utcDate(2032, 1, 1, hour: 0))

        // 时间提供方跨入新年：仅读取视图状态，旧实现会在此处崩溃。
        providers.now = utcDate(2033, 1, 1)
        assertViewStateReadIsSafe(vm)
        XCTAssertEqual(vm.monthlyBuckets.count, 12)
        XCTAssertEqual(vm.statistics.range.start, utcDate(2032, 1, 1, hour: 0))

        // 显式 reload 后整体切换到 2033 年窗口。
        vm.reload()
        XCTAssertEqual(vm.statistics.range.start, utcDate(2033, 1, 1, hour: 0))
        XCTAssertEqual(vm.statistics.range.end, utcDate(2033, 1, 2, hour: 0))
        XCTAssertEqual(vm.statistics.dayBuckets.count, 1)
        XCTAssertEqual(vm.monthlyBuckets.count, 1)
        XCTAssertEqual(vm.monthlyBuckets.first?.month, utcDate(2033, 1, 1, hour: 0))
        // 上一年的记录不在新年窗口内。
        XCTAssertEqual(vm.statistics.completedFocusCount, 0)
        XCTAssertEqual(vm.monthlyBuckets.first?.completedFocusCount, 0)
    }

    /// 时区提供方变化遵循同一规则：无聚合触发时状态冻结；
    /// reload 后卡片与图表一起换到新时区内的一致边界。
    func testTimeZoneProviderMutationWaitsForExplicitRefresh() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let utc = TimeZone(identifier: "UTC")!
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let providers = MutableProviders(now: utcDate(2032, 1, 15), timeZone: utc)
        let store = InMemoryActivityHistory()
        // UTC 1 月 15 日 00:30，在 UTC+8 是当天 08:30，仍属 1 月。
        try? store.append([
            makeRecord(date: utcDate(2032, 1, 15, hour: 0, minute: 30), planned: 600)
        ])
        let model = makeModel(storage: harness.storage, store: store)
        let vm = makeMutableViewModel(model: model, providers: providers)
        vm.select(.thisYear)

        let utcYearStart = utcDate(2032, 1, 1, hour: 0)
        XCTAssertEqual(vm.statistics.range.start, utcYearStart)
        XCTAssertEqual(vm.monthlyBuckets.first?.month, utcYearStart)

        // 仅改时区、不刷新：状态保持 UTC 快照。
        providers.timeZone = shanghai
        XCTAssertEqual(vm.statistics.range.start, utcYearStart)
        XCTAssertEqual(vm.monthlyBuckets.first?.month, utcYearStart)

        // reload 后两个上下文一起进入上海时区：
        // 上海 1 月 1 日 00:00 == UTC 2031-12-31 16:00。
        vm.reload()
        let shanghaiYearStart = utcDate(2031, 12, 31, hour: 16)
        XCTAssertEqual(vm.statistics.range.start, shanghaiYearStart)
        XCTAssertEqual(vm.statistics.dayBuckets.first?.day, shanghaiYearStart)
        XCTAssertEqual(vm.monthlyBuckets.first?.month, shanghaiYearStart)
        XCTAssertEqual(vm.monthlyBuckets.count, 1)
        // 记录在上海时区仍落在今年 1 月，卡片与月桶一致计入。
        XCTAssertEqual(vm.statistics.completedFocusCount, 1)
        XCTAssertEqual(vm.monthlyBuckets.first?.completedFocusCount, 1)
    }

    /// 今年窗口下一次记录变化只产生一次 statistics 与一次 monthlyBuckets
    /// 发布，两个发布者之间不存在反馈环或重复聚合。
    func testSinglePublicationForBothStatisticsAndMonthlyBuckets() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let model = makeModel(storage: harness.storage, now: Date())
        let vm = StatisticsViewModel(model: model)
        vm.select(.thisYear)

        var statisticsEmissions = 0
        var monthlyEmissions = 0
        var cancellables = Set<AnyCancellable>()
        vm.$statistics
            .sink { _ in statisticsEmissions += 1 }
            .store(in: &cancellables)
        vm.$monthlyBuckets
            .sink { _ in monthlyEmissions += 1 }
            .store(in: &cancellables)
        XCTAssertEqual(statisticsEmissions, 1)
        XCTAssertEqual(monthlyEmissions, 1)

        driveFocusToCompletion(model)

        XCTAssertEqual(
            statisticsEmissions,
            2,
            "一次记录变化只能触发一次 statistics 发布"
        )
        XCTAssertEqual(
            monthlyEmissions,
            2,
            "一次记录变化只能触发一次 monthlyBuckets 发布"
        )

        // 再等一个运行循环，确认没有延迟的反馈环补发。
        let exp = expectation(description: "no feedback loop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(statisticsEmissions, 2)
        XCTAssertEqual(monthlyEmissions, 2)
        XCTAssertEqual(vm.statistics.window, .thisYear)
    }

    /// 旧缺陷在读取月桶时会触发 helper 的 preconditionFailure（进程陷阱，
    /// 无法用 XCTAssert 捕获）；存储属性读取不采样任何提供方，
    /// 因此这里能正常返回即证明读取安全，若回归为旧实现测试进程会直接崩溃。
    private func assertViewStateReadIsSafe(
        _ vm: StatisticsViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(vm.monthlyBuckets.count, 0, file: file, line: line)
        XCTAssertGreaterThan(vm.statistics.dayBuckets.count, 0, file: file, line: line)
    }
}
