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
    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private var categoryButtons: [UIButton] = []
    private var symbols: [String] = []
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "symbol_panel"
        backgroundColor = KeyboardPalette.functionKey

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

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = true
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
        }
        collectionView.register(
            SymbolCell.self,
            forCellWithReuseIdentifier: SymbolCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "symbol_panel_grid"

        addSubview(header)
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 36),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        select(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard collectionView.bounds.width > 0 else { return }
        if abs(collectionView.bounds.width - laidOutWidth) > 0.5 {
            laidOutWidth = collectionView.bounds.width
            layout.invalidateLayout()
        }
    }

    private func select(_ index: Int) {
        guard Self.categories.indices.contains(index) else { return }
        symbols = Self.categories[index].symbols
        for (buttonIndex, button) in categoryButtons.enumerated() {
            let active = buttonIndex == index
            button.backgroundColor = active ? KeyboardPalette.key : .clear
            button.setTitleColor(active ? .label : .secondaryLabel, for: .normal)
        }
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if !symbols.isEmpty {
            collectionView.setContentOffset(.zero, animated: false)
        }
    }

    private func contentWidth() -> CGFloat {
        max(0, collectionView.bounds.width - 16)
    }

    private func columnCount() -> Int {
        let width = contentWidth()
        guard width > 0 else { return 5 }
        return max(5, Int((width + 6) / 70))
    }
}

extension SymbolPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        symbols.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: SymbolCell.reuseID, for: indexPath) as! SymbolCell
        cell.configure(text: symbols[indexPath.item], index: indexPath.item)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = contentWidth()
        let columns = CGFloat(columnCount())
        guard width > 0, columns > 0 else { return CGSize(width: 44, height: 44) }
        let cellWidth = floor((width - 6 * (columns - 1)) / columns)
        return CGSize(width: max(44, cellWidth), height: 44)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard symbols.indices.contains(indexPath.item) else { return }
        onInsert?(symbols[indexPath.item])
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard symbols.indices.contains(indexPath.item),
              let alternate = Self.alternates[symbols[indexPath.item]],
              let onInsert else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "输入 \(alternate)") { _ in onInsert(alternate) },
            ])
        }
    }
}

final class SymbolCell: UICollectionViewCell {
    static let reuseID = "symbol_grid"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = KeyboardPalette.key
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        label.font = .systemFont(ofSize: 20)
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.1) {
                self.contentView.alpha = self.isHighlighted ? 0.6 : 1
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1
    }

    func configure(text: String, index: Int) {
        label.text = text
        label.font = .systemFont(ofSize: text.count > 3 ? 13 : 20)
        accessibilityIdentifier = "symbol_\(index)"
        accessibilityLabel = text
        if let alternate = SymbolPanelView.alternates[text] {
            accessibilityHint = "长按输入 \(alternate)"
        } else {
            accessibilityHint = nil
        }
        isAccessibilityElement = true
    }
}
