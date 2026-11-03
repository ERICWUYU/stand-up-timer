import Foundation
import StandUpTimerCore

/// 用 `UserDefaults` 实现核心定义的存储协议。
/// 核心只依赖 `TimerStorage`，因此持久化规则可以在测试中完整覆盖。
final class UserDefaultsTimerStorage: TimerStorage {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func readInt(_ key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    func writeInt(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func readBool(_ key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    func writeBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func readString(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    func writeString(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func readData(_ key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func writeData(_ value: Data?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func containsValue(forKey key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }
}
