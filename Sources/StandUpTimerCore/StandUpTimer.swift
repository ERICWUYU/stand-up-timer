import Foundation

/// 纯计时核心：不依赖界面、通知或系统时钟，所有时间点由调用方传入。
public struct StandUpTimer: Sendable {
    /// 计时阶段。`.rest` 即文档中的“休息 / break”。
    public enum Phase: String, Codable, Equatable, Sendable {
        case focus
        case rest
    }

    /// 运行状态，与阶段相互独立。
    public enum Status: String, Codable, Equatable, Sendable {
        case idle
        case running
        case paused
    }

    /// 计时模式：普通单轮，或“四轮连续”。
    ///
    /// 四轮连续是用户选择的产品节奏：4 次专注与短休交替，最后以长休结束。
    /// 它不是健康保证，也不要求所有人遵守。
    public enum Mode: String, Codable, Equatable, Sendable {
        case single
        case fourRound
    }

    /// 休息类型。长休只出现在四轮连续模式的第 4 次专注之后。
    public enum RestKind: String, Codable, Equatable, Sendable {
        case short
        case long
    }

    /// 四轮连续模式的专注次数。
    public static let focusRoundCount = 4
    /// 四轮连续模式长休的默认时长；实际值由设置决定。
    public static let defaultLongRestDuration: TimeInterval = 15 * 60

    // 普通计时器与 Focus Cycle 各自独立的时长设置。
    public private(set) var normalFocusDuration: TimeInterval
    public private(set) var normalRestDuration: TimeInterval
    public private(set) var cycleFocusDuration: TimeInterval
    public private(set) var cycleShortRestDuration: TimeInterval
    public private(set) var cycleLongRestDuration: TimeInterval

    public private(set) var mode: Mode
    /// 当前专注轮次，范围 1...`focusRoundCount`；长休期间保留刚完成的轮次。
    public private(set) var focusRound: Int
    /// 当前休息类型；专注阶段保存下一次休息的类型，由轮次决定。
    public private(set) var restKind: RestKind

    public private(set) var phase: Phase
    public private(set) var status: Status

    /// 空闲或暂停时冻结的剩余时长。
    private var storedRemaining: TimeInterval
    /// 运行中唯一的计时依据。
    private var deadline: Date?
    /// 当前阶段开始时实际采用的完整时长。
    ///
    /// 运行中或暂停中修改设置时，这个值保持不变；新设置只影响后续阶段。
    private var currentPhaseFullDuration: TimeInterval

    /// 旧版便捷初始化：普通模式和 Focus Cycle 使用同一组时长。
    public init(
        focusDuration: TimeInterval = 25 * 60,
        restDuration: TimeInterval = 5 * 60,
        longRestDuration: TimeInterval = StandUpTimer.defaultLongRestDuration
    ) {
        self.init(
            normalFocusDuration: focusDuration,
            normalRestDuration: restDuration,
            cycleFocusDuration: focusDuration,
            cycleShortRestDuration: restDuration,
            cycleLongRestDuration: longRestDuration
        )
    }

    /// 普通模式与 Focus Cycle 使用独立时长。
    public init(
        normalFocusDuration: TimeInterval,
        normalRestDuration: TimeInterval,
        cycleFocusDuration: TimeInterval,
        cycleShortRestDuration: TimeInterval,
        cycleLongRestDuration: TimeInterval
    ) {
        precondition(
            Self.isValidDuration(normalFocusDuration)
                && Self.isValidDuration(normalRestDuration)
                && Self.isValidDuration(cycleFocusDuration)
                && Self.isValidDuration(cycleShortRestDuration)
                && Self.isValidDuration(cycleLongRestDuration),
            "所有时长必须是正的有限值"
        )
        self.normalFocusDuration = normalFocusDuration
        self.normalRestDuration = normalRestDuration
        self.cycleFocusDuration = cycleFocusDuration
        self.cycleShortRestDuration = cycleShortRestDuration
        self.cycleLongRestDuration = cycleLongRestDuration
        self.mode = .single
        self.focusRound = 1
        self.restKind = .short
        self.phase = .focus
        self.status = .idle
        self.storedRemaining = normalFocusDuration
        self.currentPhaseFullDuration = normalFocusDuration
    }

    /// 当前模式下的专注时长，供旧调用方读取。
    public var focusDuration: TimeInterval {
        mode == .fourRound ? cycleFocusDuration : normalFocusDuration
    }

    /// 当前模式下的短休时长。
    public var restDuration: TimeInterval {
        mode == .fourRound ? cycleShortRestDuration : normalRestDuration
    }

    /// Focus Cycle 的长休时长。
    public var longRestDuration: TimeInterval {
        cycleLongRestDuration
    }

    /// 当前阶段实际采用的完整时长。
    public var currentPhaseDuration: TimeInterval {
        currentPhaseFullDuration
    }

    /// 指定休息类型对应当前模式的时长。
    public func restDuration(for kind: RestKind) -> TimeInterval {
        if mode == .fourRound, kind == .long {
            return cycleLongRestDuration
        }
        return restDuration
    }

    /// 是否处于活动中的四轮系列。
    public var isSeriesActive: Bool {
        mode == .fourRound
    }

    /// 长休阶段（面板与菜单栏据此使用不同图标和文案）。
    public var isLongRest: Bool {
        phase == .rest && restKind == .long
    }

    static func isValidDuration(_ value: TimeInterval) -> Bool {
        value.isFinite && value > 0
    }

    /// 更新全部时长设置。
    ///
    /// 空闲时立即采用当前模式、当前阶段的新完整时长；运行中或暂停中保持
    /// 当前阶段的剩余时间与原截止时间，新时长从下一次进入对应阶段、
    /// 重置该阶段或开始新周期时生效。
    public mutating func updateDurations(
        normalFocusDuration: TimeInterval,
        normalRestDuration: TimeInterval,
        cycleFocusDuration: TimeInterval,
        cycleShortRestDuration: TimeInterval,
        cycleLongRestDuration: TimeInterval
    ) {
        precondition(
            Self.isValidDuration(normalFocusDuration)
                && Self.isValidDuration(normalRestDuration)
                && Self.isValidDuration(cycleFocusDuration)
                && Self.isValidDuration(cycleShortRestDuration)
                && Self.isValidDuration(cycleLongRestDuration),
            "所有时长必须是正的有限值"
        )
        self.normalFocusDuration = normalFocusDuration
        self.normalRestDuration = normalRestDuration
        self.cycleFocusDuration = cycleFocusDuration
        self.cycleShortRestDuration = cycleShortRestDuration
        self.cycleLongRestDuration = cycleLongRestDuration

        if status == .idle {
            currentPhaseFullDuration = configuredDuration(
                for: phase,
                in: mode,
                restKind: restKind
            )
            storedRemaining = currentPhaseFullDuration
        }
    }

    /// 旧版便捷更新：普通模式和 Focus Cycle 同步采用新的专注与短休时长。
    public mutating func updateDurations(
        focusDuration: TimeInterval,
        restDuration: TimeInterval
    ) {
        let longRest = cycleLongRestDuration
        updateDurations(
            normalFocusDuration: focusDuration,
            normalRestDuration: restDuration,
            cycleFocusDuration: focusDuration,
            cycleShortRestDuration: restDuration,
            cycleLongRestDuration: longRest
        )
    }

    /// 按真实时间计算剩余时长；运行中始终由截止时间点推导，不做累减。
    public func remaining(at now: Date) -> TimeInterval {
        guard status == .running, let deadline else {
            return storedRemaining
        }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// 开始，或在暂停后继续。运行中重复调用不会改变截止时间点。
    public mutating func start(at now: Date) {
        guard status != .running else { return }
        status = .running
        deadline = now.addingTimeInterval(storedRemaining)
    }

    /// 从普通空闲专注一键开始四轮系列的第 1 次专注。
    ///
    /// 已经处于系列中时调用会从头开始新的系列；界面只在普通空闲专注时提供入口。
    public mutating func startFourRounds(at now: Date) {
        mode = .fourRound
        focusRound = 1
        restKind = .short
        phase = .focus
        status = .running
        currentPhaseFullDuration = cycleFocusDuration
        storedRemaining = cycleFocusDuration
        deadline = now.addingTimeInterval(cycleFocusDuration)
    }

    /// 取消四轮系列，立即回到普通模式的空闲专注，轮次归零。
    /// 普通模式下调用不会有任何变化。
    public mutating func cancelFourRounds() {
        guard isSeriesActive else { return }
        finishSeries()
    }

    /// 暂停并冻结剩余时长。
    ///
    /// 如果此刻阶段已经到期，先结算到期转换，不会把新阶段暂停在 0。
    public mutating func pause(at now: Date) {
        guard status == .running else { return }

        let didEndPhase = refresh(at: now)
        guard !didEndPhase, let deadline else { return }

        storedRemaining = max(0, deadline.timeIntervalSince(now))
        self.deadline = nil
        status = .paused
    }

    /// 从暂停时冻结的剩余时长继续。
    public mutating func resume(at now: Date) {
        guard status == .paused else { return }
        start(at: now)
    }

    /// 当前阶段回到空闲，并恢复该阶段的完整时长。
    /// 四轮系列与轮次保持不变，只有 Reset 才采用新的完整时长。
    public mutating func reset() {
        status = .idle
        deadline = nil
        currentPhaseFullDuration = configuredDuration(
            for: phase,
            in: mode,
            restKind: restKind
        )
        storedRemaining = currentPhaseFullDuration
    }

    /// 立即切换到下一阶段。
    ///
    /// 专注中进入该轮应有的休息（第 4 轮之后是长休）；短休中进入并自动开始下一轮专注；
    /// 长休中结束系列。普通模式的规则保持不变。
    public mutating func skip(at now: Date) {
        switch phase {
        case .focus:
            let kind: RestKind = mode == .fourRound
                && focusRound >= Self.focusRoundCount ? .long : .short
            beginRest(kind, at: now)
        case .rest:
            if mode == .fourRound, restKind == .long {
                finishSeries()
            } else if mode == .fourRound {
                beginFocus(round: focusRound + 1, at: now)
            } else {
                phase = .focus
                status = .idle
                deadline = nil
                currentPhaseFullDuration = normalFocusDuration
                storedRemaining = normalFocusDuration
            }
        }
    }

    /// 结算所有已到期的阶段。界面应定期调用。
    ///
    /// 阶段切换从原截止点推算，因此延迟刷新或电脑休眠不会丢失时间。
    /// 若一次刷新跨过多个阶段，会连续结算。返回值表示本次调用是否至少结束了一个阶段。
    @discardableResult
    public mutating func refresh(at now: Date) -> Bool {
        var didEndPhase = false

        while status == .running, let deadline, now >= deadline {
            didEndPhase = true

            switch phase {
            case .focus:
                let kind: RestKind = mode == .fourRound
                    && focusRound >= Self.focusRoundCount ? .long : .short
                restKind = kind
                phase = .rest
                let duration = restDuration(for: kind)
                currentPhaseFullDuration = duration
                let restDeadline = deadline.addingTimeInterval(duration)
                self.deadline = restDeadline
                storedRemaining = max(0, restDeadline.timeIntervalSince(now))
            case .rest:
                if mode == .fourRound, restKind == .long {
                    // 长休结束：系列结束，回到普通模式的空闲专注。
                    finishSeries()
                } else if mode == .fourRound {
                    focusRound += 1
                    restKind = .short
                    phase = .focus
                    currentPhaseFullDuration = cycleFocusDuration
                    let focusDeadline = deadline.addingTimeInterval(cycleFocusDuration)
                    self.deadline = focusDeadline
                    storedRemaining = max(0, focusDeadline.timeIntervalSince(now))
                } else {
                    phase = .focus
                    status = .idle
                    self.deadline = nil
                    currentPhaseFullDuration = normalFocusDuration
                    storedRemaining = normalFocusDuration
                }
            }
        }

        return didEndPhase
    }

    // MARK: - 内部转换

    private func configuredDuration(
        for phase: Phase,
        in mode: Mode,
        restKind: RestKind
    ) -> TimeInterval {
        switch (mode, phase) {
        case (.single, .focus):
            return normalFocusDuration
        case (.single, .rest):
            return normalRestDuration
        case (.fourRound, .focus):
            return cycleFocusDuration
        case (.fourRound, .rest):
            return restKind == .long ? cycleLongRestDuration : cycleShortRestDuration
        }
    }

    private mutating func beginRest(_ kind: RestKind, at now: Date) {
        restKind = kind
        phase = .rest
        status = .running
        let duration = restDuration(for: kind)
        currentPhaseFullDuration = duration
        storedRemaining = duration
        deadline = now.addingTimeInterval(duration)
    }

    private mutating func beginFocus(round: Int, at now: Date) {
        focusRound = min(round, Self.focusRoundCount)
        restKind = .short
        phase = .focus
        status = .running
        let duration = mode == .fourRound ? cycleFocusDuration : normalFocusDuration
        currentPhaseFullDuration = duration
        storedRemaining = duration
        deadline = now.addingTimeInterval(duration)
    }

    /// 结束系列：回到普通模式的空闲专注，轮次归零。
    private mutating func finishSeries() {
        mode = .single
        focusRound = 1
        restKind = .short
        phase = .focus
        status = .idle
        deadline = nil
        currentPhaseFullDuration = normalFocusDuration
        storedRemaining = normalFocusDuration
    }
}

extension StandUpTimer {
    /// 从快照恢复。
    ///
    /// 版本不受支持、数值非有限或自相矛盾（运行中缺截止时间、非运行却带截止时间、
    /// 普通模式却停在后续轮次或长休）时返回 nil，调用方据此回到默认空闲状态。
    public init?(snapshot: StandUpTimerSnapshot) {
        guard StandUpTimerSnapshot.isSupported(version: snapshot.version),
              Self.isValidDuration(snapshot.normalFocusDuration),
              Self.isValidDuration(snapshot.normalRestDuration),
              Self.isValidDuration(snapshot.cycleFocusDuration),
              Self.isValidDuration(snapshot.cycleShortRestDuration),
              Self.isValidDuration(snapshot.cycleLongRestDuration),
              Self.isValidDuration(snapshot.currentPhaseDuration),
              snapshot.remaining.isFinite,
              snapshot.remaining >= 0,
              (1...Self.focusRoundCount).contains(snapshot.focusRound)
        else {
            return nil
        }

        // 普通模式只可能是第 1 轮、短休；其他组合属于损坏数据。
        if snapshot.mode == .single,
           snapshot.focusRound != 1 || snapshot.restKind != .short {
            return nil
        }

        switch snapshot.status {
        case .running:
            guard let deadline = snapshot.deadline,
                  deadline.timeIntervalSinceReferenceDate.isFinite
            else {
                return nil
            }
            self.init(
                normalFocusDuration: snapshot.normalFocusDuration,
                normalRestDuration: snapshot.normalRestDuration,
                cycleFocusDuration: snapshot.cycleFocusDuration,
                cycleShortRestDuration: snapshot.cycleShortRestDuration,
                cycleLongRestDuration: snapshot.cycleLongRestDuration
            )
            self.applyIdentity(of: snapshot)
            self.currentPhaseFullDuration = snapshot.currentPhaseDuration
            self.status = .running
            self.deadline = deadline
            // 运行中的剩余时间由截止时间推导，这个值只是占位。
            self.storedRemaining = min(snapshot.remaining, currentPhaseFullDuration)

        case .paused:
            guard snapshot.deadline == nil else { return nil }
            self.init(
                normalFocusDuration: snapshot.normalFocusDuration,
                normalRestDuration: snapshot.normalRestDuration,
                cycleFocusDuration: snapshot.cycleFocusDuration,
                cycleShortRestDuration: snapshot.cycleShortRestDuration,
                cycleLongRestDuration: snapshot.cycleLongRestDuration
            )
            self.applyIdentity(of: snapshot)
            self.currentPhaseFullDuration = snapshot.currentPhaseDuration
            self.status = .paused
            self.deadline = nil
            // 暂停状态必须原样保留冻结的剩余时间。即使用户在暂停期间调短了
            // 阶段时长（重启后设置会先于快照生效），剩余时间也不能跳变；
            // 只有 Reset 才采用新的完整时长。
            self.storedRemaining = snapshot.remaining

        case .idle:
            guard snapshot.deadline == nil else { return nil }
            self.init(
                normalFocusDuration: snapshot.normalFocusDuration,
                normalRestDuration: snapshot.normalRestDuration,
                cycleFocusDuration: snapshot.cycleFocusDuration,
                cycleShortRestDuration: snapshot.cycleShortRestDuration,
                cycleLongRestDuration: snapshot.cycleLongRestDuration
            )
            self.applyIdentity(of: snapshot)
            self.currentPhaseFullDuration = snapshot.currentPhaseDuration
            self.status = .idle
            self.deadline = nil
            self.storedRemaining = min(
                snapshot.remaining,
                currentPhaseFullDuration
            )
        }
    }

    private mutating func applyIdentity(of snapshot: StandUpTimerSnapshot) {
        phase = snapshot.phase
        mode = snapshot.mode
        focusRound = snapshot.focusRound
        // 专注阶段的休息类型只是下一次休息的占位，由轮次决定。
        restKind = snapshot.phase == .rest ? snapshot.restKind : .short
    }

    /// 快照当前状态。
    /// 运行中保存绝对截止时间；空闲或暂停保存冻结的剩余时间。
    public func snapshot(at now: Date) -> StandUpTimerSnapshot {
        StandUpTimerSnapshot(
            phase: phase,
            status: status,
            deadline: status == .running ? deadline : nil,
            remaining: remaining(at: now),
            focusDuration: focusDuration,
            restDuration: restDuration,
            mode: mode,
            focusRound: focusRound,
            restKind: restKind,
            longRestDuration: cycleLongRestDuration,
            normalFocusDuration: normalFocusDuration,
            normalRestDuration: normalRestDuration,
            cycleFocusDuration: cycleFocusDuration,
            cycleShortRestDuration: cycleShortRestDuration,
            cycleLongRestDuration: cycleLongRestDuration,
            currentPhaseDuration: currentPhaseFullDuration
        )
    }
}
