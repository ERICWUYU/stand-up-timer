import Foundation

/// 设置与计时状态的存储抽象。
///
/// 核心只定义协议和读写规则，具体存储（`UserDefaults`）由 App 层提供，
/// 测试使用 `InMemoryTimerStorage`。
public protocol TimerStorage: AnyObject {
    func readInt(_ key: String) -> Int?
    func writeInt(_ value: Int, forKey key: String)
    func readBool(_ key: String) -> Bool?
    func writeBool(_ value: Bool, forKey key: String)
    func readString(_ key: String) -> String?
    func writeString(_ value: String, forKey key: String)
    func readData(_ key: String) -> Data?
    func writeData(_ value: Data?, forKey key: String)
    /// 键是否存在。用来区分“旧版本没有这个键”和“键存在但值已损坏”。
    func containsValue(forKey key: String) -> Bool
}

/// 设置和计时状态的读写规则。
/// 读取时一律做校验，写入时只写结构化数据。
public struct TimerSettingsStore {
    public enum Key {
        // 阶段 4 的旧键。迁移后继续保留并同步，方便回退到旧版本。
        public static let focusMinutes = "standUpTimer.focusMinutes"
        public static let restMinutes = "standUpTimer.restMinutes"

        // 阶段 5A 起的独立时长。
        public static let normalFocusMinutes = "standUpTimer.normalFocusMinutes"
        public static let normalRestMinutes = "standUpTimer.normalRestMinutes"
        public static let cycleFocusMinutes = "standUpTimer.cycleFocusMinutes"
        public static let cycleShortRestMinutes = "standUpTimer.cycleShortRestMinutes"
        public static let cycleLongRestMinutes = "standUpTimer.cycleLongRestMinutes"

        public static let soundEnabled = "standUpTimer.soundEnabled"
        public static let sound = "standUpTimer.sound"
        public static let state = "standUpTimer.state"
    }

    private let storage: TimerStorage

    public init(storage: TimerStorage) {
        self.storage = storage
    }

    /// 读取设置，并在首次升级时把旧值迁移到新的独立键。
    ///
    /// 缺失的新键会用旧 `focusMinutes` / `restMinutes` 初始化普通模式，
    /// 同时初始化 Focus Cycle 的专注与短休；长休没有旧值，从 15 分钟开始。
    /// 键存在但值损坏（NaN、非整数、越界）时回退到默认值，而不是悄悄复用旧值。
    public var settings: TimerSettings {
        let settings = resolvedSettings()
        // 新键缺失或存在损坏值时写入修复后的值；键值已一致时不重复写。
        if !storedNewKeysMatch(settings) {
            saveNewSettingsKeys(settings)
        }
        return settings
    }

    public func save(_ settings: TimerSettings) {
        // 旧键保留并同步到普通模式，旧版本仍可读取。
        storage.writeInt(settings.focusMinutes, forKey: Key.focusMinutes)
        storage.writeInt(settings.restMinutes, forKey: Key.restMinutes)
        saveNewSettingsKeys(settings)
    }

    private func saveNewSettingsKeys(_ settings: TimerSettings) {
        storage.writeInt(settings.focusMinutes, forKey: Key.normalFocusMinutes)
        storage.writeInt(settings.restMinutes, forKey: Key.normalRestMinutes)
        storage.writeInt(settings.cycleFocusMinutes, forKey: Key.cycleFocusMinutes)
        storage.writeInt(
            settings.cycleShortRestMinutes,
            forKey: Key.cycleShortRestMinutes
        )
        storage.writeInt(
            settings.cycleLongRestMinutes,
            forKey: Key.cycleLongRestMinutes
        )
    }

    public var reminderSound: ReminderSoundPreference {
        ReminderSoundPreference(
            isEnabled: storage.readBool(Key.soundEnabled) ?? true,
            sound: storage.readString(Key.sound)
                .flatMap(NotificationSound.init(rawValue:)) ?? .glass
        )
    }

    public func save(_ preference: ReminderSoundPreference) {
        storage.writeBool(preference.isEnabled, forKey: Key.soundEnabled)
        storage.writeString(preference.sound.rawValue, forKey: Key.sound)
    }

    /// 损坏、未知版本或自相矛盾的状态数据在这里被丢弃。
    public var snapshot: StandUpTimerSnapshot? {
        storage.readData(Key.state)
            .flatMap(StandUpTimerSnapshot.decode(from:))
    }

    public func save(snapshot: StandUpTimerSnapshot?) {
        storage.writeData(snapshot?.encoded(), forKey: Key.state)
    }

    // MARK: - 迁移

    private func resolvedSettings() -> TimerSettings {
        let legacyFocus = validLegacy(
            storage.readInt(Key.focusMinutes),
            range: TimerSettings.focusRange
        )
        let legacyRest = validLegacy(
            storage.readInt(Key.restMinutes),
            range: TimerSettings.restRange
        )

        let normalFocus = resolvedValue(
            key: Key.normalFocusMinutes,
            legacy: legacyFocus,
            range: TimerSettings.focusRange,
            fallback: TimerSettings.defaultFocusMinutes
        )
        let normalRest = resolvedValue(
            key: Key.normalRestMinutes,
            legacy: legacyRest,
            range: TimerSettings.restRange,
            fallback: TimerSettings.defaultRestMinutes
        )
        let cycleFocus = resolvedValue(
            key: Key.cycleFocusMinutes,
            legacy: legacyFocus ?? normalFocus,
            range: TimerSettings.focusRange,
            fallback: TimerSettings.defaultCycleFocusMinutes
        )
        let cycleShortRest = resolvedValue(
            key: Key.cycleShortRestMinutes,
            legacy: legacyRest ?? normalRest,
            range: TimerSettings.restRange,
            fallback: TimerSettings.defaultCycleShortRestMinutes
        )
        let cycleLongRest = resolvedValue(
            key: Key.cycleLongRestMinutes,
            legacy: nil,
            range: TimerSettings.restRange,
            fallback: TimerSettings.defaultCycleLongRestMinutes
        )

        return TimerSettings(
            focusMinutes: normalFocus,
            restMinutes: normalRest,
            cycleFocusMinutes: cycleFocus,
            cycleShortRestMinutes: cycleShortRest,
            cycleLongRestMinutes: cycleLongRest
        )
    }

    /// 新键存在时只信任它：损坏就回退默认值；新键缺失时才使用旧值。
    private func resolvedValue(
        key: String,
        legacy: Int?,
        range: ClosedRange<Int>,
        fallback: Int
    ) -> Int {
        if storage.containsValue(forKey: key) {
            guard let value = storage.readInt(key), range.contains(value) else {
                return fallback
            }
            return value
        }
        if let legacy, range.contains(legacy) {
            return legacy
        }
        return fallback
    }

    private func validLegacy(
        _ value: Int?,
        range: ClosedRange<Int>
    ) -> Int? {
        guard let value, range.contains(value) else { return nil }
        return value
    }

    private func storedNewKeysMatch(_ settings: TimerSettings) -> Bool {
        storage.readInt(Key.normalFocusMinutes) == settings.focusMinutes
            && storage.readInt(Key.normalRestMinutes) == settings.restMinutes
            && storage.readInt(Key.cycleFocusMinutes) == settings.cycleFocusMinutes
            && storage.readInt(Key.cycleShortRestMinutes)
                == settings.cycleShortRestMinutes
            && storage.readInt(Key.cycleLongRestMinutes)
                == settings.cycleLongRestMinutes
    }
}

/// 测试用的内存存储。
public final class InMemoryTimerStorage: TimerStorage {
    private var ints: [String: Int] = [:]
    private var bools: [String: Bool] = [:]
    private var strings: [String: String] = [:]
    private var data: [String: Data] = [:]
    /// 仅测试使用：写入非 Int 的数值（例如 NaN），验证损坏值的安全回退。
    private var doubles: [String: Double] = [:]

    public init() {}

    public func readInt(_ key: String) -> Int? { ints[key] }

    public func writeInt(_ value: Int, forKey key: String) {
        ints[key] = value
    }

    public func readBool(_ key: String) -> Bool? { bools[key] }

    public func writeBool(_ value: Bool, forKey key: String) {
        bools[key] = value
    }

    public func readString(_ key: String) -> String? { strings[key] }

    public func writeString(_ value: String, forKey key: String) {
        strings[key] = value
    }

    public func readData(_ key: String) -> Data? { data[key] }

    public func writeData(_ value: Data?, forKey key: String) {
        data[key] = value
    }

    public func containsValue(forKey key: String) -> Bool {
        ints[key] != nil
            || bools[key] != nil
            || strings[key] != nil
            || data[key] != nil
            || doubles[key] != nil
    }

    public func writeDouble(_ value: Double, forKey key: String) {
        doubles[key] = value
    }
}
