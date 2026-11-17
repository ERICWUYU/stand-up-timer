import XCTest
@testable import StandUpTimerCore

/// Stage 6A：自然到期转换、显式 Skip/Reset/Cancel 记录、幂等键与启动追赶。
/// 所有时间都通过构造的 `Date` 注入，不使用 `sleep`。
final class ActivityHistoryEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private let focus: TimeInterval = 10
    private let rest: TimeInterval = 4
    private let longRest: TimeInterval = 15

    private func time(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func makeTimer() -> StandUpTimer {
        StandUpTimer(
            focusDuration: focus,
            restDuration: rest,
            longRestDuration: longRest
        )
    }

    // MARK: 1. 单模式专注自然完成

    func testSingleModeFocusCompletionProducesCompletedTransitionAndRecord() {
        var timer = makeTimer()
        timer.start(at: t0)

        let transitions = timer.settleTransitions(at: time(10))

        XCTAssertEqual(transitions.count, 1)
        let transition = try? XCTUnwrap(transitions.first)
        XCTAssertEqual(transition?.phase, .focus)
        XCTAssertEqual(transition?.mode, .single)
        XCTAssertEqual(transition?.focusRound, 1)
        // 专注阶段的 restKind 是占位值，对专注记录无业务含义。
        XCTAssertEqual(transition?.restKind, .short)
        XCTAssertEqual(transition?.scheduledCompletion, time(10))
        XCTAssertEqual(transition?.plannedDuration, focus)

        let record = ActivityRecord.completed(from: transitions[0])
        XCTAssertEqual(record.outcome, .completed)
        XCTAssertEqual(record.date, time(10))
        XCTAssertEqual(record.plannedDuration, focus)
        XCTAssertEqual(record.activeDuration, focus)
        XCTAssertEqual(record.schemaVersion, ActivityRecord.currentSchemaVersion)
    }

    func testRefreshBoolWrapperReportsWhetherPhaseEnded() {
        var timer = makeTimer()
        timer.start(at: t0)

        XCTAssertFalse(timer.refresh(at: time(9)))
        XCTAssertTrue(timer.refresh(at: time(10)))
        // 包装器不改变结算语义：新阶段已经在运行。
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .running)
        XCTAssertFalse(timer.refresh(at: time(10)))
    }

    // MARK: 2. 一次延迟刷新跨越多阶段，顺序与字段完整

    func testDelayedRefreshReturnsEveryCrossedPhaseInExactOrder() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        // t=28 时已跨过：F1(10) R1(14) F2(24) R2(28)。
        let transitions = timer.settleTransitions(at: time(28))

        XCTAssertEqual(transitions.map(\.phase), [.focus, .rest, .focus, .rest])
        XCTAssertEqual(transitions.map(\.focusRound), [1, 1, 2, 2])
        XCTAssertEqual(transitions.map(\.restKind), [.short, .short, .short, .short])
        XCTAssertEqual(
            transitions.map(\.scheduledCompletion),
            [time(10), time(14), time(24), time(28)]
        )
        XCTAssertEqual(
            transitions.map(\.plannedDuration),
            [focus, rest, focus, rest]
        )
        XCTAssertTrue(transitions.allSatisfy { $0.mode == .fourRound })

        // 结算后停在 F3 运行中，截止点 38，而不是重新拿到整段时长。
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 3)
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.remaining(at: time(28)), 10, accuracy: 0.000_001)
    }

    // MARK: 3. 长休完成与系列结束

    func testLongRestCompletionCapturedBeforeSeriesReset() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        // 完整系列：4 专注 + 3 短休 + 1 长休，长休截止点 52+15=67。
        let transitions = timer.settleTransitions(at: time(67))

        XCTAssertEqual(transitions.count, 8)
        let last = try? XCTUnwrap(transitions.last)
        XCTAssertEqual(last?.phase, .rest)
        XCTAssertEqual(last?.restKind, .long)
        XCTAssertEqual(last?.focusRound, 4)
        // 关键字段在 finishSeries() 复位之前捕获，模式仍是 fourRound。
        XCTAssertEqual(last?.mode, .fourRound)
        XCTAssertEqual(last?.scheduledCompletion, time(67))
        XCTAssertEqual(last?.plannedDuration, longRest)

        // 结算之后系列才结束。
        XCTAssertEqual(timer.mode, .single)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.phase, .focus)
    }

    // MARK: 4. 暂停点击恰好落在截止点

    func testPauseAtDeadlineSettlesTransitionAndKeepsTimerRunning() {
        var timer = makeTimer()
        timer.start(at: t0)

        let settled = timer.pause(at: time(10))
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.scheduledCompletion, time(10))
        // 新阶段不会被暂停在 0。
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.phase, .rest)

        let nothing = timer.pause(at: time(11))
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertEqual(timer.status, .paused)
        XCTAssertEqual(timer.remaining(at: time(11)), 3, accuracy: 0.000_001)
    }

    // MARK: 5. 重放同一快照幂等

    func testReprocessingSameSnapshotYieldsIdenticalTransitionsAndIDs() {
        var original = makeTimer()
        original.startFourRounds(at: t0)
        let snapshot = original.snapshot(at: time(2))

        var firstRestore = try? XCTUnwrap(StandUpTimer(snapshot: snapshot))
        var secondRestore = try? XCTUnwrap(StandUpTimer(snapshot: snapshot))

        let first = firstRestore?.settleTransitions(at: time(28)) ?? []
        let second = secondRestore?.settleTransitions(at: time(28)) ?? []

        XCTAssertEqual(first, second)
        let firstRecords = first.map(ActivityRecord.completed(from:))
        let secondRecords = second.map(ActivityRecord.completed(from:))
        XCTAssertEqual(firstRecords.map(\.id), secondRecords.map(\.id))

        // 存储层重放同一批记录不应产生重复。
        let mergedOnce = ActivityHistoryCodec.merge(existing: [], appending: firstRecords)
        let mergedTwice = ActivityHistoryCodec.merge(
            existing: mergedOnce,
            appending: secondRecords
        )
        XCTAssertEqual(mergedOnce.count, 4)
        XCTAssertEqual(mergedTwice, mergedOnce)
    }

    func testCanonicalIDIsDeterministicAndDistinguishesOutcomes() {
        let id1 = ActivityRecord.makeID(
            date: time(10),
            phase: .focus,
            mode: .fourRound,
            focusRound: 2,
            restKind: .short,
            outcome: .completed
        )
        let id2 = ActivityRecord.makeID(
            date: time(10),
            phase: .focus,
            mode: .fourRound,
            focusRound: 2,
            restKind: .short,
            outcome: .completed
        )
        XCTAssertEqual(id1, id2)
        XCTAssertTrue(id1.hasPrefix("v\(ActivityRecord.currentSchemaVersion)|"))

        let skippedID = ActivityRecord.makeID(
            date: time(10),
            phase: .focus,
            mode: .fourRound,
            focusRound: 2,
            restKind: .short,
            outcome: .skipped
        )
        XCTAssertNotEqual(id1, skippedID)

        let otherTimeID = ActivityRecord.makeID(
            date: time(11),
            phase: .focus,
            mode: .fourRound,
            focusRound: 2,
            restKind: .short,
            outcome: .completed
        )
        XCTAssertNotEqual(id1, otherTimeID)
    }

    // MARK: 6. Skip 的活动时长（运行中与暂停中）

    func testSkipFromRunningRecordsAccurateActiveDuration() {
        var timer = makeTimer()
        timer.start(at: t0)

        let record = timer.explicitOutcomeRecord(at: time(4), outcome: .skipped)
        XCTAssertEqual(record?.outcome, .skipped)
        XCTAssertEqual(record?.phase, .focus)
        XCTAssertEqual(record?.plannedDuration, focus)
        XCTAssertEqual(try XCTUnwrap(record).activeDuration, 4, accuracy: 0.000_001)
        XCTAssertEqual(record?.date, time(4))
    }

    func testSkipFromPausedExcludesPausedWallClock() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.pause(at: time(4)) // 冻结剩余 6 秒

        // 暂停墙上时间过去很久，活动时长不得增长。
        let record = timer.explicitOutcomeRecord(at: time(100), outcome: .skipped)
        XCTAssertEqual(record?.outcome, .skipped)
        XCTAssertEqual(try XCTUnwrap(record).activeDuration, 4, accuracy: 0.000_001)
    }

    func testResumeThenSkipCountsOnlyActiveIntervals() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.pause(at: time(4))
        timer.resume(at: time(100)) // 新截止点 106
        // 恢复后又活动 3 秒：累计活动 4 + 3 = 7。
        let record = timer.explicitOutcomeRecord(at: time(103), outcome: .skipped)
        XCTAssertEqual(try XCTUnwrap(record).activeDuration, 7, accuracy: 0.000_001)
        XCTAssertEqual(timer.remaining(at: time(103)), 3, accuracy: 0.000_001)
    }

    // MARK: 7. 空闲 Skip 只是导航，不产生记录

    func testSkipFromIdleProducesNoRecord() {
        let idle = makeTimer()
        XCTAssertNil(idle.explicitOutcomeRecord(at: t0, outcome: .skipped))

        // 普通模式休息自然结束后回到空闲专注，同样不记录。
        var settled = makeTimer()
        settled.start(at: t0)
        settled.settleTransitions(at: time(14)) // 专注 + 休息都结束
        XCTAssertEqual(settled.status, .idle)
        XCTAssertNil(settled.explicitOutcomeRecord(at: time(14), outcome: .skipped))
    }

    // MARK: 8. Reset/Cancel 只覆盖已开始且有非零活动时间的阶段

    func testResetFromIdleRecordsNothing() {
        let timer = makeTimer()
        XCTAssertNil(timer.explicitOutcomeRecord(at: t0, outcome: .cancelled))
    }

    func testCancelAtZeroActiveTimeRecordsNothing() {
        var timer = makeTimer()
        timer.start(at: t0)
        // 刚启动、活动时间为 0：取消不产生记录。
        XCTAssertNil(timer.explicitOutcomeRecord(at: t0, outcome: .cancelled))
    }

    func testCancelFromRunningRecordsActiveDuration() {
        var timer = makeTimer()
        timer.start(at: t0)
        let record = timer.explicitOutcomeRecord(at: time(3), outcome: .cancelled)
        XCTAssertEqual(record?.outcome, .cancelled)
        XCTAssertEqual(try XCTUnwrap(record).activeDuration, 3, accuracy: 0.000_001)
    }

    func testCancelFromPausedExcludesPausedWallClock() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.pause(at: time(4))
        let record = timer.explicitOutcomeRecord(at: time(999), outcome: .cancelled)
        XCTAssertEqual(record?.outcome, .cancelled)
        XCTAssertEqual(try XCTUnwrap(record).activeDuration, 4, accuracy: 0.000_001)
    }

    func testSkippedOutcomeIsAllowedWithAnyNonnegativeActiveTime() {
        var timer = makeTimer()
        timer.start(at: t0)
        // 与 cancelled 不同，skipped 在活动时间为 0 时仍可记录（用户主动跳过）。
        let record = timer.explicitOutcomeRecord(at: t0, outcome: .skipped)
        XCTAssertEqual(record?.outcome, .skipped)
        XCTAssertEqual(try XCTUnwrap(record).activeDuration, 0, accuracy: 0.000_001)
    }

    // MARK: 9. 启动离线追赶：使用计划截止点，而非重启时间

    func testStartupCatchUpReturnsTransitionsAtScheduledDeadlines() {
        // 设置只接受整分钟，这里全部用 60 秒，避免恢复时设置改写后续节奏。
        var timer = StandUpTimer(
            focusDuration: 60,
            restDuration: 60,
            longRestDuration: 60
        )
        timer.startFourRounds(at: t0)
        let snapshot = timer.snapshot(at: time(5))

        let result = TimerStartup.timer(
            settings: TimerSettings(focusMinutes: 1, restMinutes: 1),
            restored: snapshot,
            overrideDuration: nil,
            now: time(150)
        )

        XCTAssertTrue(result.persistsState)
        XCTAssertFalse(result.usesOverride)
        // 150 秒时跨过 F1(60) 与 R1(120)，F2 截止点 180 尚未到。
        XCTAssertEqual(result.settledTransitions.count, 2)
        XCTAssertEqual(result.settledTransitions.map(\.phase), [.focus, .rest])
        XCTAssertEqual(
            result.settledTransitions.map(\.scheduledCompletion),
            [time(60), time(120)]
        )
        XCTAssertEqual(result.timer.status, .running)
        XCTAssertEqual(result.timer.focusRound, 2)

        let records = result.settledTransitions.map(ActivityRecord.completed(from:))
        // 所有记录日期都早于重启时刻，证明用的是截止点。
        XCTAssertTrue(records.allSatisfy { $0.date < time(150) })
    }

    func testStartupOverrideAndFreshLaunchCarryNoTransitions() {
        let override = TimerStartup.timer(
            settings: .standard,
            restored: nil,
            overrideDuration: 10,
            now: t0
        )
        XCTAssertTrue(override.usesOverride)
        XCTAssertFalse(override.persistsState)
        XCTAssertTrue(override.settledTransitions.isEmpty)

        let fresh = TimerStartup.timer(
            settings: .standard,
            restored: nil,
            overrideDuration: nil,
            now: t0
        )
        XCTAssertTrue(fresh.settledTransitions.isEmpty)
        XCTAssertTrue(fresh.persistsState)
    }
}
