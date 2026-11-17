import XCTest
@testable import StandUpTimerCore

/// Stage 6A 修复 3：解码期记录校验——schema 版本、语义字段、时长、幂等 id。
/// 坏记录必须被类型化错误拒绝，整个文件按损坏处理并保留原始字节，不做就地修复。
final class ActivityRecordValidationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func time(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    /// 取一条合法记录的 JSON 字典表示，供测试按需篡改单个字段。
    private func validRecordDictionary(
        phase: StandUpTimer.Phase = .focus,
        mode: StandUpTimer.Mode = .fourRound,
        round: Int = 2,
        restKind: StandUpTimer.RestKind = .short,
        outcome: ActivityRecord.Outcome = .completed,
        planned: TimeInterval = 600,
        active: TimeInterval = 600
    ) throws -> [String: Any] {
        let record = ActivityRecord(
            date: time(100),
            phase: phase,
            mode: mode,
            focusRound: round,
            restKind: restKind,
            outcome: outcome,
            plannedDuration: planned,
            activeDuration: active
        )
        let data = try ActivityHistoryCodec.encode([record])
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = envelope?["records"] as? [[String: Any]]
        return try XCTUnwrap(records?.first)
    }

    private func envelopeData(record dictionary: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["envelopeVersion": 1, "records": [dictionary]]
        )
    }

    private func decode(record dictionary: [String: Any]) throws -> [ActivityRecord] {
        try ActivityHistoryCodec.decode(try envelopeData(record: dictionary))
    }

    private func assertInvalidRecord(
        _ dictionary: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let data: Data
        do {
            data = try envelopeData(record: dictionary)
        } catch {
            return XCTFail("构造测试信封失败：\(error)", file: file, line: line)
        }

        XCTAssertThrowsError(
            try ActivityHistoryCodec.decode(data),
            file: file,
            line: line
        ) { error in
            guard case ActivityHistoryError.invalidRecord = error else {
                return XCTFail("应当抛 invalidRecord，实际：\(error)", file: file, line: line)
            }
        }

        // inspect 必须把整个文件判为损坏并原样保留字节，供上层隔离备份。
        XCTAssertEqual(
            ActivityHistoryCodec.inspect(presentData: data),
            .corrupt(data),
            file: file,
            line: line
        )
    }

    // MARK: 1. 合法 v1 记录原样往返

    func testValidV1RecordsRoundTripUnchanged() throws {
        let records = [
            ActivityRecord(
                date: time(10), phase: .focus, mode: .single, focusRound: 1,
                restKind: .short, outcome: .completed, plannedDuration: 600, activeDuration: 600
            ),
            ActivityRecord(
                date: time(20), phase: .rest, mode: .fourRound, focusRound: 4,
                restKind: .long, outcome: .completed, plannedDuration: 900, activeDuration: 900
            ),
            ActivityRecord(
                date: time(30), phase: .focus, mode: .fourRound, focusRound: 3,
                restKind: .short, outcome: .skipped, plannedDuration: 600, activeDuration: 120
            ),
            ActivityRecord(
                date: time(40), phase: .rest, mode: .fourRound, focusRound: 2,
                restKind: .short, outcome: .cancelled, plannedDuration: 300, activeDuration: 45
            )
        ]

        let decoded = try ActivityHistoryCodec.decode(try ActivityHistoryCodec.encode(records))
        XCTAssertEqual(decoded, records)
        XCTAssertEqual(decoded.map(\.id), records.map(\.id))
    }

    // MARK: 2. 不支持的记录 schema 版本

    func testUnsupportedRecordSchemaIsRejected() throws {
        var dictionary = try validRecordDictionary()
        dictionary["schemaVersion"] = ActivityRecord.currentSchemaVersion + 1
        assertInvalidRecord(dictionary)
    }

    func testZeroRecordSchemaIsRejected() throws {
        var dictionary = try validRecordDictionary()
        dictionary["schemaVersion"] = 0
        assertInvalidRecord(dictionary)
    }

    // MARK: 3. 篡改 id 被拒绝，且不做就地修复

    func testTamperedIDIsRejected() throws {
        var dictionary = try validRecordDictionary()
        let originalID = try XCTUnwrap(dictionary["id"] as? String)
        dictionary["id"] = originalID + "-tampered"
        assertInvalidRecord(dictionary)
    }

    // MARK: 4. 轮次与模式/休息类型组合

    func testFocusRoundOutsideOneToFourIsRejected() throws {
        for badRound in [0, 5, -1, 99] {
            var dictionary = try validRecordDictionary(round: 2)
            dictionary["focusRound"] = badRound
            assertInvalidRecord(dictionary)
        }
    }

    func testSingleModeRoundOtherThanOneIsRejected() throws {
        var dictionary = try validRecordDictionary(mode: .single, round: 1)
        dictionary["focusRound"] = 2
        // 同时把 mode 的 rawValue 保持 single；id 会因此不匹配，校验先在语义处拒绝。
        assertInvalidRecord(dictionary)
    }

    func testSingleModeLongRestIsRejected() throws {
        var dictionary = try validRecordDictionary(
            phase: .rest,
            mode: .single,
            round: 1,
            restKind: .short
        )
        dictionary["restKind"] = "long"
        assertInvalidRecord(dictionary)
    }

    func testFocusPhaseWithLongRestIsRejected() throws {
        var dictionary = try validRecordDictionary(
            phase: .focus,
            mode: .fourRound,
            round: 4,
            restKind: .short
        )
        dictionary["restKind"] = "long"
        assertInvalidRecord(dictionary)
    }

    func testFourRoundRoundTwoLongRestIsRejectedOnDecode() throws {
        // 第 2 轮休息合法形态是短休；改成 long 必须被拒绝。
        var dictionary = try validRecordDictionary(
            phase: .rest,
            mode: .fourRound,
            round: 2,
            restKind: .short
        )
        dictionary["restKind"] = "long"
        assertInvalidRecord(dictionary)
    }

    func testFourRoundRoundFourShortRestIsRejectedOnDecode() throws {
        // 第 4 轮休息合法形态是长休；改成 short 必须被拒绝。
        var dictionary = try validRecordDictionary(
            phase: .rest,
            mode: .fourRound,
            round: 4,
            restKind: .long
        )
        dictionary["restKind"] = "short"
        assertInvalidRecord(dictionary)
    }

    // MARK: 5. 时长规则

    func testNonPositivePlannedDurationIsRejected() throws {
        for badPlanned in [0.0, -1.0] {
            var dictionary = try validRecordDictionary(planned: 600, active: 600)
            dictionary["plannedDuration"] = badPlanned
            dictionary["activeDuration"] = badPlanned
            assertInvalidRecord(dictionary)
        }
    }

    func testNegativeOrOverPlannedActiveDurationIsRejected() throws {
        var negative = try validRecordDictionary(planned: 600, active: 600)
        negative["activeDuration"] = -1
        assertInvalidRecord(negative)

        var overPlanned = try validRecordDictionary(planned: 600, active: 600)
        overPlanned["activeDuration"] = 601
        assertInvalidRecord(overPlanned)
    }

    func testNonFiniteDurationsAreRejectedByValidator() {
        // NaN/Infinity 无法用合法 JSON 表达，直接对校验器入参做非有限值测试。
        let base = (
            id: "x",
            date: time(100),
            phase: StandUpTimer.Phase.focus,
            mode: StandUpTimer.Mode.fourRound,
            focusRound: 2,
            restKind: StandUpTimer.RestKind.short,
            outcome: ActivityRecord.Outcome.skipped,
            planned: 600.0,
            active: 100.0
        )

        XCTAssertThrowsError(
            try ActivityRecord.validate(
                schemaVersion: 1, id: base.id, date: base.date, phase: base.phase,
                mode: base.mode, focusRound: base.focusRound, restKind: base.restKind,
                outcome: base.outcome, plannedDuration: .infinity, activeDuration: base.active
            )
        ) { error in
            guard case ActivityHistoryError.invalidRecord = error else {
                return XCTFail("非有限计划时长应被拒绝")
            }
        }

        XCTAssertThrowsError(
            try ActivityRecord.validate(
                schemaVersion: 1, id: base.id, date: base.date, phase: base.phase,
                mode: base.mode, focusRound: base.focusRound, restKind: base.restKind,
                outcome: base.outcome, plannedDuration: base.planned, activeDuration: .nan
            )
        ) { error in
            guard case ActivityHistoryError.invalidRecord = error else {
                return XCTFail("NaN 活动时长应被拒绝")
            }
        }
    }

    func testCompletedRecordRequiresActiveEqualsPlanned() throws {
        var dictionary = try validRecordDictionary(outcome: .completed, planned: 600, active: 600)
        dictionary["activeDuration"] = 599
        assertInvalidRecord(dictionary)
    }

    func testCancelledRecordRequiresPositiveActiveDuration() throws {
        var dictionary = try validRecordDictionary(outcome: .cancelled, planned: 600, active: 1)
        dictionary["activeDuration"] = 0
        assertInvalidRecord(dictionary)
    }

    func testSkippedRecordAllowsZeroActiveDuration() throws {
        let dictionary = try validRecordDictionary(
            outcome: .skipped,
            planned: 600,
            active: 0
        )
        XCTAssertNoThrow(try decode(record: dictionary))
    }

    // MARK: 6. 编码侧校验：内存中的非法记录不允许落盘

    private func assertEncodeRejects(
        _ record: ActivityRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ActivityHistoryCodec.encode([record]),
            file: file,
            line: line
        ) { error in
            guard case ActivityHistoryError.invalidRecord = error else {
                return XCTFail("编码应当抛 invalidRecord，实际：\(error)", file: file, line: line)
            }
        }
        // 合法记录的编码不受影响。
        let valid = ActivityRecord(
            date: time(10), phase: .focus, mode: .single, focusRound: 1,
            restKind: .short, outcome: .completed, plannedDuration: 600, activeDuration: 600
        )
        XCTAssertNoThrow(try ActivityHistoryCodec.encode([valid]), file: file, line: line)
        XCTAssertNoThrow(try ActivityHistoryCodec.encode([]), file: file, line: line)
    }

    func testEncodeRejectsUnsupportedSchemaVersion() {
        let record = ActivityRecord(
            date: time(100), phase: .focus, mode: .single, focusRound: 1,
            restKind: .short, outcome: .completed, plannedDuration: 600,
            activeDuration: 600, schemaVersion: ActivityRecord.currentSchemaVersion + 1
        )
        assertEncodeRejects(record)
    }

    func testEncodeRejectsRoundTwoLongRest() {
        let record = ActivityRecord(
            date: time(100), phase: .rest, mode: .fourRound, focusRound: 2,
            restKind: .long, outcome: .completed, plannedDuration: 300, activeDuration: 300
        )
        assertEncodeRejects(record)
    }

    func testEncodeRejectsRoundFourShortRest() {
        let record = ActivityRecord(
            date: time(100), phase: .rest, mode: .fourRound, focusRound: 4,
            restKind: .short, outcome: .completed, plannedDuration: 300, activeDuration: 300
        )
        assertEncodeRejects(record)
    }

    // MARK: 7. 信封未知版本仍然保留原始字节（回归保护）

    func testUnknownEnvelopeVersionStillPreservesOriginalBytes() throws {
        let payload: [String: Any] = [
            "envelopeVersion": ActivityHistoryCodec.envelopeVersion + 99,
            "records": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertEqual(ActivityHistoryCodec.inspect(presentData: data), .corrupt(data))
        XCTAssertThrowsError(try ActivityHistoryCodec.decode(data)) { error in
            guard case ActivityHistoryError.unsupportedVersion = error else {
                return XCTFail("应当抛 unsupportedVersion，实际：\(error)")
            }
        }
    }
}
