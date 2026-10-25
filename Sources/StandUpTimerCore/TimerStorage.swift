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
}

/// 设置和计时状态的读写规则。
/// 读取时一律做校验，写入时只写结构化数据。
public struct TimerSettingsStore {
    public enum Key {
        public static let focusMinutes = "standUpTimer.focusMinutes"
        public static let restMinutes = "standUpTimer.restMinutes"
        public static let soundEnabled = "standUpTimer.soundEnabled"
        public static let sound = "standUpTimer.sound"
        public static let state = "standUpTimer.state"
    }

    private let storage: TimerStorage

    public init(storage: TimerStorage) {
        self.storage = storage
    }

    public var settings: TimerSettings {
        TimerSettings(
            focusMinutes: storage.readInt(Key.focusMinutes),
            restMinutes: storage.readInt(Key.restMinutes)
        )
    }

    public func save(_ settings: TimerSettings) {
        storage.writeInt(settings.focusMinutes, forKey: Key.focusMinutes)
        storage.writeInt(settings.restMinutes, forKey: Key.restMinutes)
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
}

/// 测试用的内存存储。
public final class InMemoryTimerStorage: TimerStorage {
    private var ints: [String: Int] = [:]
    private var bools: [String: Bool] = [:]
    private var strings: [String: String] = [:]
    private var data: [String: Data] = [:]

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
}
