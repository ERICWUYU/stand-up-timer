import Foundation

/// 一条未来提醒：由纯逻辑算出绝对触发时间，通知框架只负责写入系统。
public struct ReminderEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 某次专注结束，`round` 为 1...4。
        case focusEnd(round: Int)
        /// 某次休息结束，长休结束意味着系列结束。
        case restEnd(kind: StandUpTimer.RestKind)
    }

    public let kind: Kind
    public let fireDate: Date

    public init(kind: Kind, fireDate: Date) {
        self.kind = kind
        self.fireDate = fireDate
    }
}

/// 计算尚未发生的提醒时间线。
///
/// 整条未来序列一次性算完并全部按绝对时间点生成，因此通知中心逐条写入的等待时间
/// 不会把后面的提醒整体推后；也保证暂停、跳过或修改设置时只需整条替换，
/// 不会残留旧系列的幽灵提醒。
public enum ReminderTimeline {
    /// 只计算尚未过期的提醒；非运行状态没有任何提醒。
    public static func events(
        for timer: StandUpTimer,
        now: Date
    ) -> [ReminderEvent] {
        guard timer.status == .running else { return [] }

        var events: [ReminderEvent] = []
        var phase = timer.phase
        var round = timer.focusRound
        var restKind = timer.restKind
        var deadline = now.addingTimeInterval(timer.remaining(at: now))
        var index = 0

        func append(_ kind: ReminderEvent.Kind, at date: Date) {
            events.append(ReminderEvent(kind: kind, fireDate: date))
        }

        if timer.mode == .single {
            // 普通模式与阶段 4 保持一致：当前阶段结束 + 紧随其后的休息结束。
            if phase == .focus {
                append(.focusEnd(round: round), at: deadline)
                append(
                    .restEnd(kind: .short),
                    at: deadline.addingTimeInterval(timer.restDuration)
                )
            } else {
                append(.restEnd(kind: .short), at: deadline)
            }
            return events
        }

        // 四轮连续：从当前阶段一直排到长休结束。上限只是防御，正常远达不到。
        let maximumEvents = StandUpTimer.focusRoundCount * 2
        while index < maximumEvents {
            index += 1
            if phase == .focus {
                append(.focusEnd(round: round), at: deadline)
                restKind = round >= StandUpTimer.focusRoundCount ? .long : .short
                deadline = deadline.addingTimeInterval(
                    timer.restDuration(for: restKind)
                )
                append(.restEnd(kind: restKind), at: deadline)
                if restKind == .long {
                    break
                }
                round = min(round + 1, StandUpTimer.focusRoundCount)
                deadline = deadline.addingTimeInterval(timer.focusDuration)
                phase = .focus
            } else {
                append(.restEnd(kind: restKind), at: deadline)
                if restKind == .long {
                    break
                }
                round = min(round + 1, StandUpTimer.focusRoundCount)
                deadline = deadline.addingTimeInterval(timer.focusDuration)
                phase = .focus
            }
        }

        return events
    }
}
