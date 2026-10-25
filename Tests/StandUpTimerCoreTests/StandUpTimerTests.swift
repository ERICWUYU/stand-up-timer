import XCTest
import StandUpTimerCore

final class StandUpTimerTests: XCTestCase {
    /// 测试只使用注入的虚拟时间点，不读取系统时钟，也不等待。
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// 测试使用几秒钟的时长，但所有时间跳跃都是直接传入的日期。
    private let focusDuration: TimeInterval = 10
    private let restDuration: TimeInterval = 4

    private func makeTimer(
        focus: TimeInterval = 10,
        rest: TimeInterval = 4
    ) -> StandUpTimer {
        StandUpTimer(focusDuration: focus, restDuration: rest)
    }

    private func time(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
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

    func testNewTimerDefaultsToIdleFocus() {
        let timer = StandUpTimer()

        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        XCTAssertEqual(timer.focusDuration, 25 * 60)
        XCTAssertEqual(timer.restDuration, 5 * 60)
        assertRemaining(timer, at: 0, equals: 25 * 60)
        assertRemaining(timer, at: 100, equals: 25 * 60)
    }

    func testStartRunsAndCountsDown() {
        var timer = makeTimer()
        timer.start(at: t0)

        XCTAssertEqual(timer.status, .running)
        assertRemaining(timer, at: 2, equals: focusDuration - 2)
        XCTAssertFalse(timer.refresh(at: time(2)))
    }

    func testStartingWhileRunningDoesNotResetDeadline() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.start(at: time(2))

        assertRemaining(timer, at: 4, equals: focusDuration - 4)
    }

    func testPauseFreezesAndResumeContinues() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.pause(at: time(3))

        XCTAssertEqual(timer.status, .paused)
        assertRemaining(timer, at: 100, equals: focusDuration - 3)

        timer.resume(at: time(100))

        XCTAssertEqual(timer.status, .running)
        assertRemaining(timer, at: 102, equals: focusDuration - 5)
    }

    func testRefreshWhilePausedDoesNothing() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.pause(at: time(3))

        XCTAssertFalse(timer.refresh(at: time(9_999)))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .paused)
        assertRemaining(timer, at: 9_999, equals: focusDuration - 3)
    }

    func testFocusExpiryStartsRest() {
        var timer = makeTimer()
        timer.start(at: t0)

        XCTAssertTrue(timer.refresh(at: time(focusDuration)))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .running)
        assertRemaining(timer, at: focusDuration, equals: restDuration)
    }

    func testLateRefreshKeepsRestDeadline() {
        var timer = makeTimer()
        timer.start(at: t0)

        // 比专注截止点晚 2 秒刷新，这 2 秒已经属于休息，不能丢失。
        XCTAssertTrue(timer.refresh(at: time(focusDuration + 2)))
        XCTAssertEqual(timer.phase, .rest)
        assertRemaining(timer, at: focusDuration + 2, equals: restDuration - 2)

        // 不规则的刷新间隔不影响剩余时间。
        XCTAssertFalse(timer.refresh(at: time(focusDuration + 3)))
        assertRemaining(timer, at: focusDuration + 3, equals: restDuration - 3)
    }

    func testLongGapCascadesThroughRest() {
        var timer = makeTimer()
        timer.start(at: t0)

        let now = time(focusDuration + restDuration + 5)
        XCTAssertTrue(timer.refresh(at: now))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: focusDuration + restDuration + 5, equals: focusDuration)
    }

    func testRestExpiryReturnsToIdleFocus() {
        var timer = makeTimer()
        timer.start(at: t0)
        XCTAssertTrue(timer.refresh(at: time(focusDuration)))

        XCTAssertFalse(timer.refresh(at: time(focusDuration + restDuration - 1)))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .running)

        XCTAssertTrue(timer.refresh(at: time(focusDuration + restDuration)))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(
            timer,
            at: focusDuration + restDuration,
            equals: focusDuration
        )
    }

    func testResetRestoresFocus() {
        var timer = makeTimer()
        timer.start(at: t0)
        XCTAssertFalse(timer.refresh(at: time(4)))
        timer.reset()

        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 20, equals: focusDuration)
        XCTAssertFalse(timer.refresh(at: time(9_999)))
    }

    func testResetRestoresRest() {
        var timer = makeTimer()
        timer.skip(at: t0)
        timer.pause(at: time(2))
        timer.reset()

        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 0, equals: restDuration)
    }

    func testSkipMovesToNextPhase() {
        var timer = makeTimer()
        timer.start(at: t0)

        timer.skip(at: time(3))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .running)
        assertRemaining(timer, at: 3, equals: restDuration)

        timer.skip(at: time(3))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 3, equals: focusDuration)
    }

    func testPauseAfterDeadlineCompletesFocus() {
        var timer = makeTimer()
        timer.start(at: t0)
        timer.pause(at: time(focusDuration + 2))

        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .running)
        assertRemaining(timer, at: focusDuration + 2, equals: restDuration - 2)
    }

    func testRefreshWhileIdleDoesNothing() {
        var timer = makeTimer()

        XCTAssertFalse(timer.refresh(at: time(9_999)))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 9_999, equals: focusDuration)
    }

    func testSupportsCustomShortDurations() {
        var timer = makeTimer(focus: 3, rest: 2)
        timer.start(at: t0)

        XCTAssertTrue(timer.refresh(at: time(3)))
        XCTAssertEqual(timer.phase, .rest)
        XCTAssertEqual(timer.status, .running)
        assertRemaining(timer, at: 3, equals: 2)

        XCTAssertTrue(timer.refresh(at: time(5)))
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.status, .idle)
        assertRemaining(timer, at: 5, equals: 3)
    }
}
