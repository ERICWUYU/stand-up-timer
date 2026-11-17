import XCTest
@testable import StandUpTimerCore

/// Stage 6A：版本化信封、损坏保留判定、幂等合并与内存存储替身。
final class ActivityHistoryStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

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

    // MARK: 1. 信封往返与版本号

    func testEnvelopeRoundTripPreservesRecordsAndVersion() throws {
        let records = [
            makeRecord(date: time(10), phase: .focus, active: 600),
            makeRecord(
                date: time(20),
                phase: .rest,
                restKind: .short,
                outcome: .completed,
                planned: 300,
                active: 300
            )
        ]

        let data = try ActivityHistoryCodec.encode(records)
        let decoded = try ActivityHistoryCodec.decode(data)
        XCTAssertEqual(decoded, records)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["envelopeVersion"] as? Int, ActivityHistoryCodec.envelopeVersion)
        XCTAssertEqual((object?["records"] as? [Any])?.count, 2)
    }

    func testRecordSchemaVersionIsEncoded() throws {
        let data = try ActivityHistoryCodec.encode([makeRecord(date: time(10))])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (object?["records"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["schemaVersion"] as? Int, ActivityRecord.currentSchemaVersion)
        XCTAssertNotNil(first?["id"] as? String)
    }

    // MARK: 2. 损坏与未知版本：原始字节必须保留

    func testInspectMissingFileMeansNoFile() {
        XCTAssertEqual(ActivityHistoryCodec.inspect(presentData: nil), .noFile)
    }

    func testInspectGarbageReturnsCorruptWithOriginalBytes() {
        let bytes = Data("not a valid history".utf8)
        XCTAssertEqual(ActivityHistoryCodec.inspect(presentData: bytes), .corrupt(bytes))

        XCTAssertThrowsError(try ActivityHistoryCodec.decode(bytes)) { error in
            guard case ActivityHistoryError.corruptEnvelope(let carried) = error else {
                return XCTFail("应当抛 corruptEnvelope，实际：\(error)")
            }
            XCTAssertEqual(carried, bytes)
        }
    }

    func testInspectEmptyDataReturnsCorruptWithOriginalBytes() {
        XCTAssertEqual(
            ActivityHistoryCodec.inspect(presentData: Data()),
            .corrupt(Data())
        )
    }

    func testInspectUnsupportedEnvelopeVersionPreservesOriginalBytes() throws {
        let payload: [String: Any] = [
            "envelopeVersion": ActivityHistoryCodec.envelopeVersion + 99,
            "records": []
        ]
        let bytes = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertEqual(ActivityHistoryCodec.inspect(presentData: bytes), .corrupt(bytes))
        XCTAssertThrowsError(try ActivityHistoryCodec.decode(bytes)) { error in
            guard case ActivityHistoryError.unsupportedVersion(let version) = error else {
                return XCTFail("应当抛 unsupportedVersion，实际：\(error)")
            }
            XCTAssertEqual(version, ActivityHistoryCodec.envelopeVersion + 99)
        }
    }

    // MARK: 3. 合并：去重、时间顺序、稳定次序

    func testMergeDedupesByStableID() {
        let record = makeRecord(date: time(10))
        let merged = ActivityHistoryCodec.merge(
            existing: [record],
            appending: [record]
        )
        XCTAssertEqual(merged, [record])
    }

    func testMergeSortsChronologicallyAndKeepsStableOrderForSameInstant() {
        let earlier = makeRecord(date: time(10), outcome: .completed)
        let later = makeRecord(date: time(30), outcome: .completed)
        // 同一时刻、不同 id（休息记录），相对次序应保持入参顺序。
        let sameInstantFocus = makeRecord(date: time(20), phase: .focus)
        let sameInstantRest = makeRecord(date: time(20), phase: .rest)

        let merged = ActivityHistoryCodec.merge(
            existing: [later, sameInstantFocus],
            appending: [earlier, sameInstantRest]
        )

        XCTAssertEqual(merged.map(\.date), [time(10), time(20), time(20), time(30)])
        XCTAssertEqual(merged[1].phase, .focus)
        XCTAssertEqual(merged[2].phase, .rest)
    }

    func testMergeKeepsFirstRecordWhenIDsCollide() {
        let original = makeRecord(date: time(10), planned: 600, active: 600)
        // 同 id 意味着稳定字段完全相同，构造一个同 id 的“重放”记录。
        let replay = ActivityRecord(
            date: original.date,
            phase: original.phase,
            mode: original.mode,
            focusRound: original.focusRound,
            restKind: original.restKind,
            outcome: original.outcome,
            plannedDuration: original.plannedDuration,
            activeDuration: original.activeDuration
        )
        XCTAssertEqual(replay.id, original.id)
        let merged = ActivityHistoryCodec.merge(existing: [original], appending: [replay])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first, original)
    }

    // MARK: 4. 内存存储替身

    func testInMemoryStoreAppendsMergesAndDedupes() throws {
        let store = InMemoryActivityHistory()
        let first = makeRecord(date: time(30))
        let second = makeRecord(date: time(10))

        try store.append([first])
        try store.append([second, first]) // first 重放去重，second 插入正确位置

        XCTAssertEqual(store.loadRecords().map(\.date), [time(10), time(30)])
        XCTAssertEqual(store.appendCalls.count, 2)
    }

    func testInMemoryStoreInjectableAppendFailureIsNonDestructive() {
        struct Boom: Error {}
        let store = InMemoryActivityHistory(appendError: Boom())
        let record = makeRecord(date: time(10))

        XCTAssertThrowsError(try store.append([record]))
        // 失败不破坏既有状态。
        XCTAssertTrue(store.loadRecords().isEmpty)
        XCTAssertEqual(store.appendCalls.count, 1)
    }
}
