import Foundation

/// 一次“自然到期”的阶段转换，由纯计时核心在结算时生成。
///
/// 与用户主动 Skip/Reset/Cancel 不同，转换只描述因截止时间到达而结束的阶段。
/// 一次延迟刷新跨过多个阶段时，会按时间顺序生成多个转换，中间阶段不会丢失。
/// 所有字段都来自转换发生前的计时状态，因此对同一份快照重复结算会得到
/// 完全相同的值，可据此构造幂等的历史记录键。
public struct PhaseTransition: Equatable, Sendable {
    /// 自然结束的阶段。
    public let phase: StandUpTimer.Phase
    /// 结束时所处的模式（长休结束、系列复位之前捕获，仍为 fourRound）。
    public let mode: StandUpTimer.Mode
    /// 结束时的专注轮次 1...4；普通模式恒为 1。
    public let focusRound: Int
    /// 结束阶段的休息类型。
    ///
    /// - rest 阶段：实际的 short/long；
    /// - focus 阶段：计时器在专注期间只保存占位值 `.short`，该字段对专注
    ///   记录无业务含义，后续休息自身的记录会携带真实类型。
    public let restKind: StandUpTimer.RestKind
    /// 该阶段计划中的完成时刻（绝对截止时间），不是刷新实际发生的时刻。
    /// 离线追赶时多条记录都使用各自的计划截止点，而非重启时间。
    public let scheduledCompletion: Date
    /// 该阶段开始时实际采用的完整计划时长。
    public let plannedDuration: TimeInterval

    public init(
        phase: StandUpTimer.Phase,
        mode: StandUpTimer.Mode,
        focusRound: Int,
        restKind: StandUpTimer.RestKind,
        scheduledCompletion: Date,
        plannedDuration: TimeInterval
    ) {
        self.phase = phase
        self.mode = mode
        self.focusRound = focusRound
        self.restKind = restKind
        self.scheduledCompletion = scheduledCompletion
        self.plannedDuration = plannedDuration
    }
}
