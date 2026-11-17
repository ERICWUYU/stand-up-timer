import XCTest
@testable import StandUpTimerApp
import StandUpTimerCore

/// Stage 6B：TimerModel 对活动历史的发布与存储降级行为。
///
/// 全部使用注入的内存存储或临时目录文件存储，绝不触碰真实
/// Application Support；UserDefaults 使用一次性 suite 并在每个用例的
/// defer 中清除（资源均为用例内局部量，不产生 actor 隔离状态）。
@MainActor
final class TimerModelHistoryTests: XCTestCase {
    private enum Boom: Error { case injected }

    /// 可预载种子、随后让 append 失败的存储替身。
    private final class SeedableFailingHistory: ActivityHistoryStoring {
        private var records: [ActivityRecord]
        private let appendError: Error?

        init(seed: [ActivityRecord], appendError: Error? = nil) {
            self.records = seed
            self.appendError = appendError
        }

        func loadRecords() -> [ActivityRecord] {
            records
        }

        func append(_ newRecords: [ActivityRecord]) throws {
            if let appendError { throw appendError }
            records = ActivityHistoryCodec.merge(
                existing: records,
                appending: newRecords
            )
        }
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - 辅助

    private struct StorageHarness {
        let storage: TimerStorage
        let cleanup: () -> Void
    }

    /// 独立 suite + 清理闭包；调用方在用例里 `defer { harness.cleanup() }`。
    private func makeStorageHarness() -> StorageHarness {
        let suite = "standup-model-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return StorageHarness(
            storage: UserDefaultsTimerStorage(defaults: defaults),
            cleanup: {
                defaults.removePersistentDomain(forName: suite)
            }
        )
    }

    private func makeTempDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("standup-model-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

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

    /// 驱动一次完整的普通专注：开始后把参考时间推过 25 分钟截止点，
    /// 由 update(at:) 结算自然完成并写历史。留 60 秒余量吸收两次
    /// Date() 调用之间的墙上时间差。
    @discardableResult
    private func driveFocusToCompletion(_ model: TimerModel) -> ActivityRecord {
        let start = Date()
        model.performPrimaryAction()
        model.update(at: start.addingTimeInterval(25 * 60 + 60))
        let record = model.activityRecords.last
        XCTAssertNotNil(record, "应当结算出一条 completed 专注记录")
        return record!
    }

    // MARK: 1. 注入存储的初始记录被直接发布

    func testInitialHistoryIsPublishedFromInjectedStore() throws {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let store = InMemoryActivityHistory()
        let records = [
            makeRecord(date: t0.addingTimeInterval(10)),
            makeRecord(date: t0.addingTimeInterval(20))
        ]
        try store.append(records)

        let model = TimerModel(
            now: t0,
            storage: harness.storage,
            historyStore: store
        )

        XCTAssertEqual(model.activityRecords, records)
        XCTAssertNil(model.historyNotice)
    }

    // MARK: 2. 成功追加后发布数组刷新

    func testSuccessfulCompletionPublishesUpdatedRecords() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let store = InMemoryActivityHistory()
        let model = TimerModel(
            now: Date(),
            storage: harness.storage,
            historyStore: store
        )
        XCTAssertTrue(model.activityRecords.isEmpty)

        let record = driveFocusToCompletion(model)

        XCTAssertEqual(record.outcome, .completed)
        XCTAssertEqual(record.phase, .focus)
        XCTAssertEqual(model.activityRecords, store.loadRecords())
        XCTAssertEqual(model.activityRecords.count, 1)
        XCTAssertNil(model.historyNotice)
    }

    // MARK: 3. 追加失败：旧数组不变，给出 writeFailed

    func testAppendFailureKeepsOldRecordsAndSetsWriteFailed() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let seeded = makeRecord(date: t0)
        let failingStore = SeedableFailingHistory(
            seed: [seeded],
            appendError: Boom.injected
        )

        let model = TimerModel(
            now: Date(),
            storage: harness.storage,
            historyStore: failingStore
        )
        XCTAssertEqual(model.activityRecords, [seeded])

        // 写入必败：核心仍会结算阶段，但发布数组必须保持旧值。
        let start = Date()
        model.performPrimaryAction()
        model.update(at: start.addingTimeInterval(25 * 60 + 60))
        XCTAssertEqual(model.phase, .rest, "阶段应已结算到休息，证明写入失败没有打断计时")

        XCTAssertEqual(model.activityRecords, [seeded], "写入失败后发布数组必须保持旧值")
        XCTAssertEqual(model.historyNotice, .writeFailed)
    }

    // MARK: 4. 损坏文件经工厂创建：隔离通知上浮，空历史可继续承接

    func testCorruptFileStoreFromFactoryExposesQuarantineAndRecovers() throws {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("activity-history.json")
        try Data("broken".utf8).write(to: fileURL)

        let model = TimerModel(
            now: Date(),
            storage: harness.storage,
            makeHistoryStore: {
                try FileHistoryStore(directoryURL: directory)
            }
        )

        guard case let .corruptFileQuarantined(backup: backupURL)? = model.historyNotice else {
            return XCTFail("应当上浮 corruptFileQuarantined，实际：\(String(describing: model.historyNotice))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertTrue(model.activityRecords.isEmpty)

        let record = driveFocusToCompletion(model)
        XCTAssertEqual(model.activityRecords, [record])
        // 成功写入不能清掉加载期通知：它描述的是本次启动发生过的隔离事件。
        XCTAssertEqual(model.historyNotice, .corruptFileQuarantined(backup: backupURL))
    }

    // MARK: 5. 工厂抛错：内存降级 + storageUnavailable，计时与历史继续可用

    func testThrowingFactoryFallsBackToMemoryWithStorageUnavailable() {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let model = TimerModel(
            now: Date(),
            storage: harness.storage,
            makeHistoryStore: { throw Boom.injected }
        )

        XCTAssertEqual(model.historyNotice, .storageUnavailable)
        XCTAssertTrue(model.activityRecords.isEmpty)

        let record = driveFocusToCompletion(model)
        XCTAssertEqual(model.activityRecords, [record])
    }

    // MARK: 6. 直接注入的文件存储：加载通知与磁盘记录都正确传递

    func testInjectedFileStorePropagatesNoticeAndRecords() throws {
        let harness = makeStorageHarness()
        defer { harness.cleanup() }

        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let seeded = makeRecord(date: t0)
        let fileStore = try FileHistoryStore(directoryURL: directory)
        try fileStore.append([seeded])

        let reopened = try FileHistoryStore(directoryURL: directory)
        let model = TimerModel(
            now: t0,
            storage: harness.storage,
            historyStore: reopened
        )

        XCTAssertNil(model.historyNotice)
        XCTAssertEqual(model.activityRecords, [seeded])
    }
}
