import XCTest
@testable import StandUpTimerApp

/// Stage 6B：两份 `.strings` 的键集合必须完全一致；新增「今年」窗口键的
/// 文案必须与产品文案逐字相等。键缺失时 L10n 会原样返回键名，这里一并拦截。
final class LocalizationParityTests: XCTestCase {
    private enum Failure: Error {
        case resourceNotFound(String)
        case unreadableStrings(String)
    }

    // MARK: 新增键的逐字文案与双语覆盖

    func testThisYearKeyHasExactBilingualValues() {
        XCTAssertEqual(
            L10n.text("statistics.window.thisYear", language: .english),
            "This Year"
        )
        XCTAssertEqual(
            L10n.text("statistics.window.thisYear", language: .chinese),
            "今年"
        )
        // 月度图表 X 轴名称同样双语齐备。
        XCTAssertEqual(
            L10n.text("statistics.chart.month", language: .english),
            "Month"
        )
        XCTAssertEqual(
            L10n.text("statistics.chart.month", language: .chinese),
            "月份"
        )
    }

    // MARK: 两份 .strings 键集合完全一致，且无未解析键

    func testEnglishAndChineseStringsHaveIdenticalKeySets() throws {
        // 先触发 L10n 资源包加载，确保合成资源包出现在 allBundles 中。
        AppLanguage.allCases.forEach {
            _ = L10n.text("statistics.heading", language: $0)
        }

        let english = try loadStrings(.english)
        let chinese = try loadStrings(.chinese)

        XCTAssertEqual(
            Set(english.keys),
            Set(chinese.keys),
            "两份 Localizable.strings 的键集合不一致"
        )

        // 任何 statistics.* 键都不允许回退成键名本身或解析为空串。
        for language in AppLanguage.allCases {
            let table = try loadStrings(language)
            for key in table.keys where key.hasPrefix("statistics.") {
                let resolved = L10n.text(key, language: language)
                XCTAssertNotEqual(resolved, key, "\(language) 下 \(key) 未解析")
                XCTAssertFalse(resolved.isEmpty, "\(language) 下 \(key) 为空文案")
            }
        }
    }

    /// 从应用自己的合成资源包中读取 lproj；系统 bundle 也可能带 en.lproj，
    /// 因此先用 bundle 路径收窄到 StandUpTimer，再要求其中确有
    /// Localizable.strings。编译后的 .strings 是二进制 plist，
    /// NSDictionary(contentsOfFile:) 对二进制 plist 与 OpenStep 文本都能解析。
    private func loadStrings(_ language: AppLanguage) throws -> [String: String] {
        let candidates = Bundle.allBundles.filter {
            $0.bundlePath.contains("StandUpTimer")
        }
        for bundle in candidates {
            guard let path = bundle.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: language.rawValue
            ) else {
                continue
            }
            guard let table = NSDictionary(contentsOfFile: path) as? [String: String] else {
                throw Failure.unreadableStrings(path)
            }
            return table
        }
        throw Failure.resourceNotFound("\(language.rawValue).lproj/Localizable.strings")
    }
}
