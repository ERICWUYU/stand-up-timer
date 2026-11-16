import XCTest
@testable import StandUpTimerApp

/// Stage 6B 批准的单行底栏回归：
/// `[图标 Focus Cycle/End Cycle]  弹性留白  [统计] [设置] [退出]`
///
/// SwiftUI 在单元测试环境下没有稳定的像素级布局断言，这里通过
/// `FooterLayout` 的语义常量与纯测量复算宽度/命中区，并以 `UtilityButton`
/// 纯描述校验图标顺序与本地化标签，不写脆弱的截图/像素测试。
/// 人工截图（中英、Focus Cycle/End Cycle、Light/Dark）仍是最终渲染门禁。
final class FooterLayoutTests: XCTestCase {

    // MARK: 面板与字体守卫：宽度、内边距、字号不得被本次重设计改变

    func testPanelAndTypographyGuards() {
        XCTAssertEqual(PanelLayout.panelWidth, 280)
        XCTAssertEqual(PanelLayout.horizontalPadding, 12)
        XCTAssertEqual(PanelLayout.contentWidth, 256)
        XCTAssertEqual(FooterLayout.footerFontPointSize, 13)
        XCTAssertEqual(FooterLayout.footerFontWeight, .medium)
    }

    // MARK: 右侧三个纯图标按钮：等命中区、等视觉权重

    func testUtilityButtonsShareEqualHitAreas() {
        XCTAssertEqual(FooterLayout.UtilityButton.all.count, 3)
        // 三个按钮共享同一个正方形命中区常量，视图层不可能给出不同尺寸。
        XCTAssertEqual(FooterLayout.utilityHitSize, 28)
        XCTAssertEqual(FooterLayout.utilityButtonCount, 3)
        // 工具组宽度 = 3 个命中区 + 2 个间距。
        XCTAssertEqual(
            FooterLayout.utilityGroupWidth,
            3 * FooterLayout.utilityHitSize + 2 * FooterLayout.utilitySpacing
        )
        // 间距保持在批准的 4–6pt 克制区间。
        XCTAssertTrue((4...6).contains(FooterLayout.utilitySpacing))
    }

    func testUtilityButtonSymbolsAndOrder() {
        XCTAssertEqual(
            FooterLayout.UtilityButton.all.map(\.systemName),
            ["chart.bar.xaxis", "gearshape", "power"]
        )
        XCTAssertEqual(
            FooterLayout.UtilityButton.all.map(\.titleKey),
            ["action.statistics", "action.settings", "action.quit"]
        )
        // 描述唯一，无重复按钮。
        XCTAssertEqual(Set(FooterLayout.UtilityButton.all).count, 3)
    }

    /// icon-only 不等于无标签：每个工具按钮在中英双语下都必须能解析出
    /// 非空的本地化 help / accessibilityLabel 文案（视图共用同一 titleKey）。
    func testUtilityButtonsHaveLocalizedLabelsInBothLanguages() {
        for spec in FooterLayout.UtilityButton.all {
            for language in AppLanguage.allCases {
                let label = L10n.text(spec.titleKey, language: language)
                XCTAssertFalse(
                    label.isEmpty,
                    "\(spec.titleKey) 在 \(language) 下解析为空"
                )
                // 键缺失时 L10n 会原样返回键名；断言不是未解析键。
                XCTAssertNotEqual(label, spec.titleKey)
            }
        }
        XCTAssertEqual(
            L10n.text("action.statistics", language: .english),
            "Statistics"
        )
        XCTAssertEqual(
            L10n.text("action.quit", language: .chinese),
            "退出"
        )
    }

    // MARK: 左侧模式按钮保持正常可读间距，不允许微型内边距

    func testModeButtonUsesReadableSpacing() {
        XCTAssertTrue((4...6).contains(FooterLayout.modeIconTextSpacing))
        XCTAssertGreaterThanOrEqual(FooterLayout.modeButtonHorizontalPadding, 2)
        XCTAssertGreaterThanOrEqual(FooterLayout.modeButtonVerticalPadding, 2)
    }

    // MARK: English：Focus Cycle 与 End Cycle 两种变体都必须落入 256pt

    func testEnglishModeVariantsFitWithUtilityGroup() {
        let cases: [(String, String)] = [
            ("repeat.circle", L10n.text("action.fourRounds", language: .english)),
            ("xmark.circle", L10n.text("action.cancelFourRounds", language: .english))
        ]
        for (symbol, title) in cases {
            let width = FooterLayout.footerWidth(modeSystemName: symbol, modeTitle: title)
            XCTAssertLessThanOrEqual(
                width,
                PanelLayout.contentWidth,
                "English「\(title)」底栏理想宽度 \(width) 超出正文 256pt"
            )
            // 保留 ≥16pt 弹性留白，吸收小数取整与系统版本度量差异。
            XCTAssertGreaterThanOrEqual(
                PanelLayout.contentWidth - width,
                16,
                "English「\(title)」裕量不足 16pt（实测 \(width)）"
            )
        }
    }

    // MARK: Chinese：独立测量两种变体，不依赖 English 最宽假设

    func testChineseModeVariantsFitWithUtilityGroup() {
        let cases: [(String, String)] = [
            ("repeat.circle", L10n.text("action.fourRounds", language: .chinese)),
            ("xmark.circle", L10n.text("action.cancelFourRounds", language: .chinese))
        ]
        for (symbol, title) in cases {
            let width = FooterLayout.footerWidth(modeSystemName: symbol, modeTitle: title)
            XCTAssertLessThanOrEqual(
                width,
                PanelLayout.contentWidth,
                "中文「\(title)」底栏理想宽度 \(width) 超出正文 256pt"
            )
            XCTAssertGreaterThanOrEqual(PanelLayout.contentWidth - width, 16)
        }
    }

    // MARK: 测量部件：真实 SF Symbol 度量 + 模式按钮宽度公式

    func testSymbolWidthsComeFromRealMeasurement() {
        // 13pt medium 实测：圆形/齿轮/电源符号 16pt，柱状图符号 18pt。
        XCTAssertEqual(FooterLayout.iconWidth(systemName: "gearshape"), 16)
        XCTAssertEqual(FooterLayout.iconWidth(systemName: "power"), 16)
        XCTAssertEqual(FooterLayout.iconWidth(systemName: "repeat.circle"), 16)
        XCTAssertEqual(FooterLayout.iconWidth(systemName: "xmark.circle"), 16)
        XCTAssertEqual(FooterLayout.iconWidth(systemName: "chart.bar.xaxis"), 18)
        // 不存在的符号退回字号宽度，而不是崩溃或返回 0。
        XCTAssertEqual(
            FooterLayout.iconWidth(systemName: "definitely.not.a.symbol"),
            FooterLayout.footerFontPointSize
        )
    }

    func testModeButtonWidthFollowsSharedConstants() {
        let title = L10n.text("action.fourRounds", language: .english)
        let textWidth = ceil((title as NSString).size(withAttributes: [
            .font: FooterLayout.footerFont
        ]).width)
        let expected = textWidth
            + FooterLayout.iconWidth(systemName: "repeat.circle")
            + FooterLayout.modeIconTextSpacing
            + 2 * FooterLayout.modeButtonHorizontalPadding
        XCTAssertEqual(
            FooterLayout.modeButtonWidth(systemName: "repeat.circle", title: title),
            expected
        )
    }
}
