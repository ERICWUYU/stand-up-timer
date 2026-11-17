import XCTest
@testable import StandUpTimerApp
import StandUpTimerCore

/// Stage 6A 修复回归：真实文件系统上的 FileHistoryStore 行为。
///
/// 所有用例只在 `setUp` 创建的临时目录内读写，构造时显式注入目录 URL，
/// 绝不触碰用户真实的 Application Support。
final class FileHistoryStoreTests: XCTestCase {
    private enum Boom: Error { case injected }

    private var directory: URL!
    private var fileURL: URL!
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("standup-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("activity-history.json")
    }

    override func tearDownWithError() throws {
        // 只读目录用例先恢复权限，保证临时目录能被完整清理。
        if let directory {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - 辅助

    private func time(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
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

    private func backupURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("activity-history.corrupt-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func temporaryURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(".activity-history.") }
    }

    private func writeRaw(_ data: Data) throws {
        try data.write(to: fileURL)
    }

    private func makeEnvelopeData(record dictionaries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["envelopeVersion": 1, "records": dictionaries]
        )
    }

    /// 取合法记录的 JSON 字典，便于篡改后落盘。
    private func validRecordDictionary(
        phase: StandUpTimer.Phase = .focus,
        mode: StandUpTimer.Mode = .fourRound,
        round: Int = 2,
        restKind: StandUpTimer.RestKind = .short,
        outcome: ActivityRecord.Outcome = .completed,
        planned: TimeInterval = 600,
        active: TimeInterval = 600
    ) throws -> [String: Any] {
        let data = try ActivityHistoryCodec.encode([
            makeRecord(
                date: time(100),
                phase: phase,
                mode: mode,
                round: round,
                restKind: restKind,
                outcome: outcome,
                planned: planned,
                active: active
            )
        ])
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = envelope?["records"] as? [[String: Any]]
        return try XCTUnwrap(records?.first)
    }

    // MARK: 1. 真实追加、重开、时间顺序与去重

    func testAppendReloadOrderingAndDeduplication() throws {
        let store = try FileHistoryStore(directoryURL: directory)
        let later = makeRecord(date: time(30))
        let earlier = makeRecord(date: time(10))

        try store.append([later, earlier])
        try store.append([later]) // 同 id 重放，必须去重

        XCTAssertEqual(store.loadRecords().map(\.date), [time(10), time(30)])

        let reopened = try FileHistoryStore(directoryURL: directory)
        let loaded = reopened.loadRecords()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.date), [time(10), time(30)])

        // 落盘文件本身是可解码的合法信封，且没有遗留临时文件。
        let onDisk = try ActivityHistoryCodec.decode(Data(contentsOf: fileURL))
        XCTAssertEqual(onDisk, loaded)
        XCTAssertTrue(try temporaryURLs().isEmpty)
        XCTAssertTrue(try backupURLs().isEmpty)
    }

    // MARK: 2. 损坏输入只产生一个字节一致的备份

    func testCorruptInputCreatesExactlyOneByteIdenticalBackup() throws {
        let garbage = Data("not a valid history file".utf8)
        try writeRaw(garbage)

        let store = try FileHistoryStore(directoryURL: directory)

        let backups = try backupURLs()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), garbage)
        XCTAssertEqual(store.loadRecords(), [])
        if case .corruptFileQuarantined = store.loadNotice {
            // 预期通知
        } else {
            XCTFail("应当暴露 corruptFileQuarantined 通知，实际：\(String(describing: store.loadNotice))")
        }
    }

    // MARK: 3. 隔离后主文件是合法空信封

    func testMainFileIsValidEmptyEnvelopeAfterRecovery() throws {
        let garbage = Data("broken".utf8)
        try writeRaw(garbage)

        _ = try FileHistoryStore(directoryURL: directory)

        let decoded = try ActivityHistoryCodec.decode(Data(contentsOf: fileURL))
        XCTAssertEqual(decoded, [])

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(object?["envelopeVersion"] as? Int, ActivityHistoryCodec.envelopeVersion)
        XCTAssertEqual((object?["records"] as? [Any])?.count, 0)
    }

    // MARK: 4. 恢复后重开不再产生新备份

    func testReopeningAfterRecoveryCreatesNoAdditionalBackup() throws {
        try writeRaw(Data("broken".utf8))

        let first = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(try backupURLs().count, 1)
        XCTAssertNil(first.loadRecords().first)

        let second = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(try backupURLs().count, 1)
        XCTAssertNil(second.loadNotice)
        XCTAssertEqual(second.loadRecords(), [])

        // 恢复后的空历史可以正常承接新记录。
        let record = makeRecord(date: time(10))
        try second.append([record])
        let third = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(third.loadRecords(), [record])
        XCTAssertEqual(try backupURLs().count, 1)
    }

    // MARK: 5a. 备份失败时原始文件保持可恢复，且不报告恢复成功

    func testBackupFailureLeavesOriginalSourceRecoverable() throws {
        let garbage = Data("broken".utf8)
        try writeRaw(garbage)

        // 目录只读：隔离备份无法写入，初始化必须失败。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )

        XCTAssertThrowsError(try FileHistoryStore(directoryURL: directory)) { error in
            XCTAssertNotNil(error)
        }

        // 恢复权限后原始损坏字节仍在原处，且没有任何备份被创建。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)
        XCTAssertEqual(try backupURLs().count, 0)

        // 原始来源仍可被下一次正常初始化恢复。
        let store = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(store.loadRecords(), [])
        XCTAssertEqual(try backupURLs().count, 1)
    }

    // MARK: 5b. 空信封替换失败时原始文件保持可恢复

    func testReplacementFailureLeavesOriginalSourceRecoverable() throws {
        let garbage = Data("broken".utf8)
        try writeRaw(garbage)

        // 备份走真实 FileManager（应成功），仅让原子替换失败。
        XCTAssertThrowsError(
            try FileHistoryStore(directoryURL: directory) { _, _ in throw Boom.injected }
        )

        // 主文件仍是原始损坏字节，没有被空信封或半截数据替换。
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)
        let backups = try backupURLs()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), garbage)

        // 下一次使用默认写入器的初始化能够正常恢复。注意：上一次初始化在替换
        // 步骤失败、原始损坏文件按设计保留，因此本次会再隔离一次（共 2 个
        // 字节一致的备份）；“不再重复备份”的保证只适用于成功恢复之后的重开。
        let store = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(store.loadRecords(), [])
        let backupsAfterRecovery = try backupURLs()
        XCTAssertEqual(backupsAfterRecovery.count, 2)
        XCTAssertTrue(
            backupsAfterRecovery.allSatisfy { (try? Data(contentsOf: $0)) == garbage }
        )
        XCTAssertNoThrow(try ActivityHistoryCodec.decode(Data(contentsOf: fileURL)))
    }

    // MARK: 6. 追加抛错后锁被释放，存储仍可继续使用

    func testThrowingAppendReleasesLockAndStoreRemainsUsable() throws {
        let failingStore = try FileHistoryStore(directoryURL: directory) { _, _ in
            throw Boom.injected
        }
        let record = makeRecord(date: time(10))

        XCTAssertThrowsError(try failingStore.append([record])) { error in
            guard case Boom.injected = error else { return XCTFail("错误类型不符：\(error)") }
        }

        // 若锁泄漏，这里会死锁而不是返回；缓存也必须保持失败前状态。
        XCTAssertEqual(failingStore.loadRecords(), [])

        // 同一目录上的正常存储可以立即读写，证明锁没有被带走。
        let healthy = try FileHistoryStore(directoryURL: directory)
        try healthy.append([record])
        let reopened = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(reopened.loadRecords(), [record])
        XCTAssertTrue(try temporaryURLs().isEmpty)
    }

    // MARK: 6b. 编码校验失败：写入器不被调用，同一实例仍可继续工作

    func testInvalidAppendFailsBeforeAtomicWriteAndSameStoreRemainsUsable() throws {
        var writerCalls = 0
        let countingWriter: FileHistoryStore.AtomicWrite = { data, target in
            writerCalls += 1
            try FileHistoryStore.defaultAtomicWrite(
                data,
                to: target,
                in: self.directory,
                fileManager: .default
            )
        }
        let store = try FileHistoryStore(directoryURL: directory, atomicWrite: countingWriter)
        let firstValid = makeRecord(date: time(10))

        try store.append([firstValid])
        XCTAssertEqual(writerCalls, 1)
        let diskBytesAfterValidAppend = try Data(contentsOf: fileURL)

        // 内存中构造一条编码侧才拦得住的非法记录（第 2 轮长休）。
        let invalid = ActivityRecord(
            date: time(20),
            phase: .rest,
            mode: .fourRound,
            focusRound: 2,
            restKind: .long,
            outcome: .completed,
            plannedDuration: 300,
            activeDuration: 300
        )

        XCTAssertThrowsError(try store.append([invalid])) { error in
            guard case ActivityHistoryError.invalidRecord = error else {
                return XCTFail("应当抛 invalidRecord，实际：\(error)")
            }
        }

        // 校验发生在 atomicWrite 之前：写入器调用次数不增加。
        XCTAssertEqual(writerCalls, 1)
        // 缓存与磁盘字节都保持失败前状态。
        XCTAssertEqual(store.loadRecords(), [firstValid])
        XCTAssertEqual(try Data(contentsOf: fileURL), diskBytesAfterValidAppend)

        // 同一个实例随后仍可正常读取并成功追加合法记录。
        let secondValid = makeRecord(date: time(30))
        try store.append([secondValid])
        XCTAssertEqual(writerCalls, 2)
        XCTAssertEqual(store.loadRecords().map(\.date), [time(10), time(30)])

        let reopened = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(reopened.loadRecords(), [firstValid, secondValid])
        XCTAssertTrue(try temporaryURLs().isEmpty)
        XCTAssertTrue(try backupURLs().isEmpty)
    }

    // MARK: 7. 不支持的记录 schema 落盘后被隔离

    func testUnsupportedRecordSchemaFileIsQuarantined() throws {
        var dictionary = try validRecordDictionary()
        dictionary["schemaVersion"] = ActivityRecord.currentSchemaVersion + 1
        let data = try makeEnvelopeData(record: [dictionary])
        try writeRaw(data)

        let store = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(try backupURLs().count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backupURLs().first)), data)
        XCTAssertEqual(store.loadRecords(), [])
        XCTAssertNoThrow(try ActivityHistoryCodec.decode(Data(contentsOf: fileURL)))
    }

    // MARK: 8. 篡改 id 的记录落盘后被隔离

    func testTamperedIDFileIsQuarantined() throws {
        var dictionary = try validRecordDictionary()
        let originalID = try XCTUnwrap(dictionary["id"] as? String)
        dictionary["id"] = originalID + "-tampered"
        let data = try makeEnvelopeData(record: [dictionary])
        try writeRaw(data)

        let store = try FileHistoryStore(directoryURL: directory)
        XCTAssertEqual(try backupURLs().count, 1)
        XCTAssertEqual(store.loadRecords(), [])
        XCTAssertEqual(try ActivityHistoryCodec.decode(Data(contentsOf: fileURL)), [])
    }

    // MARK: 9. 非法语义/时长组合落盘后被隔离

    func testInvalidSemanticCombinationsAreQuarantined() throws {
        let mutations: [(String, ([String: Any]) -> [String: Any])] = [
            ("negative active", { $0.merging(["activeDuration": -1]) { $1 } }),
            ("over-planned active", { $0.merging(["activeDuration": 601]) { $1 } }),
            ("zero planned", { dict in
                dict.merging(["plannedDuration": 0, "activeDuration": 0]) { $1 }
            }),
            ("round out of range", { $0.merging(["focusRound": 5]) { $1 } }),
            ("single mode round 2", { dict in
                dict.merging(["mode": "single", "focusRound": 2]) { $1 }
            }),
            ("single mode long rest", { dict in
                dict.merging([
                    "phase": "rest", "mode": "single",
                    "focusRound": 1, "restKind": "long"
                ]) { $1 }
            }),
            ("focus phase long rest", { dict in
                dict.merging(["phase": "focus", "restKind": "long"]) { $1 }
            }),
            ("four round round 2 long rest", { dict in
                dict.merging(["phase": "rest", "restKind": "long"]) { $1 }
            }),
            ("four round round 4 short rest", { dict in
                dict.merging([
                    "phase": "rest",
                    "focusRound": 4,
                    "restKind": "short"
                ]) { $1 }
            })
        ]

        for (name, mutate) in mutations {
            // 每个变体使用独立子目录，互不污染备份计数。
            let subdirectory = directory.appendingPathComponent(
                "case-\(name.replacingOccurrences(of: " ", with: "-"))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let subFile = subdirectory.appendingPathComponent("activity-history.json")

            let dictionary = try mutate(validRecordDictionary())
            let data = try makeEnvelopeData(record: [dictionary])
            try data.write(to: subFile)

            let store = try FileHistoryStore(directoryURL: subdirectory)
            let backups = try FileManager.default.contentsOfDirectory(
                at: subdirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("activity-history.corrupt-") }

            XCTAssertEqual(backups.count, 1, "用例 \(name) 应隔离一次")
            XCTAssertEqual(try Data(contentsOf: backups[0]), data, "用例 \(name) 备份须字节一致")
            XCTAssertEqual(store.loadRecords(), [], "用例 \(name) 不应加载坏记录")
            XCTAssertNoThrow(
                try ActivityHistoryCodec.decode(Data(contentsOf: subFile)),
                "用例 \(name) 主文件应被替换为合法空信封"
            )
        }
    }

    // MARK: 10. 合法 v1 记录经文件往返保持不变

    func testValidV1RecordsRoundTripThroughFile() throws {
        let records = [
            makeRecord(date: time(40), phase: .rest, mode: .fourRound, round: 4,
                       restKind: .long, outcome: .completed, planned: 900),
            makeRecord(date: time(30), phase: .focus, mode: .fourRound, round: 3,
                       outcome: .skipped, planned: 600, active: 120),
            makeRecord(date: time(20), phase: .focus, mode: .single,
                       outcome: .cancelled, planned: 600, active: 45),
            makeRecord(date: time(10), phase: .focus, mode: .single,
                       outcome: .completed, planned: 600)
        ]

        let store = try FileHistoryStore(directoryURL: directory)
        try store.append(records)

        let reopened = try FileHistoryStore(directoryURL: directory)
        let loaded = reopened.loadRecords()
        XCTAssertEqual(loaded, ActivityHistoryCodec.merge(existing: [], appending: records))
        XCTAssertEqual(loaded.map(\.date), [time(10), time(20), time(30), time(40)])
        XCTAssertEqual(Set(loaded.map(\.id)).count, records.count)
        XCTAssertTrue(loaded.allSatisfy { $0.schemaVersion == ActivityRecord.currentSchemaVersion })
        XCTAssertTrue(try backupURLs().isEmpty)
    }
}
