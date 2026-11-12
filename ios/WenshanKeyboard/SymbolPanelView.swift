import UIKit

/// 分类符号面板：盖住键区，顶栏保留。分类横排，下面按宽度分列滚动。
final class SymbolPanelView: UIView {
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?

    private struct Category {
        let title: String
        let symbols: [String]
    }

    private static let categories: [Category] = [
        Category(title: "常用", symbols: [
            "，", "。", "？", "！", "、", "；", "：", "…", "—", "·",
            "“", "”", "‘", "’", "（", "）", "《", "》", "【", "】",
            "￥", "@", "#", "%", "+", "-", "=", "/", "*", "&",
        ]),
        Category(title: "中文", symbols: [
            "，", "。", "？", "！", "、", "；", "：", "…", "—", "·",
            "“", "”", "‘", "’", "～", "（", "）", "《", "》",
            "〈", "〉", "「", "」", "『", "』", "〔", "〕", "※",
            "〖", "〗", "＜", "＞", "°", "｛", "｝", "［", "］", "℃",
            "︵", "︶", "﹁", "﹂", "±", "×", "÷", "≈", "≠", "≤",
            "≥", "√", "∞", "∵", "∴", "→", "←", "↑", "↓", "★",
            "☆", "●", "○", "■", "□", "◆", "◇", "▲", "△", "〇",
        ]),
        Category(title: "英文", symbols: [
            ",", ".", "?", "!", ";", ":", "'", "\"", "(", ")",
            "[", "]", "{", "}", "/", "<", ">", "\\", "|", "-",
            "_", "+", "=", "*", "&", "^", "%", "$", "#", "@",
            "~", "`", "·", "…", "–", "—", "§", "¶", "†", "‡",
        ]),
        Category(title: "数字", symbols: [
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
            "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
            "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
            "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ", "Ⅸ", "Ⅹ",
            "½", "⅓", "¼", "‰", "′", "″", "㎡", "㎏", "㎝", "№",
        ]),
        Category(title: "网络", symbols: [
            "@", "#", "/", "\\", ":", "_", "-", "+", "=", "&",
            "?", "%", "~", "^", "*", "|", "<", ">", "$", "€",
            "http://", "https://", "www.", ".com", ".cn", ".net", ".org", ".io",
        ]),
    ]

    /// 长按符号时给出的另一个常用写法，和原符号页的替换表一致。
    static let alternates: [String: String] = [
        "。": "…", "，": "、", "？": "！", "！": "？",
        "：": "；", "；": "：", "、": "，", "…": "。",
        "-": "—", "/": "\\", "(": "[", ")": "]",
        "（": "【", "）": "】", "“": "‘", "”": "’",
        "《": "〈", "》": "〉", "@": "#", "#": "@",
        "¥": "￥", "￥": "¥",
    ]

    private let header = UIStackView()
    private let grid = TextGridView(minColumns: 5, gridIdentifier: "symbol_panel_grid")
    private var categoryButtons: [UIButton] = []
    private var symbols: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "symbol_panel"
        backgroundColor = KeyboardPalette.panel

        header.axis = .horizontal
        header.spacing = 4
        header.distribution = .fillEqually
        header.translatesAutoresizingMaskIntoConstraints = false

        for (index, category) in Self.categories.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(category.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13)
            button.layer.cornerRadius = 8
            button.layer.cornerCurve = .continuous
            button.accessibilityIdentifier = "symbol_category_\(index)"
            button.addAction(UIAction { [weak self] _ in
                self?.select(index)
            }, for: .touchUpInside)
            categoryButtons.append(button)
            header.addArrangedSubview(button)
        }

        let close = UIButton(type: .system)
        close.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)),
            for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityIdentifier = "symbol_panel_close"
        close.accessibilityLabel = "关闭符号面板"
        close.addAction(UIAction { [weak self] _ in
            self?.onClose?()
        }, for: .touchUpInside)
        header.addArrangedSubview(close)

        grid.style = { index, text in
            TextGridView.Style(
                font: .systemFont(ofSize: text.count > 3 ? 13 : 20),
                inset: 4,
                accessibilityIdentifier: "symbol_\(index)",
                accessibilityHint: Self.alternates[text].map { "长按输入 \($0)" })
        }
        grid.onSelect = { [weak self] index in
            guard let self else { return }
            self.onInsert?(self.symbols[index])
        }
        grid.menuProvider = { [weak self] index in
            guard let self,
                  let alternate = Self.alternates[self.symbols[index]],
                  let onInsert = self.onInsert else { return nil }
            return UIMenu(children: [
                UIAction(title: "输入 \(alternate)") { _ in onInsert(alternate) },
            ])
        }

        addSubview(header)
        addSubview(grid)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 36),

            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        select(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func select(_ index: Int) {
        guard Self.categories.indices.contains(index) else { return }
        symbols = Self.categories[index].symbols
        for (buttonIndex, button) in categoryButtons.enumerated() {
            let active = buttonIndex == index
            button.backgroundColor = active ? KeyboardPalette.key : .clear
            button.setTitleColor(active ? .label : .secondaryLabel, for: .normal)
        }
        grid.setItems(symbols)
    }
}
