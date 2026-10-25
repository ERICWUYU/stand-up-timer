/// 用户可以选择的提醒声音。
///
/// 只使用 macOS 自带的提示音：`UNNotificationSound(named:)` 在这台系统上
/// 只会解析系统提示音（/System/Library/Sounds），放进 app bundle 的自定义
/// WAV 会被忽略并退回默认提示音，导致所有选项听起来都一样。
public enum NotificationSound: String, CaseIterable, Identifiable, Sendable {
    case glass
    case ping
    case pop
    case hero
    case sosumi
    case submarine
    case tink
    case funk

    public var id: String { rawValue }

    /// 显示名称随界面语言切换；英文名使用 Apple 的系统提示音原名。
    public var displayNameKey: String {
        "sound.\(rawValue)"
    }

    public var fileName: String {
        switch self {
        case .glass: return "Glass.aiff"
        case .ping: return "Ping.aiff"
        case .pop: return "Pop.aiff"
        case .hero: return "Hero.aiff"
        case .sosumi: return "Sosumi.aiff"
        case .submarine: return "Submarine.aiff"
        case .tink: return "Tink.aiff"
        case .funk: return "Funk.aiff"
        }
    }

    /// 系统提示音的完整路径，试听和通知使用同一个文件。
    public var systemPath: String {
        "/System/Library/Sounds/\(fileName)"
    }
}

/// 通知声音偏好：是否播放，以及选择的系统提示音。
///
/// 关闭时通知仍然送达，但内容不带声音；重新开启时沿用之前选择的音效。
public struct ReminderSoundPreference: Equatable, Sendable {
    public var isEnabled: Bool
    /// 用户选择的音效。关闭声音时依然保留，重新开启即恢复。
    public var sound: NotificationSound

    public init(
        isEnabled: Bool = true,
        sound: NotificationSound = .glass
    ) {
        self.isEnabled = isEnabled
        self.sound = sound
    }

    /// 关闭时返回 nil，通知内容因此保持无声。
    public var notificationSound: NotificationSound? {
        isEnabled ? sound : nil
    }
}
