import UIKit

/// 顶栏右端的「收起键盘」按钮，空闲工具栏和候选条各一个。
@MainActor
private func configureDismissButton(_ button: UIButton, action: @escaping () -> Void) {
    let image = UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    button.setImage(image, for: .normal)
    button.tintColor = .secondaryLabel
    button.accessibilityLabel = "收起键盘"
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
}

/// 空闲时占住顶栏：左侧品牌和状态，右侧全半角与收起。
/// 输入开始后同一块位置换成 CandidateBar，高度不变，按键不跳。
final class ToolbarBar: UIView {
    var onToggleFullWidth: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let brandLabel = UILabel()
    private let statusLabel = UILabel()
    private let fullWidthButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "toolbar_bar"

        brandLabel.text = "文山"
        brandLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        brandLabel.textColor = .label
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.accessibilityIdentifier = "toolbar_brand"
        brandLabel.accessibilityLabel = "文山输入法"

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "toolbar_status"
        statusLabel.isHidden = true

        fullWidthButton.setTitle("全", for: .normal)
        fullWidthButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        fullWidthButton.setTitleColor(.secondaryLabel, for: .normal)
        fullWidthButton.accessibilityIdentifier = "key_full_width"
        fullWidthButton.translatesAutoresizingMaskIntoConstraints = false
        fullWidthButton.addAction(UIAction { [weak self] _ in
            self?.onToggleFullWidth?()
        }, for: .touchUpInside)

        dismissButton.accessibilityIdentifier = "toolbar_dismiss"
        configureDismissButton(dismissButton) { [weak self] in self?.onDismiss?() }

        addSubview(brandLabel)
        addSubview(statusLabel)
        addSubview(fullWidthButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            brandLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            brandLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 40),
            dismissButton.heightAnchor.constraint(equalToConstant: 40),

            fullWidthButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -2),
            fullWidthButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            fullWidthButton.widthAnchor.constraint(equalToConstant: 44),
            fullWidthButton.heightAnchor.constraint(equalToConstant: 40),

            statusLabel.leadingAnchor.constraint(equalTo: brandLabel.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: fullWidthButton.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStatus(_ text: String?, isError: Bool = false, hint: String? = nil) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
        statusLabel.accessibilityHint = hint
        statusLabel.isHidden = text == nil
    }

    func setFullWidth(_ fullWidth: Bool) {
        fullWidthButton.setTitle(fullWidth ? "全" : "半", for: .normal)
        fullWidthButton.accessibilityLabel = fullWidth
            ? "全角标点，点击切换半角"
            : "半角标点，点击切换全角"
    }

    func setFullWidthEnabled(_ enabled: Bool) {
        fullWidthButton.isEnabled = enabled
        fullWidthButton.alpha = enabled ? 1 : 0.4
    }
}

/// 输入中的顶栏：当前页候选词块、展开全部候选、收起键盘。
final class CandidateBar: UIView {
    var onSelect: ((Int) -> Void)?
    var onSelectChar: ((Int, Bool) -> Void)?
    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let expandButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let emptyLabel = UILabel()
    private var candidates: [String] = []
    var font = UIFont.systemFont(ofSize: 20)

    override init(frame: CGRect) {
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "candidate_bar"

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.contentInset = UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        // 候选条只有一行高，默认 edge effect 会盖住整行候选文字。
        collectionView.topEdgeEffect.isHidden = true
        collectionView.bottomEdgeEffect.isHidden = true
        collectionView.leftEdgeEffect.isHidden = true
        collectionView.rightEdgeEffect.isHidden = true
        collectionView.register(CandidateCell.self, forCellWithReuseIdentifier: CandidateCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "candidates"

        emptyLabel.text = "无候选"
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.accessibilityIdentifier = "candidate_empty"
        emptyLabel.isHidden = true

        expandButton.setImage(
            UIImage(
                systemName: "square.grid.2x2",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)),
            for: .normal)
        expandButton.tintColor = .secondaryLabel
        expandButton.accessibilityIdentifier = "candidate_expand"
        expandButton.accessibilityLabel = "展开全部候选"
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.addAction(UIAction { [weak self] _ in
            self?.onExpand?()
        }, for: .touchUpInside)

        dismissButton.accessibilityIdentifier = "key_dismiss"
        configureDismissButton(dismissButton) { [weak self] in self?.onDismiss?() }

        addSubview(collectionView)
        addSubview(emptyLabel)
        addSubview(expandButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 40),
            dismissButton.heightAnchor.constraint(equalToConstant: 40),

            expandButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -2),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 40),
            expandButton.heightAnchor.constraint(equalToConstant: 40),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -2),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: expandButton.leadingAnchor, constant: -8),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCandidates(_ candidates: [String]) {
        let changed = candidates != self.candidates
        self.candidates = candidates
        collectionView.isHidden = candidates.isEmpty
        emptyLabel.isHidden = !candidates.isEmpty
        expandButton.isEnabled = !candidates.isEmpty
        expandButton.alpha = candidates.isEmpty ? 0.4 : 1
        if changed {
            collectionView.reloadData()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if !candidates.isEmpty {
                collectionView.setContentOffset(.zero, animated: false)
            }
        }
    }

    func setCandidateFont(_ font: UIFont) {
        self.font = font
        collectionView.reloadData()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    func setExpanded(_ expanded: Bool) {
        let name = expanded ? "xmark" : "square.grid.2x2"
        expandButton.setImage(
            UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)),
            for: .normal)
        expandButton.accessibilityLabel = expanded ? "收起全部候选" : "展开全部候选"
    }
}

extension CandidateBar: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        candidates.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CandidateCell.reuseID, for: indexPath) as! CandidateCell
        cell.configure(
            text: candidates[indexPath.item],
            index: indexPath.item,
            font: font,
            isFirst: indexPath.item == 0)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let text = candidates[indexPath.item] as NSString
        let width = text.size(withAttributes: [.font: font]).width + 22
        let height = max(30, min(36, collectionView.bounds.height - 4))
        return CGSize(width: max(44, ceil(width)), height: height)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard candidates.indices.contains(indexPath.item),
              candidates[indexPath.item].count > 1,
              let onSelectChar else { return nil }
        let index = indexPath.item
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "取首字") { _ in onSelectChar(index, false) },
                UIAction(title: "取尾字") { _ in onSelectChar(index, true) },
            ])
        }
    }
}

final class CandidateCell: PressableCell {
    static let reuseID = "candidate"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        label.font = .systemFont(ofSize: 20)
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, index: Int, font: UIFont, isFirst: Bool) {
        label.text = text
        label.font = isFirst ? .systemFont(ofSize: font.pointSize, weight: .semibold) : font
        contentView.backgroundColor = isFirst ? KeyboardPalette.key : .clear
        contentView.layer.cornerRadius = isFirst ? 9 : 0
        accessibilityIdentifier = "candidate_\(index)"
        accessibilityLabel = text
        accessibilityValue = isFirst ? "首选" : nil
        accessibilityHint = text.count > 1 ? "长按可取首字或尾字" : nil
        isAccessibilityElement = true
    }
}

/// 展开后的全部候选：盖住键区，顶栏保留。网格按宽自动分列，整份候选一次滚动看完。
final class CandidatePanel: UIView {
    var onSelect: ((Int) -> Void)? {
        get { grid.onSelect }
        set { grid.onSelect = newValue }
    }

    private let grid = TextGridView(minColumns: 3, gridIdentifier: "candidate_panel_grid")

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "candidate_panel"
        backgroundColor = KeyboardPalette.functionKey

        grid.style = { index, _ in
            TextGridView.Style(
                font: .systemFont(ofSize: 17, weight: index == 0 ? .semibold : .regular),
                inset: 6,
                accessibilityIdentifier: "candidate_panel_\(index)",
                accessibilityValue: index == 0 ? "首选" : nil)
        }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCandidates(_ candidates: [String]) {
        grid.setItems(candidates)
    }
}
