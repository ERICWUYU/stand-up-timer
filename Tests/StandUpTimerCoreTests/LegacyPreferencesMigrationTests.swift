import XCTest
@testable import StandUpTimerCore

/// 旧 bundle id 偏好域到新域的一次性迁移（`LegacyPreferences`）。
///
/// 每个用例使用独立的 CFPreferences 源域和独立的 UserDefaults suite，
/// setUp/tearDown 里创建并清空，绝不读写真实的 `.standard` 或线上旧域。
final class LegacyPreferencesMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var sourceDomain: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.standuptimer.tests.migration-\(UUID().uuidString)"
        sourceDomain = "com.standuptimer.tests.legacy-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "应当能创建隔离的 UserDefaults suite")
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        for key in LegacyPreferences.keys {
            CFPreferencesSetValue(
                key as CFString,
                nil,
                sourceDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        CFPreferencesAppSynchronize(sourceDomain as CFString)
        defaults.removePersistentDomain(forName: suiteName)
        // 清空键值后 cfprefsd 仍会在 Preferences 目录保留空 plist；
        // 这些域名只在本用例的 UUID 命名空间内，直接删除文件做彻底清理。
        removePreferencesPlist(for: sourceDomain)
        removePreferencesPlist(for: suiteName)
        super.tearDown()
    }

    private func removePreferencesPlist(for domain: String) {
        guard domain.hasPrefix("com.standuptimer.tests.") else { return }
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 辅助

    private func seedLegacy(_ pairs: [String: Any]) {
        for (key, value) in pairs {
            CFPreferencesSetValue(
                key as CFString,
                value as CFPropertyList,
                sourceDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        CFPreferencesAppSynchronize(sourceDomain as CFString)
    }

    private func migrate() {
        LegacyPreferences.migrateIfNeeded(
            into: defaults,
            sourceDomain: sourceDomain
        )
    }

    private func sourceValue(_ key: String) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            sourceDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as Any?
    }

    // MARK: - 用例

    /// 0.3.1 用户的典型旧域：整型时长、开关、提示音、语言和状态快照都被复制。
    func testCopiesRepresentativeLegacyFixture() {
        let state = Data([0x7b, 0x22, 0x76, 0x22, 0x3a, 0x31, 0x7d])
        seedLegacy([
            "standUpTimer.focusMinutes": NSNumber(value: 23),
            "standUpTimer.restMinutes": NSNumber(value: 7),
            "standUpTimer.soundEnabled": NSNumber(value: true),
            "standUpTimer.sound": "funk" as NSString,
            "standUpTimer.language": "en" as NSString,
            "standUpTimer.state": state as NSData
        ])

        migrate()

        XCTAssertEqual(defaults.integer(forKey: "standUpTimer.focusMinutes"), 23)
        XCTAssertEqual(defaults.integer(forKey: "standUpTimer.restMinutes"), 7)
        XCTAssertTrue(defaults.bool(forKey: "standUpTimer.soundEnabled"))
        XCTAssertEqual(defaults.string(forKey: "standUpTimer.sound"), "funk")
        XCTAssertEqual(defaults.string(forKey: "standUpTimer.language"), "en")
        XCTAssertEqual(defaults.data(forKey: "standUpTimer.state"), state)
        XCTAssertTrue(defaults.bool(forKey: LegacyPreferences.sentinelKey))
    }

    /// `false` 是真实存在的值，不能因为按 Bool 读取为假就漏迁移。
    func testCopiesFalseBooleanValue() {
        seedLegacy(["standUpTimer.soundEnabled": NSNumber(value: false)])

        migrate()

        XCTAssertNotNil(defaults.object(forKey: "standUpTimer.soundEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "standUpTimer.soundEnabled"))
    }

    /// 新域已有值优先：只补齐缺失的键，不覆盖用户在新版本里的修改。
    func testPreservesExistingTargetValuesAndFillsMissing() {
        defaults.set(99, forKey: "standUpTimer.focusMinutes")
        seedLegacy([
            "standUpTimer.focusMinutes": NSNumber(value: 23),
            "standUpTimer.restMinutes": NSNumber(value: 7)
        ])

        migrate()

        XCTAssertEqual(defaults.integer(forKey: "standUpTimer.focusMinutes"), 99)
        XCTAssertEqual(defaults.integer(forKey: "standUpTimer.restMinutes"), 7)
        XCTAssertTrue(defaults.bool(forKey: LegacyPreferences.sentinelKey))
    }

    /// 哨兵置位后迁移只执行一次：旧域后来出现的新值不得再写入。
    func testSentinelMakesMigrationOneShot() {
        seedLegacy(["standUpTimer.sound": "funk" as NSString])
        migrate()

        seedLegacy([
            "standUpTimer.sound": "glass" as NSString,
            "standUpTimer.language": "zh-Hans" as NSString
        ])
        migrate()

        XCTAssertEqual(defaults.string(forKey: "standUpTimer.sound"), "funk")
        XCTAssertNil(defaults.string(forKey: "standUpTimer.language"))
    }

    /// 旧域完全为空时迁移安全完成：只写哨兵，不制造伪造的设置值。
    func testEmptyLegacyDomainOnlySetsSentinel() {
        migrate()

        XCTAssertTrue(defaults.bool(forKey: LegacyPreferences.sentinelKey))
        for key in LegacyPreferences.keys {
            XCTAssertNil(defaults.object(forKey: key), "空旧域不应凭空写入 \(key)")
        }
    }

    /// 旧域只读：迁移后源域的值不变，也不会把哨兵写进旧域。
    func testSourceDomainIsReadOnly() {
        seedLegacy([
            "standUpTimer.focusMinutes": NSNumber(value: 23),
            "standUpTimer.sound": "funk" as NSString
        ])
        let focusBefore = sourceValue("standUpTimer.focusMinutes")
        let soundBefore = sourceValue("standUpTimer.sound")

        migrate()

        XCTAssertEqual(sourceValue("standUpTimer.focusMinutes") as? NSNumber,
                       focusBefore as? NSNumber)
        XCTAssertEqual(sourceValue("standUpTimer.sound") as? String,
                       soundBefore as? String)
        XCTAssertNil(
            CFPreferencesCopyValue(
                LegacyPreferences.sentinelKey as CFString,
                sourceDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ),
            "哨兵只能写入新域，不能污染旧域"
        )
    }

    /// 线上旧域常量一旦改动，真实用户的迁移就会静默失效。
    func testLegacyDomainConstant() {
        XCTAssertEqual(LegacyPreferences.legacyDomain, "com.standuptimer.menubar")
    }
}
