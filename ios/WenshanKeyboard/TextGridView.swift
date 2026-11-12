import UIKit

/// 按宽度自动分列、纵向滚动的文字网格。全部候选和符号面板共用，
/// 各自只提供数据、每格的样式和长按菜单。
final class TextGridView: UIView {
    /// 一格的显示样式。
    struct Style {
        var font: UIFont
        /// 文字左右留白。
        var inset: CGFloat
        var accessibilityIdentifier: String
        var accessibilityValue: String?
        var accessibilityHint: String?
        /// 首选候选用强调色字、不填底。
        var isFirst: Bool = false
    }

    var onSelect: ((Int) -> Void)?
    /// 第 i 格的长按菜单，返回 nil 表示没有。
    var menuProvider: ((Int) -> UIMenu?)?
    /// 第 i 格的样式，默认 17 号字。
    var style: (Int, String) -> Style = { index, _ in
        Style(font: .systemFont(ofSize: 17), inset: 6, accessibilityIdentifier: "grid_\(index)")
    }

    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 8
    private static let cellHeight: CGFloat = 44
    private static let targetCellWidth: CGFloat = 64

    private let minColumns: Int
    private let layout = UICollectionViewFlowLayout()
    private let collectionView: UICollectionView
    private var items: [String] = []
    private var laidOutWidth: CGFloat = 0

    init(minColumns: Int, gridIdentifier: String) {
        self.minColumns = minColumns
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = UIEdgeInsets(
            top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = true
        // 默认 edge effect 会把首末两行文字模糊掉。
        collectionView.topEdgeEffect.isHidden = true
        collectionView.bottomEdgeEffect.isHidden = true
        collectionView.register(GridCell.self, forCellWithReuseIdentifier: GridCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = gridIdentifier
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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

    /// 换一组内容并滚回顶部。
    func setItems(_ items: [String]) {
        self.items = items
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if !items.isEmpty {
            collectionView.setContentOffset(.zero, animated: false)
        }
    }

    /// 供宿主在只改样式后重画当前内容，不重置滚动位置。
    func itemsSnapshot() -> [String] { items }

    private func cellWidth() -> CGFloat {
        let width = max(0, collectionView.bounds.width - 2 * Self.padding)
        guard width > 0 else { return Self.cellHeight }
        let columns = CGFloat(max(minColumns, Int((width + Self.spacing) / (Self.targetCellWidth + Self.spacing))))
        return max(Self.cellHeight, floor((width - Self.spacing * (columns - 1)) / columns))
    }
}

extension TextGridView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GridCell.reuseID, for: indexPath) as! GridCell
        let text = items[indexPath.item]
        cell.configure(text: text, style: style(indexPath.item, text))
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: cellWidth(), height: Self.cellHeight)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item) else { return }
        onSelect?(indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard items.indices.contains(indexPath.item),
              let menu = menuProvider?(indexPath.item) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

/// 按下时变淡的格子。候选条和网格的格子都继承它。
class PressableCell: UICollectionViewCell {
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
}

/// TextGridView 的一格：圆角按键底色 + 居中文字。
final class GridCell: PressableCell {
    static let reuseID = "grid"

    private let label = UILabel()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = KeyboardPalette.gridCell
        contentView.layer.cornerRadius = 7
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        leading = label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailing = label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        NSLayoutConstraint.activate([
            leading,
            trailing,
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, style: TextGridView.Style) {
        label.text = text
        label.font = style.font
        label.textColor = style.isFirst ? KeyboardPalette.accent : .label
        leading.constant = style.inset
        trailing.constant = -style.inset
        accessibilityIdentifier = style.accessibilityIdentifier
        accessibilityLabel = text
        accessibilityValue = style.accessibilityValue
        accessibilityHint = style.accessibilityHint
        isAccessibilityElement = true
    }
}
