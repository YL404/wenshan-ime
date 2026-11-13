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
        var adjustsFontSizeToFitWidth: Bool = false
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
    private let adaptsWidthToContent: Bool
    private let layout = AdaptiveTextGridLayout()
    private let collectionView: UICollectionView
    private var items: [String] = []
    private var laidOutWidth: CGFloat = 0

    init(minColumns: Int, gridIdentifier: String, adaptsWidthToContent: Bool = false) {
        self.minColumns = minColumns
        self.adaptsWidthToContent = adaptsWidthToContent
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = UIEdgeInsets(
            top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        layout.adaptsToContent = adaptsWidthToContent
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delaysContentTouches = false
        collectionView.canCancelContentTouches = true
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
            if !adaptsWidthToContent {
                layout.itemSize = CGSize(width: cellWidth(), height: Self.cellHeight)
            }
            layout.invalidateLayout()
        }
    }

    /// 换一组内容并滚回顶部。
    func setItems(_ items: [String]) {
        self.items = items
        collectionView.reloadData()
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        if !items.isEmpty {
            collectionView.setContentOffset(.zero, animated: false)
        }
    }

    /// 只改字号或样式时原地刷新布局，不重置滚动位置。
    func reloadStyles() {
        collectionView.reloadData()
        layout.invalidateLayout()
    }

    /// 供宿主在只改样式后重画当前内容，不重置滚动位置。
    func itemsSnapshot() -> [String] { items }

    private func cellWidth() -> CGFloat {
        let width = max(0, collectionView.bounds.width - 2 * Self.padding)
        guard width > 0 else { return Self.cellHeight }
        let columns = CGFloat(max(minColumns, Int((width + Self.spacing) / (Self.targetCellWidth + Self.spacing))))
        return max(Self.cellHeight, floor((width - Self.spacing * (columns - 1)) / columns))
    }

    private func itemSize(at indexPath: IndexPath) -> CGSize {
        let minWidth = cellWidth()
        guard adaptsWidthToContent, items.indices.contains(indexPath.item) else {
            return CGSize(width: minWidth, height: Self.cellHeight)
        }
        let text = items[indexPath.item]
        let itemStyle = style(indexPath.item, text)
        let textWidth = (text as NSString).size(withAttributes: [.font: itemStyle.font]).width
        let desiredWidth = ceil(textWidth) + itemStyle.inset * 2 + 4
        let maxWidth = max(minWidth, collectionView.bounds.width - 2 * Self.padding)
        return CGSize(width: min(maxWidth, max(minWidth, desiredWidth)), height: Self.cellHeight)
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
        itemSize(at: indexPath)
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
            guard isHighlighted != oldValue else { return }
            UIView.animate(
                withDuration: 0.08,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.contentView.alpha = self.isHighlighted ? 0.6 : 1
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
    }
}

/// TextGridView 的一格：圆角按键底色 + 居中文字。
final class GridCell: PressableCell {
    static let reuseID = "grid"

    private let label = UILabel()
    private var horizontalInset: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = KeyboardPalette.gridCell
        contentView.layer.cornerRadius = 7
        contentView.layer.cornerCurve = .continuous
        contentView.layer.allowsGroupOpacity = false

        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: horizontalInset, dy: 0)
    }

    func configure(text: String, style: TextGridView.Style) {
        label.text = text
        label.font = style.font
        label.textColor = style.isFirst ? KeyboardPalette.accent : .label
        label.adjustsFontSizeToFitWidth = style.adjustsFontSizeToFitWidth
        label.minimumScaleFactor = style.adjustsFontSizeToFitWidth ? 0.6 : 1
        if horizontalInset != style.inset {
            horizontalInset = style.inset
            setNeedsLayout()
        }
        accessibilityIdentifier = style.accessibilityIdentifier
        accessibilityLabel = text
        accessibilityValue = style.accessibilityValue
        accessibilityHint = style.accessibilityHint
        isAccessibilityElement = true
    }
}

/// 展开候选网格用的自适应流式布局：按词宽决定格子宽度，普通行适度拉齐左右边缘。
private final class AdaptiveTextGridLayout: UICollectionViewFlowLayout {
    var adaptsToContent = false

    private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
    private var cachedContentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        cachedAttributes.removeAll(keepingCapacity: true)
        cachedContentHeight = 0
        guard adaptsToContent,
              let collectionView,
              collectionView.bounds.width > 0,
              collectionView.numberOfSections > 0
        else { return }

        let itemCount = collectionView.numberOfItems(inSection: 0)
        let availableWidth = max(0, collectionView.bounds.width - sectionInset.left - sectionInset.right)
        guard itemCount > 0, availableWidth > 0 else {
            cachedContentHeight = sectionInset.top + sectionInset.bottom
            return
        }

        let delegate = collectionView.delegate as? UICollectionViewDelegateFlowLayout
        var y = sectionInset.top
        var rowItems: [(index: Int, width: CGFloat, height: CGFloat)] = []
        var rowUsedWidth: CGFloat = 0

        func flushRow(justify: Bool) {
            guard !rowItems.isEmpty else { return }
            let rowHeight = rowItems.map(\.height).max() ?? 44
            let slack = max(0, availableWidth - rowUsedWidth)
            let shouldJustify = justify && rowItems.count >= 2 && slack <= availableWidth * 0.45
            let wholeExtra = shouldJustify ? floor(slack / CGFloat(rowItems.count)) : 0
            var remainder = shouldJustify ? slack - wholeExtra * CGFloat(rowItems.count) : 0

            var x = sectionInset.left
            for (offset, item) in rowItems.enumerated() {
                let isLastInRow = offset == rowItems.count - 1
                let width: CGFloat
                if shouldJustify && isLastInRow {
                    width = max(item.width, sectionInset.left + availableWidth - x)
                } else {
                    let extraPixel: CGFloat = remainder >= 1 ? 1 : 0
                    if extraPixel > 0 { remainder -= 1 }
                    width = item.width + wholeExtra + extraPixel
                }
                let attrs = UICollectionViewLayoutAttributes(
                    forCellWith: IndexPath(item: item.index, section: 0))
                attrs.frame = CGRect(x: x, y: y, width: width, height: rowHeight)
                cachedAttributes.append(attrs)
                x += width + minimumInteritemSpacing
            }
            y += rowHeight + minimumLineSpacing
            rowItems.removeAll(keepingCapacity: true)
            rowUsedWidth = 0
        }

        for index in 0..<itemCount {
            let indexPath = IndexPath(item: index, section: 0)
            let requested = delegate?.collectionView?(
                collectionView, layout: self, sizeForItemAt: indexPath
            ) ?? CGSize(width: 64, height: 44)
            let width = min(availableWidth, requested.width)
            let nextWidth = rowItems.isEmpty ? width : rowUsedWidth + minimumInteritemSpacing + width
            if !rowItems.isEmpty && nextWidth > availableWidth + 0.5 {
                flushRow(justify: true)
            }
            rowItems.append((index, width, requested.height))
            rowUsedWidth = rowItems.count == 1 ? width : rowUsedWidth + minimumInteritemSpacing + width
        }
        flushRow(justify: false)

        cachedContentHeight = y - minimumLineSpacing + sectionInset.bottom
    }

    override var collectionViewContentSize: CGSize {
        guard adaptsToContent, let collectionView else {
            return super.collectionViewContentSize
        }
        return CGSize(width: collectionView.bounds.width, height: cachedContentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard adaptsToContent else {
            return super.layoutAttributesForElements(in: rect)
        }
        return cachedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard adaptsToContent else {
            return super.layoutAttributesForItem(at: indexPath)
        }
        guard cachedAttributes.indices.contains(indexPath.item) else { return nil }
        return cachedAttributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard adaptsToContent else {
            return super.shouldInvalidateLayout(forBoundsChange: newBounds)
        }
        guard let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > 0.5
    }
}
