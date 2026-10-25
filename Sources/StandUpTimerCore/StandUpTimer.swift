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
    /// 四轮连续是用户选择的产品节奏：4 次专注与短休交替，最后以 15 分钟长休结束。
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
    /// 四轮连续模式中长休的固定时长；不提供单独设置。
    public static let defaultLongRestDuration: TimeInterval = 15 * 60

    public private(set) var focusDuration: TimeInterval
    public private(set) var restDuration: TimeInterval
    public private(set) var longRestDuration: TimeInterval

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

    public init(
        focusDuration: TimeInterval = 25 * 60,
        restDuration: TimeInterval = 5 * 60,
        longRestDuration: TimeInterval = StandUpTimer.defaultLongRestDuration
    ) {
        precondition(
            Self.isValidDuration(focusDuration)
                && Self.isValidDuration(restDuration)
                && Self.isValidDuration(longRestDuration),
            "focusDuration、restDuration 和 longRestDuration 必须是正的有限值"
        )
        self.focusDuration = focusDuration
        self.restDuration = restDuration
        self.longRestDuration = longRestDuration
        self.mode = .single
        self.focusRound = 1
        self.restKind = .short
        self.phase = .focus
        self.status = .idle
        self.storedRemaining = focusDuration
    }

    /// 当前阶段的完整时长。
    public var currentPhaseDuration: TimeInterval {
        phase == .focus ? focusDuration : restDuration(for: restKind)
    }

    /// 指定休息类型对应的时长。
    public func restDuration(for kind: RestKind) -> TimeInterval {
        kind == .long ? longRestDuration : restDuration
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

    /// 更新时长设置。
    ///
    /// 空闲时立即采用当前阶段新的完整时长；运行中或暂停中保持当前阶段的剩余时间
    /// 与原截止时间，新时长从下一次进入对应阶段、重置该阶段或开始新周期时生效。
    public mutating func updateDurations(
        focusDuration: TimeInterval,
        restDuration: TimeInterval
    ) {
        precondition(
            Self.isValidDuration(focusDuration) && Self.isValidDuration(restDuration),
            "focusDuration 和 restDuration 必须是正的有限值"
        )
        self.focusDuration = focusDuration
        self.restDuration = restDuration

        if status == .idle {
            storedRemaining = currentPhaseDuration
        }
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
        storedRemaining = focusDuration
        deadline = now.addingTimeInterval(focusDuration)
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
        storedRemaining = currentPhaseDuration
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
                storedRemaining = focusDuration
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
                let restDeadline = deadline.addingTimeInterval(
                    restDuration(for: kind)
                )
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
                    let focusDeadline = deadline.addingTimeInterval(focusDuration)
                    self.deadline = focusDeadline
                    storedRemaining = max(0, focusDeadline.timeIntervalSince(now))
                } else {
                    phase = .focus
                    status = .idle
                    self.deadline = nil
                    storedRemaining = focusDuration
                }
            }
        }

        return didEndPhase
    }

    // MARK: - 内部转换

    private mutating func beginRest(_ kind: RestKind, at now: Date) {
        restKind = kind
        phase = .rest
        status = .running
        let duration = restDuration(for: kind)
        storedRemaining = duration
        deadline = now.addingTimeInterval(duration)
    }

    private mutating func beginFocus(round: Int, at now: Date) {
        focusRound = min(round, Self.focusRoundCount)
        restKind = .short
        phase = .focus
        status = .running
        storedRemaining = focusDuration
        deadline = now.addingTimeInterval(focusDuration)
    }

    /// 结束系列：回到普通模式的空闲专注，轮次归零。
    private mutating func finishSeries() {
        mode = .single
        focusRound = 1
        restKind = .short
        phase = .focus
        status = .idle
        deadline = nil
        storedRemaining = focusDuration
    }
}

extension StandUpTimer {
    /// 从快照恢复。
    ///
    /// 版本不受支持、数值非有限或自相矛盾（运行中缺截止时间、非运行却带截止时间、
    /// 普通模式却停在后续轮次或长休）时返回 nil，调用方据此回到默认空闲状态。
    public init?(snapshot: StandUpTimerSnapshot) {
        guard StandUpTimerSnapshot.isSupported(version: snapshot.version),
              Self.isValidDuration(snapshot.focusDuration),
              Self.isValidDuration(snapshot.restDuration),
              Self.isValidDuration(snapshot.longRestDuration),
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
                focusDuration: snapshot.focusDuration,
                restDuration: snapshot.restDuration,
                longRestDuration: snapshot.longRestDuration
            )
            self.applyIdentity(of: snapshot)
            self.status = .running
            self.deadline = deadline
            // 运行中的剩余时间由截止时间推导，这个值只是占位。
            self.storedRemaining = min(snapshot.remaining, currentPhaseDuration)

        case .paused:
            guard snapshot.deadline == nil else { return nil }
            self.init(
                focusDuration: snapshot.focusDuration,
                restDuration: snapshot.restDuration,
                longRestDuration: snapshot.longRestDuration
            )
            self.applyIdentity(of: snapshot)
            self.status = .paused
            self.deadline = nil
            // 暂停状态必须原样保留冻结的剩余时间。即使用户在暂停期间调短了
            // 阶段时长（重启后设置会先于快照生效），剩余时间也不能跳变；
            // 只有 Reset 才采用新的完整时长。
            self.storedRemaining = snapshot.remaining

        case .idle:
            guard snapshot.deadline == nil else { return nil }
            self.init(
                focusDuration: snapshot.focusDuration,
                restDuration: snapshot.restDuration,
                longRestDuration: snapshot.longRestDuration
            )
            self.applyIdentity(of: snapshot)
            self.status = .idle
            self.deadline = nil
            self.storedRemaining = min(snapshot.remaining, currentPhaseDuration)
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
            longRestDuration: longRestDuration
        )
    }
}
