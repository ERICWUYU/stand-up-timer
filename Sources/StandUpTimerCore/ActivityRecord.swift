import Foundation

/// 一条长期保存的本地活动历史记录（计时器历史，不涉及屏幕/应用使用追踪）。
///
/// 版本化、可 Codable，字段全部是稳定值类型。`id` 是由稳定字段确定性派生的
/// 幂等键：对同一份快照重复结算、或中断后重放同一批转换，生成的 id 完全一致，
/// 存储层据此去重。禁止使用 Swift `Hasher`，它在不同进程间刻意不保证稳定。
///
/// 解码时执行完整校验（schema 版本、语义字段、时长、幂等 id），
/// 任何一项不合法都抛 `ActivityHistoryError.invalidRecord`，坏数据无法进入
/// 聚合或去重流程，也不会被就地“修复”。
public struct ActivityRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// 阶段到达计划截止点，自然完成。
        case completed
        /// 用户在阶段运行/暂停时主动跳过。
        case skipped
        /// 用户 Reset 或取消 Focus Cycle，中断了已开始的阶段。
        case cancelled
    }

    /// 历史记录结构版本，独立于计时快照版本演进。
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// 确定性幂等键，见 `makeID(...)`。
    public let id: String
    /// 结果发生时刻：自然完成使用计划截止点；显式操作使用注入的操作时间。
    public let date: Date
    public let phase: StandUpTimer.Phase
    public let mode: StandUpTimer.Mode
    public let focusRound: Int
    public let restKind: StandUpTimer.RestKind
    public let outcome: Outcome
    /// 阶段开始时采用的完整计划时长。
    public let plannedDuration: TimeInterval
    /// 实际计入的活动时长（暂停的墙上时间不计入）。
    public let activeDuration: TimeInterval

    public init(
        date: Date,
        phase: StandUpTimer.Phase,
        mode: StandUpTimer.Mode,
        focusRound: Int,
        restKind: StandUpTimer.RestKind,
        outcome: Outcome,
        plannedDuration: TimeInterval,
        activeDuration: TimeInterval,
        schemaVersion: Int = ActivityRecord.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = Self.makeID(
            date: date,
            phase: phase,
            mode: mode,
            focusRound: focusRound,
            restKind: restKind,
            outcome: outcome
        )
        self.date = date
        self.phase = phase
        self.mode = mode
        self.focusRound = focusRound
        self.restKind = restKind
        self.outcome = outcome
        self.plannedDuration = plannedDuration
        self.activeDuration = activeDuration
    }

    /// 由稳定字段拼接的规范键。
    ///
    /// - `Date` 取 `timeIntervalSinceReferenceDate` 的规范字符串形式
    ///   （Double 的最短往返表示，跨进程稳定）；
    /// - 枚举全部使用受控 rawValue，不含分隔符 `|`；
    /// - 前缀带结构版本，outcome 参与键值，自然完成与同一时刻的显式操作
    ///   不会互相覆盖。
    public static func makeID(
        date: Date,
        phase: StandUpTimer.Phase,
        mode: StandUpTimer.Mode,
        focusRound: Int,
        restKind: StandUpTimer.RestKind,
        outcome: Outcome
    ) -> String {
        [
            "v\(currentSchemaVersion)",
            outcome.rawValue,
            mode.rawValue,
            phase.rawValue,
            String(focusRound),
            restKind.rawValue,
            String(date.timeIntervalSinceReferenceDate)
        ].joined(separator: "|")
    }

    /// 从自然到期转换构造 completed 记录：
    /// 日期取计划截止点，活动时长等于计划时长。
    public static func completed(from transition: PhaseTransition) -> ActivityRecord {
        ActivityRecord(
            date: transition.scheduledCompletion,
            phase: transition.phase,
            mode: transition.mode,
            focusRound: transition.focusRound,
            restKind: transition.restKind,
            outcome: .completed,
            plannedDuration: transition.plannedDuration,
            activeDuration: transition.plannedDuration
        )
    }

    // MARK: - 受校验的解码

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case date
        case phase
        case mode
        case focusRound
        case restKind
        case outcome
        case plannedDuration
        case activeDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let id = try container.decode(String.self, forKey: .id)
        let date = try container.decode(Date.self, forKey: .date)
        let phase = try container.decode(StandUpTimer.Phase.self, forKey: .phase)
        let mode = try container.decode(StandUpTimer.Mode.self, forKey: .mode)
        let focusRound = try container.decode(Int.self, forKey: .focusRound)
        let restKind = try container.decode(StandUpTimer.RestKind.self, forKey: .restKind)
        let outcome = try container.decode(Outcome.self, forKey: .outcome)
        let plannedDuration = try container.decode(TimeInterval.self, forKey: .plannedDuration)
        let activeDuration = try container.decode(TimeInterval.self, forKey: .activeDuration)

        try Self.validate(
            schemaVersion: schemaVersion,
            id: id,
            date: date,
            phase: phase,
            mode: mode,
            focusRound: focusRound,
            restKind: restKind,
            outcome: outcome,
            plannedDuration: plannedDuration,
            activeDuration: activeDuration
        )

        self.schemaVersion = schemaVersion
        self.id = id
        self.date = date
        self.phase = phase
        self.mode = mode
        self.focusRound = focusRound
        self.restKind = restKind
        self.outcome = outcome
        self.plannedDuration = plannedDuration
        self.activeDuration = activeDuration
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(phase, forKey: .phase)
        try container.encode(mode, forKey: .mode)
        try container.encode(focusRound, forKey: .focusRound)
        try container.encode(restKind, forKey: .restKind)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(plannedDuration, forKey: .plannedDuration)
        try container.encode(activeDuration, forKey: .activeDuration)
    }

    /// 记录校验的唯一实现，编码与解码共用，避免两套规则漂移。纯函数、无 I/O。
    ///
    /// 规则：
    /// - 只接受当前 `schemaVersion`，未知版本拒绝；
    /// - `focusRound` 必须在 1...4；
    /// - 普通模式只能是第 1 轮且不允许长休状态；专注阶段的休息类型只能是占位 `.short`；
    /// - Focus Cycle 的休息阶段：第 4 轮必须是长休，第 1...3 轮必须是短休；
    /// - 计划时长有限且为正；活动时长有限、非负且不超过计划时长；
    /// - completed 必须活动时长等于计划时长；cancelled 必须有正活动时长；
    /// - 由稳定字段重算规范 id，必须与存储 id 完全一致（防篡改、防错位）。
    static func validate(
        schemaVersion: Int,
        id: String,
        date: Date,
        phase: StandUpTimer.Phase,
        mode: StandUpTimer.Mode,
        focusRound: Int,
        restKind: StandUpTimer.RestKind,
        outcome: Outcome,
        plannedDuration: TimeInterval,
        activeDuration: TimeInterval
    ) throws {
        guard schemaVersion == currentSchemaVersion else {
            throw ActivityHistoryError.invalidRecord(
                reason: "不支持的记录 schemaVersion：\(schemaVersion)"
            )
        }

        guard (1...StandUpTimer.focusRoundCount).contains(focusRound) else {
            throw ActivityHistoryError.invalidRecord(
                reason: "focusRound 越界：\(focusRound)"
            )
        }

        if mode == .single {
            guard focusRound == 1 else {
                throw ActivityHistoryError.invalidRecord(reason: "普通模式轮次必须为 1")
            }
            guard restKind != .long else {
                throw ActivityHistoryError.invalidRecord(reason: "普通模式不允许长休状态")
            }
        }

        if phase == .focus, restKind != .short {
            throw ActivityHistoryError.invalidRecord(reason: "专注阶段的休息类型只能是 .short 占位值")
        }

        if mode == .fourRound, phase == .rest {
            if focusRound == StandUpTimer.focusRoundCount {
                guard restKind == .long else {
                    throw ActivityHistoryError.invalidRecord(
                        reason: "Focus Cycle 第 \(StandUpTimer.focusRoundCount) 轮休息必须是长休"
                    )
                }
            } else {
                guard restKind == .short else {
                    throw ActivityHistoryError.invalidRecord(
                        reason: "Focus Cycle 第 1...\(StandUpTimer.focusRoundCount - 1) 轮休息必须是短休"
                    )
                }
            }
        }

        guard plannedDuration.isFinite, plannedDuration > 0 else {
            throw ActivityHistoryError.invalidRecord(reason: "计划时长必须为正的有限值")
        }

        guard activeDuration.isFinite,
              activeDuration >= 0,
              activeDuration <= plannedDuration else {
            throw ActivityHistoryError.invalidRecord(reason: "活动时长必须有限、非负且不超过计划时长")
        }

        switch outcome {
        case .completed:
            guard activeDuration == plannedDuration else {
                throw ActivityHistoryError.invalidRecord(
                    reason: "completed 记录的活动时长必须等于计划时长"
                )
            }
        case .cancelled:
            guard activeDuration > 0 else {
                throw ActivityHistoryError.invalidRecord(reason: "cancelled 记录必须有正活动时长")
            }
        case .skipped:
            break
        }

        let expectedID = makeID(
            date: date,
            phase: phase,
            mode: mode,
            focusRound: focusRound,
            restKind: restKind,
            outcome: outcome
        )
        guard expectedID == id else {
            throw ActivityHistoryError.invalidRecord(reason: "存储 id 与稳定字段重算结果不一致")
        }
    }

    /// 对内存中的整条记录执行同一套校验，供写入侧在生成 JSON 之前拦截非法记录。
    static func validate(_ record: ActivityRecord) throws {
        try validate(
            schemaVersion: record.schemaVersion,
            id: record.id,
            date: record.date,
            phase: record.phase,
            mode: record.mode,
            focusRound: record.focusRound,
            restKind: record.restKind,
            outcome: record.outcome,
            plannedDuration: record.plannedDuration,
            activeDuration: record.activeDuration
        )
    }
}
