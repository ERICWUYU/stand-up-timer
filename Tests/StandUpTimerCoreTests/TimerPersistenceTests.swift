import XCTest
import StandUpTimerCore

/// 阶段 4：设置、时长变更、状态保存与恢复、声音开关。
/// 所有时间都通过构造的 `Date` 注入，不使用 `sleep`。
final class TimerPersistenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func time(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private var defaultSettings: TimerSettings {
        TimerSettings(focusMinutes: nil, restMinutes: nil)
    }

    private func makeTimer(focus: TimeInterval, rest: TimeInterval) -> StandUpTimer {
        StandUpTimer(focusDuration: focus, restDuration: rest)
    }

    // MARK: 1. 默认 25/5 与自定义时长

    func testDefaultSettingsProduce25And5Minutes() {
        XCTAssertEqual(defaultSettings, .standard)
        XCTAssertEqual(defaultSettings.focusDuration, 25 * 60)
        XCTAssertEqual(defaultSettings.restDuration, 5 * 60)

        let result = TimerStartup.timer(
            settings: defaultSettings,
            restored: nil,
            overrideDuration: nil,
            now: t0
        )

        XCTAssertFalse(result.usesOverride)
        XCTAssertTrue(result.persistsState)
        XCTAssertEqual(result.timer.focusDuration, 25 * 60)
        XCTAssertEqual(result.timer.restDuration, 5 * 60)
        XCTAssertEqual(result.timer.phase, .focus)
        XCTAssertEqual(result.timer.status, .idle)
        XCTAssertEqual(result.timer.remaining(at: t0), 25 * 60)
    }

    func testCustomSettingsProduceCustomDurations() {
        let settings = TimerSettings(focusMinutes: 45, restMinutes: 10)
        let result = TimerStartup.timer(
            settings: settings,
            restored: nil,
            overrideDuration: nil,
            now: t0
        )

        XCTAssertEqual(result.timer.focusDuration, 45 * 60)
        XCTAssertEqual(result.timer.restDuration, 10 * 60)
        XCTAssertEqual(result.timer.remaining(at: t0), 45 * 60)
    }

    func testOutOfRangeSettingsFallBackToDefaults() {
        XCTAssertEqual(
            TimerSettings(focusMinutes: 0, restMinutes: -5),
            .standard
        )
        XCTAssertEqual(
            TimerSettings(focusMinutes: 181, restMinutes: 61),
            .standard
        )
        XCTAssertEqual(
            TimerSettings(focusMinutes: 180, restMinutes: 60),
            TimerSettings(focusMinutes: 180, restMinutes: 60)
        )
    }

    // MARK: 2. 空闲状态修改时长

    func testChangingDurationsWhileIdleAdoptsNewFullDuration() {
        var timer = makeTimer(focus: 600, rest: 300)

        timer.updateDurations(focusDuration: 1_200, restDuration: 300)

        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.remaining(at: t0), 1_200)

        // 空闲的休息阶段同样立即采用新的完整时长。
        timer.skip(at: t0)
        timer.pause(at: time(30))
        timer.reset()
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .idle)

        timer.updateDurations(focusDuration: 1_200, restDuration: 400)
        XCTAssertEqual(timer.remaining(at: t0), 400)
    }

    // MARK: 3. 运行中修改设置不改变当前截止点

    func testChangingDurationsWhileRunningKeepsDeadlineAndAppliesNextPhase() {
        var timer = makeTimer(focus: 600, rest: 300)
        timer.start(at: t0)

        let before = timer.remaining(at: time(10))
        timer.updateDurations(focusDuration: 1_800, restDuration: 900)

        XCTAssertEqual(timer.status, .running)
        XCTAssertEqual(timer.remaining(at: time(10)), before, accuracy: 0.000_001)

        // 新时长从进入休息时生效。
        XCTAssertTrue(timer.refresh(at: time(600)))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.remaining(at: time(600)), 900, accuracy: 0.000_001)
    }

    func testChangingDurationsWhilePausedKeepsFrozenRemaining() {
        var timer = makeTimer(focus: 600, rest: 300)
        timer.start(at: t0)
        timer.pause(at: time(20))

        timer.updateDurations(focusDuration: 1_800, restDuration: 900)

        XCTAssertEqual(timer.status, .paused)
        XCTAssertEqual(timer.remaining(at: time(9_999)), 580, accuracy: 0.000_001)
    }

    // MARK: 4. 运行状态按绝对截止时间恢复

    func testRestoresRunningTimerFromAbsoluteDeadline() {
        var timer = makeTimer(focus: 600, rest: 300)
        timer.start(at: t0)
        let snapshot = timer.snapshot(at: time(60))

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertNotNil(snapshot.deadline)

        let result = TimerStartup.timer(
            settings: TimerSettings(focusMinutes: 10, restMinutes: 5),
            restored: snapshot,
            overrideDuration: nil,
            now: time(120)
        )

        XCTAssertEqual(result.timer.status, .running)
        XCTAssertEqual(result.timer.phase, .focus)
        XCTAssertEqual(result.timer.remaining(at: time(120)), 480, accuracy: 0.000_001)
    }

    // MARK: 5. 恢复时跨过专注和休息后回到空闲专注

    func testRestoreAcrossFocusAndRestEndsIdleFocus() {
        var timer = makeTimer(focus: 600, rest: 300)
        timer.start(at: t0)
        let snapshot = timer.snapshot(at: t0)

        let result = TimerStartup.timer(
            settings: TimerSettings(focusMinutes: 10, restMinutes: 5),
            restored: snapshot,
            overrideDuration: nil,
            now: time(1_000)
        )

        XCTAssertEqual(result.timer.phase, .focus)
        XCTAssertEqual(result.timer.status, .idle)
        XCTAssertEqual(result.timer.remaining(at: time(1_000)), 600, accuracy: 0.000_001)
    }

    // MARK: 6. 暂停状态恢复后剩余时间冻结

    func testPausedSnapshotKeepsRemainingAfterRestore() {
        var timer = makeTimer(focus: 600, rest: 300)
        timer.start(at: t0)
        timer.pause(at: time(100))
        let snapshot = timer.snapshot(at: time(100))

        XCTAssertNil(snapshot.deadline)

        let result = TimerStartup.timer(
            settings: TimerSettings(focusMinutes: 10, restMinutes: 5),
            restored: snapshot,
            overrideDuration: nil,
            now: time(5_000)
        )

        XCTAssertEqual(result.timer.status, .paused)
        XCTAssertEqual(result.timer.remaining(at: time(5_000)), 500, accuracy: 0.000_001)
    }

    /// 回归：暂停期间调短阶段时长，重启后仍保留原冻结剩余时间。
    func testShorteningDurationWhilePausedKeepsFrozenRemainingAfterRestart() {
        var timer = makeTimer(focus: 600, rest: 300)
        timer.start(at: t0)
        timer.pause(at: time(20)) // 冻结 580 秒

        let storage = InMemoryTimerStorage()
        let store = TimerSettingsStore(storage: storage)
        store.save(TimerSettings(focusMinutes: 5, restMinutes: 5))
        store.save(snapshot: timer.snapshot(at: time(20)))

        let result = TimerStartup.timer(
            settings: store.settings,
            restored: store.snapshot,
            overrideDuration: nil,
            now: time(3_600)
        )

        XCTAssertEqual(result.timer.status, .paused)
        XCTAssertEqual(
            result.timer.remaining(at: time(3_600)),
            580,
            accuracy: 0.000_001
        )

        var restored = result.timer
        restored.resume(at: time(3_600))
        XCTAssertEqual(
            restored.remaining(at: time(3_600)),
            580,
            accuracy: 0.000_001
        )

        // 只有 Reset 才采用新的完整时长。
        restored.reset()
        XCTAssertEqual(restored.remaining(at: time(3_600)), 300)
    }

    // MARK: 7. 空闲休息阶段恢复

    func testIdleRestSnapshotRestoresWithoutStarting() {
        var timer = makeTimer(focus: 600, rest: 300)
        timer.skip(at: t0)
        timer.pause(at: time(30))
        timer.reset()

        let snapshot = timer.snapshot(at: time(30))
        XCTAssertEqual(snapshot.phase, .rest)
        XCTAssertEqual(snapshot.status, .idle)

        let result = TimerStartup.timer(
            settings: TimerSettings(focusMinutes: 10, restMinutes: 5),
            restored: snapshot,
            overrideDuration: nil,
            now: time(9_000)
        )

        XCTAssertEqual(result.timer.phase, .rest)
        XCTAssertEqual(result.timer.status, .idle)
        XCTAssertEqual(result.timer.remaining(at: time(9_000)), 300, accuracy: 0.000_001)
    }

    // MARK: 8. 损坏、未知版本和非法数值安全回退

    func testCorruptDataIsDiscarded() {
        XCTAssertNil(StandUpTimerSnapshot.decode(from: Data("not json".utf8)))
        XCTAssertNil(StandUpTimerSnapshot.decode(from: Data()))

        let storage = InMemoryTimerStorage()
        storage.writeData(Data("garbage".utf8), forKey: TimerSettingsStore.Key.state)
        let store = TimerSettingsStore(storage: storage)
        XCTAssertNil(store.snapshot)
    }

    func testUnknownVersionIsDiscarded() {
        let future = StandUpTimerSnapshot(
            version: StandUpTimerSnapshot.currentVersion + 1,
            phase: .focus,
            status: .idle,
            deadline: nil,
            remaining: 600,
            focusDuration: 600,
            restDuration: 300
        )

        XCTAssertNil(StandUpTimer(snapshot: future))

        let data = try? JSONEncoder().encode(future)
        XCTAssertNotNil(data)
        XCTAssertNil(data.flatMap(StandUpTimerSnapshot.decode(from:)))
    }

    func testContradictoryValuesAreRejected() {
        let runningWithoutDeadline = StandUpTimerSnapshot(
            phase: .focus,
            status: .running,
            deadline: nil,
            remaining: 10,
            focusDuration: 600,
            restDuration: 300
        )
        XCTAssertNil(StandUpTimer(snapshot: runningWithoutDeadline))

        let idleWithDeadline = StandUpTimerSnapshot(
            phase: .focus,
            status: .idle,
            deadline: t0,
            remaining: 10,
            focusDuration: 600,
            restDuration: 300
        )
        XCTAssertNil(StandUpTimer(snapshot: idleWithDeadline))

        let nonFiniteRemaining = StandUpTimerSnapshot(
            phase: .focus,
            status: .paused,
            deadline: nil,
            remaining: .nan,
            focusDuration: 600,
            restDuration: 300
        )
        XCTAssertNil(StandUpTimer(snapshot: nonFiniteRemaining))

        let negativeRemaining = StandUpTimerSnapshot(
            phase: .focus,
            status: .paused,
            deadline: nil,
            remaining: -1,
            focusDuration: 600,
            restDuration: 300
        )
        XCTAssertNil(StandUpTimer(snapshot: negativeRemaining))

        let zeroDuration = StandUpTimerSnapshot(
            phase: .focus,
            status: .idle,
            deadline: nil,
            remaining: 0,
            focusDuration: 0,
            restDuration: 300
        )
        XCTAssertNil(StandUpTimer(snapshot: zeroDuration))
    }

    func testInvalidSnapshotFallsBackToDefaultTimer() {
        let broken = StandUpTimerSnapshot(
            phase: .rest,
            status: .running,
            deadline: nil,
            remaining: 10,
            focusDuration: 600,
            restDuration: 300
        )

        let result = TimerStartup.timer(
            settings: TimerSettings(focusMinutes: 30, restMinutes: 8),
            restored: broken,
            overrideDuration: nil,
            now: time(9_999)
        )

        XCTAssertEqual(result.timer.phase, .focus)
        XCTAssertEqual(result.timer.status, .idle)
        XCTAssertEqual(result.timer.remaining(at: time(9_999)), 30 * 60)
    }

    // MARK: 9. --test-durations 不覆盖持久化设置

    func testTestDurationDoesNotOverwriteStoredSettings() {
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

        // 持久化的设置没有被测试时长改写。
        XCTAssertEqual(store.settings, settings)
        XCTAssertEqual(storage.readInt(TimerSettingsStore.Key.focusMinutes), 40)
        XCTAssertEqual(storage.readInt(TimerSettingsStore.Key.restMinutes), 15)
    }

    // MARK: 10. 声音开关保存并让通知保持无声

    func testSoundPreferencePersistsAndSilencesNotifications() {
        let storage = InMemoryTimerStorage()
        let store = TimerSettingsStore(storage: storage)

        // 默认开启并使用 Glass。
        XCTAssertEqual(
            store.reminderSound,
            ReminderSoundPreference(isEnabled: true, sound: .glass)
        )

        store.save(ReminderSoundPreference(isEnabled: true, sound: .funk))
        XCTAssertEqual(store.reminderSound.sound, .funk)
        XCTAssertEqual(store.reminderSound.notificationSound, .funk)

        // 关闭后通知无声，但选择仍然保存在偏好里。
        store.save(ReminderSoundPreference(isEnabled: false, sound: .funk))
        XCTAssertFalse(store.reminderSound.isEnabled)
        XCTAssertNil(store.reminderSound.notificationSound)
        XCTAssertEqual(store.reminderSound.sound, .funk)

        // 重新开启沿用先前选择的音效，而不是回到 Glass。
        store.save(ReminderSoundPreference(isEnabled: true, sound: .funk))
        XCTAssertEqual(store.reminderSound.notificationSound, .funk)
    }

    func testUnknownStoredSoundFallsBackToGlass() {
        let storage = InMemoryTimerStorage()
        storage.writeString("bagpipes", forKey: TimerSettingsStore.Key.sound)
        let store = TimerSettingsStore(storage: storage)

        XCTAssertEqual(store.reminderSound.sound, .glass)
    }

    // MARK: 设置的持久化与状态往返

    func testSettingsAndSnapshotRoundTripThroughStorage() {
        let storage = InMemoryTimerStorage()
        let store = TimerSettingsStore(storage: storage)

        let settings = TimerSettings(focusMinutes: 90, restMinutes: 20)
        store.save(settings)
        XCTAssertEqual(store.settings, settings)

        var timer = makeTimer(focus: 600, rest: 300)
        timer.start(at: t0)
        store.save(snapshot: timer.snapshot(at: time(30)))

        let restored = store.snapshot
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.status, .running)
        XCTAssertEqual(restored?.phase, .focus)

        guard let rebuilt = restored.flatMap(StandUpTimer.init(snapshot:)) else {
            return XCTFail("保存的计时状态应当能恢复")
        }
        XCTAssertEqual(rebuilt.remaining(at: time(30)), 570, accuracy: 0.000_001)
    }
}
