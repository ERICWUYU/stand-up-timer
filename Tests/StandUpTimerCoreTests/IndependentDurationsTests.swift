import XCTest
import StandUpTimerCore

/// 阶段 5A：普通计时器与 Focus Cycle 的独立时长、迁移、快照与通知时间线。
/// 所有时间都通过构造的 `Date` 注入，不使用 `sleep`。
final class IndependentDurationsTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func time(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func makeSettings(
        normalFocus: Int = 30,
        normalRest: Int = 10,
        cycleFocus: Int = 20,
        cycleShort: Int = 7,
        cycleLong: Int = 18
    ) -> TimerSettings {
        TimerSettings(
            focusMinutes: normalFocus,
            restMinutes: normalRest,
            cycleFocusMinutes: cycleFocus,
            cycleShortRestMinutes: cycleShort,
            cycleLongRestMinutes: cycleLong
        )
    }

    private func makeTimer(
        normalFocus: TimeInterval = 100,
        normalRest: TimeInterval = 40,
        cycleFocus: TimeInterval = 20,
        cycleShort: TimeInterval = 7,
        cycleLong: TimeInterval = 18
    ) -> StandUpTimer {
        StandUpTimer(
            normalFocusDuration: normalFocus,
            normalRestDuration: normalRest,
            cycleFocusDuration: cycleFocus,
            cycleShortRestDuration: cycleShort,
            cycleLongRestDuration: cycleLong
        )
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

    // MARK: 1. 旧设置迁移

    func testLegacyFocusAndRestMigrateToBothModesWithoutDeletingOldKeys() {
        let storage = InMemoryTimerStorage()
        storage.writeInt(45, forKey: TimerSettingsStore.Key.focusMinutes)
        storage.writeInt(10, forKey: TimerSettingsStore.Key.restMinutes)
        let store = TimerSettingsStore(storage: storage)

        let settings = store.settings

        XCTAssertEqual(settings.focusMinutes, 45)
        XCTAssertEqual(settings.restMinutes, 10)
        XCTAssertEqual(settings.cycleFocusMinutes, 45)
        XCTAssertEqual(settings.cycleShortRestMinutes, 10)
        XCTAssertEqual(settings.cycleLongRestMinutes, 15)

        // 旧键保留原值，绝不删除。
        XCTAssertEqual(storage.readInt(TimerSettingsStore.Key.focusMinutes), 45)
        XCTAssertEqual(storage.readInt(TimerSettingsStore.Key.restMinutes), 10)

        // 五个新键在首次读取时写入。
        XCTAssertEqual(
            storage.readInt(TimerSettingsStore.Key.normalFocusMinutes),
            45
        )
        XCTAssertEqual(
            storage.readInt(TimerSettingsStore.Key.normalRestMinutes),
            10
        )
        XCTAssertEqual(
            storage.readInt(TimerSettingsStore.Key.cycleFocusMinutes),
            45
        )
        XCTAssertEqual(
            storage.readInt(TimerSettingsStore.Key.cycleShortRestMinutes),
            10
        )
        XCTAssertEqual(
            storage.readInt(TimerSettingsStore.Key.cycleLongRestMinutes),
            15
        )

        // 迁移是幂等的。
        XCTAssertEqual(store.settings, settings)
    }

    func testEmptyStorageUsesDefaultsAndPersistsThem() {
        let storage = InMemoryTimerStorage()
        let store = TimerSettingsStore(storage: storage)

        let settings = store.settings

        XCTAssertEqual(settings, .standard)
        XCTAssertEqual(settings.focusMinutes, 25)
        XCTAssertEqual(settings.restMinutes, 5)
        XCTAssertEqual(settings.cycleFocusMinutes, 25)
        XCTAssertEqual(settings.cycleShortRestMinutes, 5)
        XCTAssertEqual(settings.cycleLongRestMinutes, 15)

        for key in [
            TimerSettingsStore.Key.normalFocusMinutes,
            TimerSettingsStore.Key.normalRestMinutes,
            TimerSettingsStore.Key.cycleFocusMinutes,
            TimerSettingsStore.Key.cycleShortRestMinutes,
            TimerSettingsStore.Key.cycleLongRestMinutes
        ] {
            XCTAssertTrue(storage.containsValue(forKey: key), key)
        }

        // 首次迁移不创建旧键。
        XCTAssertFalse(
            storage.containsValue(forKey: TimerSettingsStore.Key.focusMinutes)
        )
        XCTAssertFalse(
            storage.containsValue(forKey: TimerSettingsStore.Key.restMinutes)
        )
    }

    func testCorruptNewValuesFallBackToDefaultsInsteadOfLegacyValues() {
        let storage = InMemoryTimerStorage()
        storage.writeInt(45, forKey: TimerSettingsStore.Key.focusMinutes)
        storage.writeInt(10, forKey: TimerSettingsStore.Key.restMinutes)

        // 键存在但值损坏：字符串、越界、负数、NaN。
        storage.writeString(
            "broken",
            forKey: TimerSettingsStore.Key.normalFocusMinutes
        )
        storage.writeInt(0, forKey: TimerSettingsStore.Key.normalRestMinutes)
        storage.writeInt(
            999,
            forKey: TimerSettingsStore.Key.cycleFocusMinutes
        )
        storage.writeInt(
            -1,
            forKey: TimerSettingsStore.Key.cycleShortRestMinutes
        )
        storage.writeDouble(
            .nan,
            forKey: TimerSettingsStore.Key.cycleLongRestMinutes
        )

        let store = TimerSettingsStore(storage: storage)
        let settings = store.settings

        XCTAssertEqual(settings.focusMinutes, 25)
        XCTAssertEqual(settings.restMinutes, 5)
        XCTAssertEqual(settings.cycleFocusMinutes, 25)
        XCTAssertEqual(settings.cycleShortRestMinutes, 5)
        XCTAssertEqual(settings.cycleLongRestMinutes, 15)

        // 旧键仍然保持迁移前的原值。
        XCTAssertEqual(storage.readInt(TimerSettingsStore.Key.focusMinutes), 45)
        XCTAssertEqual(storage.readInt(TimerSettingsStore.Key.restMinutes), 10)

        // 损坏值被默认值修复，下一次读取稳定。
        XCTAssertEqual(store.settings, settings)
        XCTAssertEqual(
            storage.readInt(TimerSettingsStore.Key.normalFocusMinutes),
            25
        )
        XCTAssertEqual(
            storage.readInt(TimerSettingsStore.Key.cycleLongRestMinutes),
            15
        )
    }

    func testNewKeysTakePrecedenceOverLegacyKeys() {
        let storage = InMemoryTimerStorage()
        storage.writeInt(45, forKey: TimerSettingsStore.Key.focusMinutes)
        storage.writeInt(10, forKey: TimerSettingsStore.Key.restMinutes)
        let store = TimerSettingsStore(storage: storage)

        XCTAssertEqual(store.settings.focusMinutes, 45)

        // 迁移后改动旧键不能影响新设置。
        storage.writeInt(90, forKey: TimerSettingsStore.Key.focusMinutes)
        XCTAssertEqual(store.settings.focusMinutes, 45)
        XCTAssertEqual(store.settings.cycleFocusMinutes, 45)
    }

    // MARK: 2. 边界与非法参数

    func testDurationBoundariesAreAccepted() {
        let settings = TimerSettings(
            focusMinutes: 180,
            restMinutes: 60,
            cycleFocusMinutes: 180,
            cycleShortRestMinutes: 60,
            cycleLongRestMinutes: 60
        )

        XCTAssertEqual(settings.focusMinutes, 180)
        XCTAssertEqual(settings.restMinutes, 60)
        XCTAssertEqual(settings.cycleFocusMinutes, 180)
        XCTAssertEqual(settings.cycleShortRestMinutes, 60)
        XCTAssertEqual(settings.cycleLongRestMinutes, 60)
        XCTAssertEqual(settings.cycleFocusDuration, 180 * 60)
        XCTAssertEqual(settings.cycleShortRestDuration, 60 * 60)
        XCTAssertEqual(settings.cycleLongRestDuration, 60 * 60)
    }

    func testOutOfRangeCycleValuesFallBackWithoutAffectingNormalValues() {
        let settings = TimerSettings(
            focusMinutes: 30,
            restMinutes: 10,
            cycleFocusMinutes: 181,
            cycleShortRestMinutes: 0,
            cycleLongRestMinutes: 61
        )

        XCTAssertEqual(settings.focusMinutes, 30)
        XCTAssertEqual(settings.restMinutes, 10)
        XCTAssertEqual(settings.cycleFocusMinutes, 25)
        XCTAssertEqual(settings.cycleShortRestMinutes, 5)
        XCTAssertEqual(settings.cycleLongRestMinutes, 15)
    }

    func testOmittedCycleValuesMirrorNormalValues() {
        let settings = TimerSettings(focusMinutes: 40, restMinutes: 12)

        XCTAssertEqual(settings.cycleFocusMinutes, 40)
        XCTAssertEqual(settings.cycleShortRestMinutes, 12)
        XCTAssertEqual(settings.cycleLongRestMinutes, 15)
    }

    // MARK: 3. 两种模式使用各自时长

    func testTimerStartupUsesIndependentModeDurations() {
        let settings = makeSettings()
        let result = TimerStartup.timer(
            settings: settings,
            restored: nil,
            overrideDuration: nil,
            now: t0
        )

        XCTAssertEqual(result.timer.normalFocusDuration, 30 * 60)
        XCTAssertEqual(result.timer.normalRestDuration, 10 * 60)
        XCTAssertEqual(result.timer.cycleFocusDuration, 20 * 60)
        XCTAssertEqual(result.timer.cycleShortRestDuration, 7 * 60)
        XCTAssertEqual(result.timer.cycleLongRestDuration, 18 * 60)

        // 普通模式从普通专注开始。
        XCTAssertEqual(result.timer.remaining(at: t0), 30 * 60)
    }

    func testFourRoundUsesThreeShortBreaksAndOneConfiguredLongBreak() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        XCTAssertEqual(timer.mode, .fourRound)
        assertRemaining(timer, at: 0, equals: 20)

        timer.refresh(at: time(20))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        assertRemaining(timer, at: 20, equals: 7)

        timer.refresh(at: time(27))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 27, equals: 20)

        timer.refresh(at: time(47))
        XCTAssertEqual(timer.restKind, .short)

        timer.refresh(at: time(54))
        XCTAssertEqual(timer.focusRound, 3)
        assertRemaining(timer, at: 54, equals: 20)

        timer.refresh(at: time(74))
        XCTAssertEqual(timer.restKind, .short)

        timer.refresh(at: time(81))
        XCTAssertEqual(timer.focusRound, 4)
        assertRemaining(timer, at: 81, equals: 20)

        timer.refresh(at: time(101))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .long)
        assertRemaining(timer, at: 101, equals: 18)

        timer.refresh(at: time(119))
        XCTAssertEqual(timer.mode, .single)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 1)
        // 系列结束后使用普通模式的专注时长，而不是循环时长。
        assertRemaining(timer, at: 119, equals: 100)
    }

    func testSingleModeRestUsesNormalRestDuration() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.refresh(at: time(100))

        XCTAssertEqual(timer.phase, .rest)
        assertRemaining(timer, at: 100, equals: 40)

        timer.refresh(at: time(140))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 140, equals: 100)
    }

    // MARK: 4. 空闲时修改设置

    func testChangingIdleNormalDurationUpdatesOnlyTheCurrentNormalPhase() {
        var timer = makeTimer()

        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )
        assertRemaining(timer, at: 0, equals: 200)

        // 进入空闲休息后，再改普通休息时长。
        timer.skip(at: t0)
        timer.pause(at: t0)
        timer.reset()
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 0, equals: 50)

        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 65,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )
        assertRemaining(timer, at: 0, equals: 65)
    }

    func testChangingIdleCycleDurationUpdatesOnlyTheCurrentCyclePhase() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        timer.pause(at: time(5))
        timer.reset()

        XCTAssertEqual(timer.mode, .fourRound)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 5, equals: 20)

        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 35,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )
        assertRemaining(timer, at: 5, equals: 35)

        // 只改普通时长，不应影响正在显示的循环专注。
        timer.updateDurations(
            normalFocusDuration: 300,
            normalRestDuration: 70,
            cycleFocusDuration: 35,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )
        assertRemaining(timer, at: 5, equals: 35)
    }

    // MARK: 5. 运行中与暂停中修改设置

    func testChangingSettingsWhileRunningKeepsDeadlineAndUsesNewFutureDurations() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)

        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )

        // 当前专注仍在 20 秒结束，不因新设置延长或缩短。
        assertRemaining(timer, at: 5, equals: 15)

        timer.refresh(at: time(20))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        assertRemaining(timer, at: 20, equals: 9)

        timer.refresh(at: time(29))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 29, equals: 30)

        timer.refresh(at: time(59))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        assertRemaining(timer, at: 59, equals: 9)

        // 剩余阶段使用新的 30/9/25 节奏，最后回到普通 200 秒专注。
        timer.refresh(at: time(162))
        XCTAssertEqual(timer.mode, .single)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.phase, .focus)
        assertRemaining(timer, at: 162, equals: 200)
    }

    func testChangingSettingsWhilePausedKeepsFrozenRemaining() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        timer.pause(at: time(5))

        XCTAssertEqual(timer.status, .paused)
        assertRemaining(timer, at: 5, equals: 15)

        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )

        // 暂停中的剩余时间完全不变。
        assertRemaining(timer, at: 9_999, equals: 15)

        timer.resume(at: time(100))
        assertRemaining(timer, at: 100, equals: 15)

        timer.refresh(at: time(115))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.restKind, .short)
        assertRemaining(timer, at: 115, equals: 9)

        timer.refresh(at: time(124))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 124, equals: 30)
    }

    // MARK: 6. 取消与完成回到普通模式

    func testCancelAndCompletionReturnToNormalIdleFocusDuration() {
        var cancelled = makeTimer()
        cancelled.startFourRounds(at: t0)
        cancelled.pause(at: time(5))
        cancelled.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )
        cancelled.cancelFourRounds()

        XCTAssertEqual(cancelled.mode, .single)
        XCTAssertEqual(cancelled.status, .idle)
        XCTAssertEqual(cancelled.phase, .focus)
        assertRemaining(cancelled, at: 5, equals: 200)

        var completed = makeTimer()
        completed.startFourRounds(at: t0)
        for _ in 0..<7 {
            completed.skip(at: t0)
        }
        XCTAssertEqual(completed.phase, .rest)
        XCTAssertEqual(completed.restKind, .long)
        completed.skip(at: t0)

        XCTAssertEqual(completed.mode, .single)
        XCTAssertEqual(completed.status, .idle)
        XCTAssertEqual(completed.phase, .focus)
        assertRemaining(completed, at: 0, equals: 100)
    }

    // MARK: 7. 快照保存与恢复

    func testSnapshotPreservesModeRoundPhaseAndActualDurationAfterSettingsChange() throws {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )

        let snapshot = timer.snapshot(at: time(5))

        XCTAssertEqual(snapshot.version, StandUpTimerSnapshot.currentVersion)
        XCTAssertEqual(snapshot.mode, .fourRound)
        XCTAssertEqual(snapshot.focusRound, 1)
        XCTAssertEqual(snapshot.phase, .focus)
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.remaining, 15, accuracy: 0.000_001)
        // 当前这一轮实际仍在 20 秒结束，后续阶段使用新设置。
        XCTAssertEqual(snapshot.currentPhaseDuration, 20)
        XCTAssertEqual(snapshot.cycleFocusDuration, 30)
        XCTAssertEqual(snapshot.cycleShortRestDuration, 9)
        XCTAssertEqual(snapshot.cycleLongRestDuration, 25)
        XCTAssertEqual(snapshot.normalFocusDuration, 200)
        XCTAssertEqual(snapshot.normalRestDuration, 50)

        let data = try XCTUnwrap(snapshot.encoded())
        let decoded = try XCTUnwrap(StandUpTimerSnapshot.decode(from: data))
        XCTAssertEqual(decoded, snapshot)

        var restored = try XCTUnwrap(StandUpTimer(snapshot: decoded))
        XCTAssertEqual(restored.mode, .fourRound)
        XCTAssertEqual(restored.focusRound, 1)
        XCTAssertEqual(restored.phase, .focus)
        assertRemaining(restored, at: 5, equals: 15)

        restored.refresh(at: time(20))
        XCTAssertEqual(restored.phase, .rest)
        XCTAssertEqual(restored.restKind, .short)
        assertRemaining(restored, at: 20, equals: 9)

        restored.refresh(at: time(29))
        XCTAssertEqual(restored.phase, .focus)
        XCTAssertEqual(restored.focusRound, 2)
        assertRemaining(restored, at: 29, equals: 30)
    }

    func testPausedSnapshotRestoresFrozenRemainingAndFutureDurations() throws {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        timer.pause(at: time(5))
        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )

        let snapshot = timer.snapshot(at: time(10))
        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.remaining, 15, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.currentPhaseDuration, 20)

        var restored = try XCTUnwrap(StandUpTimer(snapshot: snapshot))
        assertRemaining(restored, at: 10, equals: 15)

        restored.resume(at: time(100))
        assertRemaining(restored, at: 100, equals: 15)
        restored.refresh(at: time(115))
        XCTAssertEqual(restored.restKind, .short)
        assertRemaining(restored, at: 115, equals: 9)
        restored.refresh(at: time(124))
        XCTAssertEqual(restored.focusRound, 2)
        assertRemaining(restored, at: 124, equals: 30)
    }

    func testIdleFourRoundSnapshotAdoptsNewCycleDurationOnStartup() throws {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        for _ in 0..<4 {
            timer.skip(at: t0)
        }
        // 第 3 轮专注中；重置后仍在四轮模式，但处于空闲。
        XCTAssertEqual(timer.focusRound, 3)
        timer.reset()
        let snapshot = timer.snapshot(at: t0)
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(snapshot.currentPhaseDuration, 20)

        let result = TimerStartup.timer(
            settings: makeSettings(
                normalFocus: 80,
                normalRest: 30,
                cycleFocus: 35,
                cycleShort: 12,
                cycleLong: 22
            ),
            restored: snapshot,
            overrideDuration: nil,
            now: t0
        )

        XCTAssertEqual(result.timer.mode, .fourRound)
        XCTAssertEqual(result.timer.focusRound, 3)
        XCTAssertEqual(result.timer.status, .idle)
        // 设置以分钟计：35 分钟 = 2100 秒。
        assertRemaining(result.timer, at: 0, equals: 35 * 60)
    }

    func testSnapshotWithInvalidIndependentDurationIsRejected() throws {
        let invalidNormal = StandUpTimerSnapshot(
            phase: .focus,
            status: .idle,
            deadline: nil,
            remaining: 10,
            focusDuration: 10,
            restDuration: 4,
            normalFocusDuration: 0
        )
        XCTAssertNil(StandUpTimer(snapshot: invalidNormal))
        let data = try XCTUnwrap(invalidNormal.encoded())
        XCTAssertNil(StandUpTimerSnapshot.decode(from: data))

        let invalidCycle = StandUpTimerSnapshot(
            phase: .rest,
            status: .idle,
            deadline: nil,
            remaining: 10,
            focusDuration: 10,
            restDuration: 4,
            mode: .fourRound,
            restKind: .long,
            longRestDuration: 15,
            cycleLongRestDuration: .nan
        )
        XCTAssertNil(StandUpTimer(snapshot: invalidCycle))
    }

    func testVersionTwoSnapshotMigratesToIndependentDurations() throws {
        let deadline = time(10).timeIntervalSinceReferenceDate
        let legacy = """
        {"version":2,"phase":"focus","status":"running","deadline":\(deadline),
         "remaining":10,"focusDuration":10,"restDuration":4,
         "mode":"fourRound","focusRound":2,"restKind":"short",
         "longRestDuration":15}
        """
        let data = try XCTUnwrap(legacy.data(using: .utf8))
        let snapshot = try XCTUnwrap(StandUpTimerSnapshot.decode(from: data))

        XCTAssertEqual(snapshot.version, 2)
        XCTAssertEqual(snapshot.mode, .fourRound)
        XCTAssertEqual(snapshot.focusRound, 2)
        // 旧快照只有一个专注/短休/长休时长，迁移时同时作为两种模式的起点。
        XCTAssertEqual(snapshot.normalFocusDuration, 10)
        XCTAssertEqual(snapshot.normalRestDuration, 4)
        XCTAssertEqual(snapshot.cycleFocusDuration, 10)
        XCTAssertEqual(snapshot.cycleShortRestDuration, 4)
        XCTAssertEqual(snapshot.cycleLongRestDuration, 15)
        XCTAssertEqual(snapshot.currentPhaseDuration, 10)

        var timer = try XCTUnwrap(StandUpTimer(snapshot: snapshot))
        XCTAssertEqual(timer.mode, .fourRound)
        XCTAssertEqual(timer.focusRound, 2)
        assertRemaining(timer, at: 5, equals: 5)
    }

    // MARK: 8. 通知时间线

    func testTimelineUsesEachModesOwnDurations() {
        var single = makeTimer()
        single.start(at: t0)
        let singleEvents = ReminderTimeline.events(for: single, now: t0)

        XCTAssertEqual(
            singleEvents.map(\.kind),
            [.focusEnd(round: 1), .restEnd(kind: .short)]
        )
        XCTAssertEqual(singleEvents.map(\.fireDate), [time(100), time(140)])

        var cycle = makeTimer()
        cycle.startFourRounds(at: t0)
        let cycleEvents = ReminderTimeline.events(for: cycle, now: t0)

        XCTAssertEqual(
            cycleEvents.map(\.kind),
            [
                .focusEnd(round: 1), .restEnd(kind: .short),
                .focusEnd(round: 2), .restEnd(kind: .short),
                .focusEnd(round: 3), .restEnd(kind: .short),
                .focusEnd(round: 4), .restEnd(kind: .long)
            ]
        )
        XCTAssertEqual(
            cycleEvents.map(\.fireDate),
            [20, 27, 47, 54, 74, 81, 101, 119].map(time)
        )
    }

    func testTimelineAfterSettingsChangeKeepsCurrentDeadline() {
        var timer = makeTimer()
        timer.startFourRounds(at: t0)
        timer.updateDurations(
            normalFocusDuration: 200,
            normalRestDuration: 50,
            cycleFocusDuration: 30,
            cycleShortRestDuration: 9,
            cycleLongRestDuration: 25
        )

        let events = ReminderTimeline.events(for: timer, now: time(5))

        // 当前专注仍在 20 秒结束；后续阶段使用新的 30/9/25。
        XCTAssertEqual(
            events.map(\.fireDate),
            [20, 29, 59, 68, 98, 107, 137, 162].map(time)
        )
        XCTAssertEqual(
            events.map(\.kind),
            [
                .focusEnd(round: 1), .restEnd(kind: .short),
                .focusEnd(round: 2), .restEnd(kind: .short),
                .focusEnd(round: 3), .restEnd(kind: .short),
                .focusEnd(round: 4), .restEnd(kind: .long)
            ]
        )
        XCTAssertTrue(events.allSatisfy { $0.fireDate > time(5) })
    }
}
