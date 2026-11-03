import Foundation

/// 把旧 bundle id 的偏好一次性迁移到新域。
///
/// macOS 按 bundle id 保存通知记录的图标快照，旧 id 的快照停在图标缺失的早期
/// 版本上，重装、重签、清理图标缓存都不会刷新，通知横幅因此一直显示空白方块。
/// 换新 id 后系统会建立全新的通知记录，图标才能正确显示。
///
/// 旧域只读不写：旧版本仍可照常读取自己的设置，出问题也能回退。
public enum LegacyPreferences {
    /// 旧 bundle id，也是 0.3.1 及更早版本写入偏好的 CFPreferences 域。
    public static let legacyDomain = "com.standuptimer.menubar"

    /// 迁移完成后置位，避免每次启动覆盖用户后来修改的设置。
    static let sentinelKey = "standUpTimer.migratedFromLegacyBundleID"

    static let keys = [
        "standUpTimer.focusMinutes",
        "standUpTimer.restMinutes",
        "standUpTimer.normalFocusMinutes",
        "standUpTimer.normalRestMinutes",
        "standUpTimer.cycleFocusMinutes",
        "standUpTimer.cycleShortRestMinutes",
        "standUpTimer.cycleLongRestMinutes",
        "standUpTimer.soundEnabled",
        "standUpTimer.sound",
        "standUpTimer.state",
        "standUpTimer.language"
    ]

    /// 只补齐新域里缺失的键；新域已有值说明用户已经在新版本里改过设置，不能覆盖。
    ///
    /// - Parameters:
    ///   - defaults: 迁移目标域。默认 `.standard`；测试注入独立的 suite 以隔离真实偏好。
    ///   - sourceDomain: 旧偏好所在的 CFPreferences 域（appID）。默认旧 bundle id；
    ///     测试注入一次性的临时域名。
    public static func migrateIfNeeded(
        into defaults: UserDefaults = .standard,
        sourceDomain: String = legacyDomain
    ) {
        guard !defaults.bool(forKey: sentinelKey) else { return }

        for key in keys where defaults.object(forKey: key) == nil {
            guard let value = CFPreferencesCopyValue(
                key as CFString,
                sourceDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) else { continue }
            defaults.set(value, forKey: key)
        }

        defaults.set(true, forKey: sentinelKey)
    }
}
