import UIKit

/// 顶栏按钮统一成键帽：圆角浅底、按下压暗、足够大的点击区。
/// 避免它们看起来像一行 footer 文字。
@MainActor
private func configureToolbarButton(
    _ button: UIButton, image: UIImage?, title: String?, action: @escaping () -> Void
) {
    var config = UIButton.Configuration.plain()
    config.image = image
    config.title = title
    config.baseForegroundColor = .label
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var out = incoming
        out.font = .systemFont(ofSize: 16, weight: .medium)
        return out
    }
    config.imagePadding = 0
    button.configuration = config
    button.configurationUpdateHandler = { button in
        button.backgroundColor = button.isHighlighted
            ? KeyboardPalette.pressed
            : KeyboardPalette.key
        button.layer.borderColor = KeyboardPalette.keyBorder
            .resolvedColor(with: button.traitCollection)
            .cgColor
    }
    button.backgroundColor = KeyboardPalette.key
    button.layer.cornerRadius = 7
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 1
    button.layer.borderColor = KeyboardPalette.keyBorder
        .resolvedColor(with: button.traitCollection)
        .cgColor
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
}

@MainActor
private func toolbarIcon(_ name: String, pointSize: CGFloat = 16) -> UIImage? {
    UIImage(
        systemName: name,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
}

/// 顶栏右端的「收起键盘」按钮，空闲工具栏和候选条各一个。
@MainActor
private func configureDismissButton(_ button: UIButton, action: @escaping () -> Void) {
    configureToolbarButton(button, image: toolbarIcon("chevron.down"), title: nil, action: action)
    button.accessibilityLabel = "收起键盘"
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
        statusLabel.textColor = .label
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "toolbar_status"
        statusLabel.isHidden = true

        configureToolbarButton(fullWidthButton, image: nil, title: "全") { [weak self] in
            self?.onToggleFullWidth?()
        }
        fullWidthButton.accessibilityIdentifier = "key_full_width"

        dismissButton.accessibilityIdentifier = "toolbar_dismiss"
        configureDismissButton(dismissButton) { [weak self] in self?.onDismiss?() }

        addSubview(brandLabel)
        addSubview(statusLabel)
        addSubview(fullWidthButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            brandLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            brandLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 44),
            dismissButton.heightAnchor.constraint(equalToConstant: 36),

            fullWidthButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -6),
            fullWidthButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            fullWidthButton.widthAnchor.constraint(equalToConstant: 44),
            fullWidthButton.heightAnchor.constraint(equalToConstant: 36),

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
        statusLabel.textColor = isError ? .systemRed : .label
        statusLabel.accessibilityHint = hint
        statusLabel.isHidden = text == nil
    }

    func setFullWidth(_ fullWidth: Bool) {
        var config = fullWidthButton.configuration
        config?.title = fullWidth ? "全" : "半"
        fullWidthButton.configuration = config
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
    var onManage: ((Int, Bool) -> Void)?
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

        configureToolbarButton(
            expandButton, image: toolbarIcon("square.grid.2x2"), title: nil
        ) { [weak self] in
            self?.onExpand?()
        }
        expandButton.accessibilityIdentifier = "candidate_expand"
        expandButton.accessibilityLabel = "展开全部候选"

        dismissButton.accessibilityIdentifier = "key_dismiss"
        configureDismissButton(dismissButton) { [weak self] in self?.onDismiss?() }

        addSubview(collectionView)
        addSubview(emptyLabel)
        addSubview(expandButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 44),
            dismissButton.heightAnchor.constraint(equalToConstant: 36),

            expandButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -6),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 44),
            expandButton.heightAnchor.constraint(equalToConstant: 36),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -6),
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
        var config = expandButton.configuration
        config?.image = toolbarIcon(name)
        expandButton.configuration = config
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
        guard candidates.indices.contains(indexPath.item) else { return nil }
        let index = indexPath.item
        let canPickChar = candidates[index].count > 1 && onSelectChar != nil
        guard canPickChar || onManage != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions: [UIMenuElement] = []
            if canPickChar {
                actions.append(UIAction(title: "取首字") { _ in self.onSelectChar?(index, false) })
                actions.append(UIAction(title: "取尾字") { _ in self.onSelectChar?(index, true) })
            }
            if let onManage = self.onManage {
                actions.append(UIAction(title: "置顶此候选") { _ in onManage(index, true) })
                actions.append(UIAction(title: "删除此候选", attributes: .destructive) { _ in
                    onManage(index, false)
                })
            }
            return UIMenu(children: actions)
        }
    }
}

final class CandidateCell: PressableCell {
    static let reuseID = "candidate"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerCurve = .continuous
        contentView.layer.allowsGroupOpacity = false

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
        label.textColor = isFirst ? KeyboardPalette.accent : .label
        contentView.backgroundColor = isFirst ? KeyboardPalette.gridCell : .clear
        contentView.layer.cornerRadius = isFirst ? 7 : 0
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
    var menuProvider: ((Int) -> UIMenu?)? {
        get { grid.menuProvider }
        set { grid.menuProvider = newValue }
    }

    private let grid = TextGridView(
        minColumns: 3,
        gridIdentifier: "candidate_panel_grid",
        adaptsWidthToContent: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "candidate_panel"
        // 不画自己的底板：和字母页/数字页一样露出 UIInputView 的系统键盘材质。
        backgroundColor = .clear

        grid.style = makeStyle(font: .systemFont(ofSize: 17))
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

    func setFont(_ font: UIFont) {
        grid.style = makeStyle(font: font)
        grid.reloadStyles()
    }

    private func makeStyle(font: UIFont) -> (Int, String) -> TextGridView.Style {
        { index, _ in
            TextGridView.Style(
                font: .systemFont(ofSize: font.pointSize, weight: index == 0 ? .semibold : .regular),
                inset: 10,
                accessibilityIdentifier: "candidate_panel_\(index)",
                accessibilityValue: index == 0 ? "首选" : nil,
                isFirst: index == 0,
                adjustsFontSizeToFitWidth: true)
        }
    }
}
