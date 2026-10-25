import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    /// 按系统偏好顺序取第一个受支持的语言。
    /// 只看第一项时，主语言不受支持会直接退回英文，
    /// 即使中文排在第二顺位。
    static var systemDefault: AppLanguage {
        for preferred in Locale.preferredLanguages {
            let tag = preferred.lowercased()
            if tag.hasPrefix("zh") {
                return .chinese
            }
            if tag.hasPrefix("en") {
                return .english
            }
        }
        return .english
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        bundle(for: language)
            .localizedString(forKey: key, value: key, table: nil)
    }

    /// 每种语言的资源包只解析一次，避免每次取词都重新查找路径。
    private static let bundles: [AppLanguage: Bundle] = Dictionary(
        uniqueKeysWithValues: AppLanguage.allCases.map { language in
            (language, resolveBundle(for: language))
        }
    )

    private static func bundle(for language: AppLanguage) -> Bundle {
        bundles[language] ?? Bundle.module
    }

    private static func resolveBundle(for language: AppLanguage) -> Bundle {
        guard
            let path = Bundle.module.path(
                forResource: language.rawValue,
                ofType: "lproj"
            ),
            let bundle = Bundle(path: path)
        else {
            return Bundle.module
        }
        return bundle
    }
}
