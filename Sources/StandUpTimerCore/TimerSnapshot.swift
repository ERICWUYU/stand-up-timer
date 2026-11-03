import Foundation

/// 可持久化的计时状态快照，带版本号以便迁移。
///
/// 这是“计时状态”唯一的事实来源；散落的多个键不允许各自代表一部分状态。
public struct StandUpTimerSnapshot: Codable, Equatable, Sendable {
    /// 当前数据结构版本。
    /// 版本 2 增加四轮连续模式；版本 3 增加普通模式与 Focus Cycle 的独立时长，
    /// 以及当前阶段实际采用的完整时长。
    public static let currentVersion = 3
    /// 版本 1（阶段 4）没有四轮字段，读取时迁移为普通单轮模式。
    public static let minimumSupportedVersion = 1

    public static func isSupported(version: Int) -> Bool {
        (minimumSupportedVersion...currentVersion).contains(version)
    }

    public let version: Int
    public let phase: StandUpTimer.Phase
    public let status: StandUpTimer.Status
    /// 运行中才有绝对截止时间；空闲或暂停时为 nil。
    public let deadline: Date?
    /// 运行中为快照时刻的剩余秒数；空闲或暂停为冻结的剩余秒数。
    public let remaining: TimeInterval
    /// 当前模式下的专注/短休时长（保留给旧调用方与旧快照）。
    public let focusDuration: TimeInterval
    public let restDuration: TimeInterval
    /// 计时模式：普通单轮或四轮连续。
    public let mode: StandUpTimer.Mode
    /// 当前专注轮次，1...4。
    public let focusRound: Int
    /// 当前休息类型（专注阶段为下一次休息的占位）。
    public let restKind: StandUpTimer.RestKind
    /// Focus Cycle 的长休时长。
    public let longRestDuration: TimeInterval

    /// 普通计时器的独立时长。
    public let normalFocusDuration: TimeInterval
    public let normalRestDuration: TimeInterval
    /// Focus Cycle 的独立时长。
    public let cycleFocusDuration: TimeInterval
    public let cycleShortRestDuration: TimeInterval
    public let cycleLongRestDuration: TimeInterval
    /// 当前阶段开始时实际采用的完整时长；运行中修改设置不会改变它。
    public let currentPhaseDuration: TimeInterval

    public init(
        version: Int = StandUpTimerSnapshot.currentVersion,
        phase: StandUpTimer.Phase,
        status: StandUpTimer.Status,
        deadline: Date?,
        remaining: TimeInterval,
        focusDuration: TimeInterval,
        restDuration: TimeInterval,
        mode: StandUpTimer.Mode = .single,
        focusRound: Int = 1,
        restKind: StandUpTimer.RestKind = .short,
        longRestDuration: TimeInterval = StandUpTimer.defaultLongRestDuration,
        normalFocusDuration: TimeInterval? = nil,
        normalRestDuration: TimeInterval? = nil,
        cycleFocusDuration: TimeInterval? = nil,
        cycleShortRestDuration: TimeInterval? = nil,
        cycleLongRestDuration: TimeInterval? = nil,
        currentPhaseDuration: TimeInterval? = nil
    ) {
        self.version = version
        self.phase = phase
        self.status = status
        self.deadline = deadline
        self.remaining = remaining
        self.focusDuration = focusDuration
        self.restDuration = restDuration
        self.mode = mode
        self.focusRound = focusRound
        self.restKind = restKind
        self.longRestDuration = longRestDuration

        let resolvedNormalFocus = normalFocusDuration ?? focusDuration
        let resolvedNormalRest = normalRestDuration ?? restDuration
        let resolvedCycleFocus = cycleFocusDuration ?? focusDuration
        let resolvedCycleShort = cycleShortRestDuration ?? restDuration
        let resolvedCycleLong = cycleLongRestDuration ?? longRestDuration

        self.normalFocusDuration = resolvedNormalFocus
        self.normalRestDuration = resolvedNormalRest
        self.cycleFocusDuration = resolvedCycleFocus
        self.cycleShortRestDuration = resolvedCycleShort
        self.cycleLongRestDuration = resolvedCycleLong
        self.currentPhaseDuration = currentPhaseDuration ?? Self.phaseDuration(
            mode: mode,
            phase: phase,
            restKind: restKind,
            normalFocus: resolvedNormalFocus,
            normalRest: resolvedNormalRest,
            cycleFocus: resolvedCycleFocus,
            cycleShort: resolvedCycleShort,
            cycleLong: resolvedCycleLong
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case phase
        case status
        case deadline
        case remaining
        case focusDuration
        case restDuration
        case mode
        case focusRound
        case restKind
        case longRestDuration
        case normalFocusDuration
        case normalRestDuration
        case cycleFocusDuration
        case cycleShortRestDuration
        case cycleLongRestDuration
        case currentPhaseDuration
    }

    /// 旧版本缺少的字段用兼容值补齐，避免升级时丢失正在进行的计时。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMode = try container.decodeIfPresent(
            StandUpTimer.Mode.self,
            forKey: .mode
        ) ?? .single
        let decodedRound = try container.decodeIfPresent(
            Int.self,
            forKey: .focusRound
        ) ?? 1
        let decodedRestKind = try container.decodeIfPresent(
            StandUpTimer.RestKind.self,
            forKey: .restKind
        ) ?? .short
        let decodedFocus = try container.decode(
            TimeInterval.self,
            forKey: .focusDuration
        )
        let decodedRest = try container.decode(
            TimeInterval.self,
            forKey: .restDuration
        )
        let decodedLongRest = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .longRestDuration
        ) ?? StandUpTimer.defaultLongRestDuration

        let decodedNormalFocus = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .normalFocusDuration
        ) ?? decodedFocus
        let decodedNormalRest = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .normalRestDuration
        ) ?? decodedRest
        let decodedCycleFocus = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .cycleFocusDuration
        ) ?? decodedFocus
        let decodedCycleShort = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .cycleShortRestDuration
        ) ?? decodedRest
        let decodedCycleLong = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .cycleLongRestDuration
        ) ?? decodedLongRest

        self.version = try container.decode(Int.self, forKey: .version)
        self.phase = try container.decode(StandUpTimer.Phase.self, forKey: .phase)
        self.status = try container.decode(StandUpTimer.Status.self, forKey: .status)
        self.deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        self.remaining = try container.decode(TimeInterval.self, forKey: .remaining)
        self.focusDuration = decodedFocus
        self.restDuration = decodedRest
        self.mode = decodedMode
        self.focusRound = decodedRound
        self.restKind = decodedRestKind
        self.longRestDuration = decodedLongRest
        self.normalFocusDuration = decodedNormalFocus
        self.normalRestDuration = decodedNormalRest
        self.cycleFocusDuration = decodedCycleFocus
        self.cycleShortRestDuration = decodedCycleShort
        self.cycleLongRestDuration = decodedCycleLong
        self.currentPhaseDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .currentPhaseDuration
        ) ?? Self.phaseDuration(
            mode: decodedMode,
            phase: phase,
            restKind: decodedRestKind,
            normalFocus: decodedNormalFocus,
            normalRest: decodedNormalRest,
            cycleFocus: decodedCycleFocus,
            cycleShort: decodedCycleShort,
            cycleLong: decodedCycleLong
        )
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// 解码并校验。损坏、未知版本或自相矛盾的数据一律返回 nil。
    public static func decode(from data: Data) -> StandUpTimerSnapshot? {
        guard
            let snapshot = try? JSONDecoder().decode(
                StandUpTimerSnapshot.self,
                from: data
            ),
            isSupported(version: snapshot.version),
            StandUpTimer(snapshot: snapshot) != nil
        else {
            return nil
        }
        return snapshot
    }

    private static func phaseDuration(
        mode: StandUpTimer.Mode,
        phase: StandUpTimer.Phase,
        restKind: StandUpTimer.RestKind,
        normalFocus: TimeInterval,
        normalRest: TimeInterval,
        cycleFocus: TimeInterval,
        cycleShort: TimeInterval,
        cycleLong: TimeInterval
    ) -> TimeInterval {
        switch (mode, phase) {
        case (.single, .focus):
            return normalFocus
        case (.single, .rest):
            return normalRest
        case (.fourRound, .focus):
            return cycleFocus
        case (.fourRound, .rest):
            return restKind == .long ? cycleLong : cycleShort
        }
    }
}
