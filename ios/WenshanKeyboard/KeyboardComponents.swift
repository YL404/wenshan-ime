import UIKit

/// 键盘尺寸。先按 iPhone 竖屏/横屏和 iPad 三档给值，后续再用实机截图校准。
struct KeyboardMetrics {
    let totalHeight: CGFloat
    let candidateHeight: CGFloat
    let gap: CGFloat
    let keyFontSize: CGFloat
    let candidateFontSize: CGFloat
    let letterWidth: CGFloat

    static func make(screen: CGSize, width: CGFloat, isPad: Bool) -> KeyboardMetrics {
        let landscape = screen.width > screen.height
        let gap: CGFloat = isPad ? 6 : (landscape ? 5 : 5)
        let contentWidth = max(0, width - 12)
        let letterWidth = max(26, (contentWidth - 9 * gap) / 10)
        if isPad {
            return KeyboardMetrics(
                totalHeight: landscape ? 300 : 280,
                candidateHeight: 44,
                gap: gap,
                keyFontSize: 24,
                candidateFontSize: 22,
                letterWidth: letterWidth)
        }
        if landscape {
            return KeyboardMetrics(
                totalHeight: 200,
                candidateHeight: 34,
                gap: gap,
                keyFontSize: 19,
                candidateFontSize: 18,
                letterWidth: letterWidth)
        }
        return KeyboardMetrics(
            totalHeight: 260,
            candidateHeight: 40,
            gap: gap,
            keyFontSize: 23,
            candidateFontSize: 20,
            letterWidth: letterWidth)
    }
}

/// 键盘底色交给 UIInputView 的系统材质，按键只补灰阶层级：
/// 字母键比底色亮，功能键介于两者之间，深色模式不会出现灰底垫黑键。
enum KeyboardPalette {
    static let key = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray3 : .systemBackground
    }
    static let functionKey = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray4 : .secondarySystemBackground
    }
    static let pressed = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray2 : .systemGray4
    }
}

/// 普通按键。所有触摸状态都收在这里：按下、抬起、长按、连发、横向拖动和拖出取消。
/// VC 只接语义回调，不再给单个键挂 gesture recognizer。
final class KeyButton: UIButton {
    var onTap: (() -> Void)?
    /// 返回 true 表示这次长按已被消费，抬起时不再触发 onTap。
    var onLongPress: (() -> Bool)?
    var onRepeat: (() -> Void)?
    /// 横向拖动步长，正数向右，负数向左。
    var onDrag: ((CGFloat) -> Void)?
    var onPressChanged: ((Bool) -> Void)?

    var showsPreview = true
    var previewText: String?
    /// 删除键按下即生效，不等抬起。
    var triggersOnPress = false
    var repeatDelay: TimeInterval = 0.45
    var repeatInterval: TimeInterval = 0.1

    private let normalBackground: UIColor
    private var active = false
    private var touchActive = false
    private var didLongPress = false
    private var didRepeat = false
    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var lastDragStep = 0
    private var longPressTimer: Timer?
    private var repeatDelayTimer: Timer?
    private var repeatTimer: Timer?

    init(title: String, identifier: String, font: UIFont, background: UIColor = KeyboardPalette.key) {
        normalBackground = background
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setTitleColor(.label, for: .normal)
        titleLabel?.font = font
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.6
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

    override func removeFromSuperview() {
        finishTracking()
        super.removeFromSuperview()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishTracking() }
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    func setActive(_ active: Bool) {
        self.active = active
        updateBackground()
        setTitleColor(active ? .white : .label, for: .normal)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard super.beginTracking(touch, with: event) else { return false }
        touchActive = true
        didLongPress = false
        didRepeat = false
        isDragging = false
        dragStartX = touch.location(in: self).x
        lastDragStep = 0
        onPressChanged?(true)
        if triggersOnPress {
            didRepeat = true
            onRepeat?()
        }
        startTimers()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let result = super.continueTracking(touch, with: event)
        guard touchActive, let onDrag else { return result }

        let dx = touch.location(in: self).x - dragStartX
        guard abs(dx) >= 10 else { return result }
        if !isDragging {
            isDragging = true
            didRepeat = true
            cancelRepeatTimers()
        }
        let step = Int(dx / 10)
        guard step != lastDragStep else { return result }
        onDrag(CGFloat(step - lastDragStep))
        lastDragStep = step
        return result
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let inside = touch.map {
            bounds.insetBy(dx: -10, dy: -10).contains($0.location(in: self))
        } ?? false
        let shouldTap = inside && !didLongPress && !didRepeat
        finishTracking()
        super.endTracking(touch, with: event)
        if shouldTap { onTap?() }
    }

    override func cancelTracking(with event: UIEvent?) {
        finishTracking()
        super.cancelTracking(with: event)
    }

    private func updateBackground() {
        backgroundColor = isHighlighted ? KeyboardPalette.pressed : (active ? .systemBlue : normalBackground)
    }

    private func startTimers() {
        cancelTimers()
        if onLongPress != nil {
            let timer = Timer(
                timeInterval: 0.45,
                target: self,
                selector: #selector(longPressFired),
                userInfo: nil,
                repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            longPressTimer = timer
        }
        if onRepeat != nil {
            let timer = Timer(
                timeInterval: repeatDelay,
                target: self,
                selector: #selector(repeatDelayFired),
                userInfo: nil,
                repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            repeatDelayTimer = timer
        }
    }

    private func finishTracking() {
        touchActive = false
        isDragging = false
        cancelTimers()
        onPressChanged?(false)
    }

    private func cancelTimers() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        cancelRepeatTimers()
    }

    private func cancelRepeatTimers() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    @objc private func longPressFired() {
        guard touchActive, let onLongPress, onLongPress() else { return }
        didLongPress = true
        cancelRepeatTimers()
    }

    @objc private func repeatDelayFired() {
        guard touchActive, let onRepeat else { return }
        didRepeat = true
        onRepeat()
        let timer = Timer(
            timeInterval: repeatInterval,
            target: self,
            selector: #selector(repeatFired),
            userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    @objc private func repeatFired() {
        guard touchActive else { return }
        onRepeat?()
    }
}

/// 按键上方的放大预览。只做显示，不参与触摸。
final class KeyPreviewView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.textAlignment = .center
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(text: String, keyFrame: CGRect, font: UIFont, in container: UIView) {
        label.text = text
        label.font = font

        let width = max(keyFrame.width, 44)
        let height = keyFrame.height + 8
        let maxX = max(4, container.bounds.width - width - 4)
        let x = min(max(4, keyFrame.midX - width / 2), maxX)
        var y = keyFrame.minY - height - 4
        if y < 4 {
            y = min(keyFrame.maxY + 4, container.bounds.height - height - 4)
        }
        frame = CGRect(x: x, y: y, width: width, height: height)
        isHidden = false
    }

    func hide() {
        isHidden = true
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
