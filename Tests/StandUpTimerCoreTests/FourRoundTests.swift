import XCTest
import StandUpTimerCore

/// 阶段 4B：四轮连续模式的状态转换、持久化与未来通知时间线。
/// 所有时间都通过构造的 `Date` 注入，不使用 `sleep`。
final class FourRoundTests: XCTestCase {
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

    /// 反复刷新，一次跨过多个阶段时也能结算到位。
    private func settle(_ timer: inout StandUpTimer, at seconds: TimeInterval) {
        timer.refresh(at: time(seconds))
    }

    private func assertRemaining(
        _ timer: StandUpTimer,
        at seconds: TimeInterval,
        equals expected: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            timer.remaining(at: time(seconds)),
            expected,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
    }

    // MARK: 1. 一键开始

    func testStartFourRoundsBeginsFirstFocusImmediately() {
        var timer = makeTimer()
        XCTAssertEqual(timer.mode, .single)

        timer.startFourRounds(at: t0)

        XCTAssertEqual(timer.mode, .fourRound)
        XCTAssertTrue(timer.isSeriesActive)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.focusRound, 1)
        XCTAssertEqual(timer.restKind, .short)
        assertRemaining(timer, at: 0, equals: focus)
    }

    // MARK: 2. 前三次专注与短休自动推进

    func testFirstThreeFocusAndShortRestsAdvanceAutomatically() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        settle(&timer, at: 10)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.focusRound, 1)
        assertRemaining(timer, at: 10, equals: rest)

        settle(&timer, at: 14)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 2)
        XCTAssertEqual(timer.status, .running)
        assertRemaining(timer, at: 14, equals: focus)

        settle(&timer, at: 24)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        XCTAssertEqual(timer.focusRound, 2)

        settle(&timer, at: 28)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 3)

        settle(&timer, at: 38)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        XCTAssertEqual(timer.focusRound, 3)

        settle(&timer, at: 42)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 4)
        assertRemaining(timer, at: 42, equals: focus)
    }

    // MARK: 3. 第四次专注进入长休

    func testFourthFocusEntersLongRest() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        settle(&timer, at: 52)

        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .long)
        XCTAssertTrue(timer.isLongRest)
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.focusRound, 4)
        assertRemaining(timer, at: 52, equals: longRest)
    }

    // MARK: 4. 长休结束

    func testLongRestEndReturnsToNormalIdleFocus() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        settle(&timer, at: 67)

        XCTAssertEqual(timer.mode, .single)
        XCTAssertFalse(timer.isSeriesActive)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.focusRound, 1)
        XCTAssertEqual(timer.restKind, .short)
        assertRemaining(timer, at: 67, equals: focus)
    }

    // MARK: 5. Pause/Resume 不改变轮次

    func testPauseAndResumeKeepRound() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        settle(&timer, at: 10) // 短休
        settle(&timer, at: 14) // 第 2 轮专注

        timer.pause(at: time(16))
        XCTAssertEqual(timer.status, .paused)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 16, equals: focus - 2)

        timer.resume(at: time(500))
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 500, equals: focus - 2)

        // 休息中暂停同样保留轮次。
        settle(&timer, at: 508)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.focusRound, 2)
        timer.pause(at: time(509))
        XCTAssertEqual(timer.status, .paused)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 509, equals: rest - 1)
        timer.resume(at: time(600))
        XCTAssertEqual(timer.focusRound, 2)
    }

    // MARK: 6. Reset 保留轮次并恢复完整时长

    func testResetKeepsRoundAndRestoresFullDuration() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        settle(&timer, at: 28) // 第 3 轮专注
        XCTAssertEqual(timer.focusRound, 3)

        timer.reset()

        XCTAssertEqual(timer.mode, .fourRound)
        XCTAssertEqual(timer.focusRound, 3)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 28, equals: focus)

        timer.start(at: time(30))
        XCTAssertEqual(timer.focusRound, 3)
        assertRemaining(timer, at: 30, equals: focus)

        // 休息阶段重置同样保留轮次和休息类型。
        settle(&timer, at: 40) // 第 3 轮专注结束 → 短休
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        timer.reset()
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.focusRound, 3)
        assertRemaining(timer, at: 40, equals: rest)
    }

    // MARK: 7. 各阶段的 Skip

    func testSkipBehaviorsAcrossPhases() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        // 专注 → 短休
        timer.skip(at: time(2))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.focusRound, 1)
        assertRemaining(timer, at: 2, equals: rest)

        // 短休 → 下一轮专注，自动开始
        timer.skip(at: time(3))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 3, equals: focus)

        // 一路跳到第 4 轮专注
        timer.skip(at: time(4)) // 短休
        timer.skip(at: time(5)) // 第 3 轮专注
        timer.skip(at: time(6)) // 短休
        timer.skip(at: time(7)) // 第 4 轮专注
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 4)

        // 第 4 轮专注 → 长休
        timer.skip(at: time(8))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .long)
        XCTAssertEqual(timer.focusRound, 4)
        assertRemaining(timer, at: 8, equals: longRest)

        // 长休 → 结束系列
        timer.skip(at: time(9))
        XCTAssertEqual(timer.mode, .single)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.focusRound, 1)
        assertRemaining(timer, at: 9, equals: focus)
    }

    func testSingleModeSkipIsUnchanged() {
        var timer = makeTimer()
        timer.start(at: t0)

        timer.skip(at: time(1))
        XCTAssertEqual(timer.mode, .single)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        XCTAssertEqual(timer.status, .running)

        timer.skip(at: time(2))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 2, equals: focus)
    }

    // MARK: 8. 取消系列

    func testCancelFourRoundsReturnsToNormalIdleFocus() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        settle(&timer, at: 24) // 第 2 轮短休
        XCTAssertEqual(timer.focusRound, 2)

        timer.cancelFourRounds()

        XCTAssertEqual(timer.mode, .single)
        XCTAssertFalse(timer.isSeriesActive)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.focusRound, 1)
        assertRemaining(timer, at: 24, equals: focus)

        // 普通模式下调用不产生变化。
        timer.cancelFourRounds()
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 24, equals: focus)
    }

    // MARK: 9. 一次跨过多个阶段

    func testLargeJumpAcrossSeveralPhasesKeepsCorrectRound() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        // 27 秒：第 2 轮专注已结束，正处在第 2 段短休（14...28）。
        settle(&timer, at: 27)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 27, equals: 1)

        // 50 秒：正处在第 4 轮专注（42...52）。
        settle(&timer, at: 50)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 4)
        assertRemaining(timer, at: 50, equals: 2)

        // 60 秒：长休中（52...67）。
        settle(&timer, at: 60)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .long)
        XCTAssertEqual(timer.focusRound, 4)
        assertRemaining(timer, at: 60, equals: longRest - 8)

        // 75 秒：系列已结束。
        settle(&timer, at: 75)
        XCTAssertEqual(timer.mode, .single)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.focusRound, 1)
    }

    // MARK: 10. 运行、暂停与长休的保存/恢复

    func testRunningFourRoundRestores() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        settle(&timer, at: 10) // 第 1 段短休

        let snapshot = timer.snapshot(at: time(11))
        XCTAssertEqual(snapshot.mode, .fourRound)
        XCTAssertEqual(snapshot.focusRound, 1)
        XCTAssertEqual(snapshot.restKind, .short)
        XCTAssertEqual(snapshot.longRestDuration, longRest)

        guard let restored = StandUpTimer(snapshot: snapshot) else {
            return XCTFail("四轮运行状态应当能恢复")
        }
        XCTAssertEqual(restored.status, .running)
        XCTAssertEqual(restored.mode, .fourRound)
        XCTAssertEqual(restored.phase, .rest)
        XCTAssertEqual(restored.focusRound, 1)
        assertRemaining(restored, at: 11, equals: rest - 1)
    }

    func testPausedFourRoundRestoresFrozenRemaining() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        timer.pause(at: time(2))

        let snapshot = timer.snapshot(at: time(2))
        guard let restored = StandUpTimer(snapshot: snapshot) else {
            return XCTFail("暂停状态应当能恢复")
        }

        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.focusRound, 1)
        assertRemaining(restored, at: 5_000, equals: focus - 2)
    }

    func testPausedFourRoundSurvivesLongerSettingAfterRestart() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        timer.pause(at: time(2))

        let storage = InMemoryTimerStorage()
        let store = TimerSettingsStore(storage: storage)
        store.save(TimerSettings(focusMinutes: 1, restMinutes: 1))
        store.save(snapshot: timer.snapshot(at: time(2)))

        let result = TimerStartup.timer(
            settings: store.settings,
            restored: store.snapshot,
            overrideDuration: nil,
            now: time(600)
        )

        XCTAssertEqual(result.timer.mode, .fourRound)
        XCTAssertEqual(result.timer.status, .paused)
        XCTAssertEqual(result.timer.focusRound, 1)
        // 调短时长不能让暂停中的剩余时间跳变。
        XCTAssertEqual(
            result.timer.remaining(at: time(600)),
            focus - 2,
            accuracy: 0.000_001
        )
    }

    func testLongRestSnapshotRestores() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        settle(&timer, at: 52) // 长休

        let snapshot = timer.snapshot(at: time(55))
        XCTAssertEqual(snapshot.restKind, .long)
        XCTAssertEqual(snapshot.focusRound, 4)

        guard let restored = StandUpTimer(snapshot: snapshot) else {
            return XCTFail("长休状态应当能恢复")
        }
        XCTAssertEqual(restored.phase, .rest)
        XCTAssertTrue(restored.isLongRest)
        XCTAssertEqual(restored.focusRound, 4)
        assertRemaining(restored, at: 55, equals: longRest - 3)
    }

    func testRestoreAfterLongRestReturnsToIdleFocus() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        let snapshot = timer.snapshot(at: t0)

        let result = TimerStartup.timer(
            settings: TimerSettings(focusMinutes: 5, restMinutes: 2),
            restored: snapshot,
            overrideDuration: nil,
            now: time(10_000)
        )

        XCTAssertEqual(result.timer.mode, .single)
        XCTAssertEqual(result.timer.status, .idle)
        XCTAssertEqual(result.timer.phase, .focus)
        XCTAssertEqual(result.timer.focusRound, 1)
    }

    // MARK: 11. 非法组合与未知版本

    func testInvalidFourRoundSnapshotsAreRejected() {
        func snapshot(
            version: Int = StandUpTimerSnapshot.currentVersion,
            mode: StandUpTimer.Mode = .fourRound,
            round: Int = 1,
            restKind: StandUpTimer.RestKind = .short,
            phase: StandUpTimer.Phase = .focus
        ) -> StandUpTimerSnapshot {
            StandUpTimerSnapshot(
                version: version,
                phase: phase,
                status: .idle,
                deadline: nil,
                remaining: 10,
                focusDuration: 10,
                restDuration: 4,
                mode: mode,
                focusRound: round,
                restKind: restKind,
                longRestDuration: longRest
            )
        }

        XCTAssertNil(StandUpTimer(snapshot: snapshot(mode: .single, round: 3)))
        XCTAssertNil(StandUpTimer(snapshot: snapshot(mode: .single, restKind: .long)))
        XCTAssertNil(StandUpTimer(snapshot: snapshot(round: 0)))
        XCTAssertNil(StandUpTimer(snapshot: snapshot(round: 5)))
        XCTAssertNil(StandUpTimer(snapshot: snapshot(version: 99)))
        XCTAssertNil(
            StandUpTimerSnapshot.decode(
                from: snapshot(version: 99).encoded() ?? Data()
            )
        )

        XCTAssertNotNil(StandUpTimer(snapshot: snapshot(round: 4)))
        XCTAssertNotNil(
            StandUpTimer(snapshot: snapshot(round: 4, restKind: .long, phase: .rest))
        )
    }

    /// 阶段 4 写下的版本 1 快照迁移为普通单轮模式，不丢正在进行的计时。
    func testVersionOneSnapshotMigratesToSingleMode() throws {
        let legacy = """
        {"version":1,"phase":"focus","status":"idle","remaining":600,
         "focusDuration":600,"restDuration":300}
        """
        let data = try XCTUnwrap(legacy.data(using: .utf8))
        let snapshot = try XCTUnwrap(StandUpTimerSnapshot.decode(from: data))

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.mode, .single)
        XCTAssertEqual(snapshot.focusRound, 1)
        XCTAssertEqual(snapshot.restKind, .short)
        XCTAssertEqual(
            snapshot.longRestDuration,
            StandUpTimer.defaultLongRestDuration
        )

        let restored = try XCTUnwrap(StandUpTimer(snapshot: snapshot))
        XCTAssertEqual(restored.status, .idle)
        assertRemaining(restored, at: 0, equals: 600)
    }

    // MARK: 12. 未来通知时间线

    func testSingleModeTimelineSchedulesFocusAndRestEnd() {
        var timer = makeTimer()
        timer.start(at: t0)

        let events = ReminderTimeline.events(for: timer, now: t0)

        XCTAssertEqual(events.map(\.kind), [.focusEnd(round: 1), .restEnd(kind: .short)])
        XCTAssertEqual(events.map(\.fireDate), [time(10), time(14)])
        XCTAssertEqual(
            ReminderTimeline.events(for: makeTimer(), now: t0),
            []
        )
    }

    func testFourRoundTimelineCoversWholeSeriesWithoutDuplicates() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        let events = ReminderTimeline.events(for: timer, now: t0)

        XCTAssertEqual(
            events.map(\.kind),
            [
                .focusEnd(round: 1), .restEnd(kind: .short),
                .focusEnd(round: 2), .restEnd(kind: .short),
                .focusEnd(round: 3), .restEnd(kind: .short),
                .focusEnd(round: 4), .restEnd(kind: .long)
            ]
        )
        XCTAssertEqual(
            events.map(\.fireDate),
            [10, 14, 24, 28, 38, 42, 52, 67].map(time)
        )

        // 没有重复的（类型，时间）组合，避免重复通知。
        let unique = Set(events.map { "\($0.kind)@\($0.fireDate.timeIntervalSinceReferenceDate)" })
        XCTAssertEqual(unique.count, events.count)
    }

    func testTimelineAfterDurationChangeUsesNewDurationsForFuturePhases() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        settle(&timer, at: 10) // 第 1 段短休，14 秒结束
        timer.updateDurations(focusDuration: 20, restDuration: 4)

        let events = ReminderTimeline.events(for: timer, now: time(10))

        XCTAssertEqual(
            events.map(\.fireDate),
            [14, 34, 38, 58, 62, 82, 97].map(time)
        )
        XCTAssertEqual(events.first?.kind, .restEnd(kind: .short))
        XCTAssertEqual(events.last?.kind, .restEnd(kind: .long))
    }

    func testTimelineFromMidSeriesOnlyContainsFutureEvents() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        settle(&timer, at: 50) // 第 4 轮专注

        let events = ReminderTimeline.events(for: timer, now: time(50))

        XCTAssertEqual(
            events.map(\.kind),
            [.focusEnd(round: 4), .restEnd(kind: .long)]
        )
        XCTAssertEqual(events.map(\.fireDate), [time(52), time(67)])
        XCTAssertTrue(events.allSatisfy { $0.fireDate > time(50) })
    }

    // MARK: 13. --test-durations 同时缩短三种阶段

    func testTestDurationShortensAllPhasesWithoutTouchingStorage() {
        let storage = InMemoryTimerStorage()
        let store = TimerSettingsStore(storage: storage)
        let settings = TimerSettings(focusMinutes: 40, restMinutes: 15)
        store.save(settings)

        let result = TimerStartup.timer(
            settings: store.settings,
            restored: nil,
            overrideDuration: 10,
            now: t0
        )

        XCTAssertTrue(result.usesOverride)
        XCTAssertFalse(result.persistsState)
        XCTAssertEqual(result.timer.focusDuration, 10)
        XCTAssertEqual(result.timer.restDuration, 10)
        XCTAssertEqual(result.timer.longRestDuration, 10)

        var timer = result.timer
        timer.startFourRounds(at: t0)
        // 每段都是 10 秒：第 4 轮专注在 70 秒结束，进入 10 秒长休。
        settle(&timer, at: 70)
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .long)
        assertRemaining(timer, at: 70, equals: 10)

        XCTAssertEqual(store.settings, settings)
        XCTAssertNil(store.snapshot)
    }
}
