import Foundation

/// 可持久化的计时状态快照，带版本号以便迁移。
///
/// 这是“计时状态”唯一的事实来源；散落的多个键不允许各自代表一部分状态。
public struct StandUpTimerSnapshot: Codable, Equatable, Sendable {
    /// 当前数据结构版本。版本 2 增加四轮连续模式、轮次、休息类型和长休时长。
    public static let currentVersion = 2
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
    /// 该状态所依据的专注/休息时长。
    public let focusDuration: TimeInterval
    public let restDuration: TimeInterval
    /// 计时模式：普通单轮或四轮连续。
    public let mode: StandUpTimer.Mode
    /// 当前专注轮次，1...4。
    public let focusRound: Int
    /// 当前休息类型（专注阶段为下一次休息的占位）。
    public let restKind: StandUpTimer.RestKind
    /// 该状态所依据的长休时长。
    public let longRestDuration: TimeInterval

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
        longRestDuration: TimeInterval = StandUpTimer.defaultLongRestDuration
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
    }

    /// 版本 1 的数据缺少四轮字段，用默认值补齐，避免升级时丢失正在进行的计时。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        phase = try container.decode(StandUpTimer.Phase.self, forKey: .phase)
        status = try container.decode(StandUpTimer.Status.self, forKey: .status)
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        remaining = try container.decode(TimeInterval.self, forKey: .remaining)
        focusDuration = try container.decode(TimeInterval.self, forKey: .focusDuration)
        restDuration = try container.decode(TimeInterval.self, forKey: .restDuration)
        mode = try container.decodeIfPresent(
            StandUpTimer.Mode.self,
            forKey: .mode
        ) ?? .single
        focusRound = try container.decodeIfPresent(Int.self, forKey: .focusRound) ?? 1
        restKind = try container.decodeIfPresent(
            StandUpTimer.RestKind.self,
            forKey: .restKind
        ) ?? .short
        longRestDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .longRestDuration
        ) ?? StandUpTimer.defaultLongRestDuration
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
}
