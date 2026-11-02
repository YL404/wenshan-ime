import UIKit

/// 键盘尺寸。先按 iPhone 竖屏/横屏和 iPad 三档给值，后续再用实机截图校准。
struct KeyboardMetrics {
    let totalHeight: CGFloat
    let candidateHeight: CGFloat
    let gap: CGFloat
    let keyFontSize: CGFloat
    let candidateFontSize: CGFloat

    static func make(screen: CGSize, isPad: Bool) -> KeyboardMetrics {
        let landscape = screen.width > screen.height
        if isPad {
            return KeyboardMetrics(
                totalHeight: landscape ? 300 : 280,
                candidateHeight: 44,
                gap: 6,
                keyFontSize: 24,
                candidateFontSize: 22)
        }
        if landscape {
            return KeyboardMetrics(
                totalHeight: 200,
                candidateHeight: 34,
                gap: 5,
                keyFontSize: 19,
                candidateFontSize: 18)
        }
        return KeyboardMetrics(
            totalHeight: 260,
            candidateHeight: 40,
            gap: 5,
            keyFontSize: 23,
            candidateFontSize: 20)
    }
}

/// 普通按键。按下时改变背景色，Shift/中英键可切成蓝色激活态。
final class KeyButton: UIButton {
    private let normalBackground: UIColor
    private var active = false

    init(title: String, identifier: String, font: UIFont, background: UIColor = .systemBackground) {
        normalBackground = background
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setTitleColor(.label, for: .normal)
        titleLabel?.font = font
        backgroundColor = background
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        accessibilityIdentifier = identifier
        accessibilityLabel = title
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? .systemGray4 : (active ? .systemBlue : normalBackground)
        }
    }

    func setActive(_ active: Bool) {
        self.active = active
        backgroundColor = active ? .systemBlue : normalBackground
        setTitleColor(active ? .white : .label, for: .normal)
    }
}

/// 候选条：横向复用的 collection view，避免每次按键重建按钮。
final class CandidateBar: UIView {
    var onSelect: ((Int) -> Void)?
    var onPage: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private let prevButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let collectionView: UICollectionView
    private let layout = UICollectionViewFlowLayout()
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

        prevButton.setTitle("‹", for: .normal)
        nextButton.setTitle("›", for: .normal)
        dismissButton.setTitle("⌄", for: .normal)
        for button in [prevButton, nextButton, dismissButton] {
            button.titleLabel?.font = .systemFont(ofSize: 18)
            button.tintColor = .secondaryLabel
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        prevButton.accessibilityIdentifier = "candidate_prev"
        nextButton.accessibilityIdentifier = "candidate_next"
        dismissButton.accessibilityIdentifier = "key_dismiss"
        prevButton.accessibilityLabel = "上一页"
        nextButton.accessibilityLabel = "下一页"
        dismissButton.accessibilityLabel = "收起键盘"
        prevButton.addAction(UIAction { [weak self] _ in self?.onPage?(-1) }, for: .touchUpInside)
        nextButton.addAction(UIAction { [weak self] _ in self?.onPage?(1) }, for: .touchUpInside)
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "candidate_status"

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        if #available(iOS 26.0, *) {
            // 候选条只有一行高，默认 edge effect 会盖住整行候选文字，看起来像被高斯模糊。
            collectionView.topEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
            collectionView.leftEdgeEffect.isHidden = true
            collectionView.rightEdgeEffect.isHidden = true
        }
        collectionView.register(CandidateCell.self, forCellWithReuseIdentifier: CandidateCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "candidates"

        addSubview(prevButton)
        addSubview(collectionView)
        addSubview(statusLabel)
        addSubview(nextButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            prevButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 22),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 28),

            nextButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 22),

            collectionView.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: collectionView.trailingAnchor),
        ])

        setCandidates([], status: "文山")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCandidates(_ candidates: [String], status: String?) {
        let changed = candidates != self.candidates
        self.candidates = candidates
        statusLabel.text = status
        statusLabel.isHidden = !candidates.isEmpty
        collectionView.isHidden = candidates.isEmpty
        prevButton.isHidden = candidates.isEmpty
        nextButton.isHidden = candidates.isEmpty
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
        cell.configure(text: candidates[indexPath.item], index: indexPath.item, font: font)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let text = candidates[indexPath.item] as NSString
        let width = text.size(withAttributes: [.font: font]).width + 20
        return CGSize(width: max(44, ceil(width)), height: max(30, 36))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(indexPath.item)
    }
}

final class CandidateCell: UICollectionViewCell {
    static let reuseID = "candidate"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20)
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byClipping
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

    func configure(text: String, index: Int, font: UIFont) {
        label.text = text
        label.font = font
        accessibilityIdentifier = "candidate_\(index)"
        accessibilityLabel = text
        isAccessibilityElement = true
    }
}
