import UIKit

/// 键盘尺寸。iPhone 保持紧凑两档；iPad 按屏幕高度分档，浮动/分屏单独一档。
struct KeyboardMetrics {
    let totalHeight: CGFloat
    let candidateHeight: CGFloat
    let gap: CGFloat
    let keyFontSize: CGFloat
    let candidateFontSize: CGFloat
    let letterWidth: CGFloat

    static func make(
        screen: CGSize,
        width: CGFloat,
        isPad: Bool,
        isFloating: Bool = false
    ) -> KeyboardMetrics {
        let landscape = screen.width > screen.height
        let gap: CGFloat = isPad ? (isFloating ? 5 : 6) : (landscape ? 5 : 5)
        let contentWidth = max(0, width - 12)
        let letterWidth = max(26, (contentWidth - 9 * gap) / 10)
        if isPad {
            if isFloating {
                return KeyboardMetrics(
                    totalHeight: 255,
                    candidateHeight: 40,
                    gap: gap,
                    keyFontSize: 24,
                    candidateFontSize: 20,
                    letterWidth: letterWidth)
            }
            if landscape {
                let height: CGFloat = max(screen.width, screen.height) >= 1300
                    ? 420
                    : (screen.height < 850 ? 342 : 348)
                return KeyboardMetrics(
                    totalHeight: height,
                    candidateHeight: 44,
                    gap: gap,
                    keyFontSize: 27,
                    candidateFontSize: 22,
                    letterWidth: letterWidth)
            }
            let height: CGFloat = screen.height >= 1300 ? 325 : (screen.height < 1150 ? 255 : 260)
            return KeyboardMetrics(
                totalHeight: height,
                candidateHeight: 44,
                gap: gap,
                keyFontSize: 22,
                candidateFontSize: 20,
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

/// 按按下顺序执行按键动作。两指快速连打时，后按下的键可能先抬起；
/// 队列会等前一个键抬起或取消后再执行，保证字符顺序和手指顺序一致。
///
/// 某个键既没抬起也没取消（UIKit 漏发事件）时，它会挡住后面所有按键。
/// 两道兜底：队头按下超过 staleAfter 秒就让开；已经不在队列里的序号
/// （被让开或 reset 掉）提交时直接执行，不再等。
@MainActor
final class KeyEventQueue {
    private static let staleAfter: TimeInterval = 2

    private var nextSequence = 0
    private var order: [Int] = []
    private var pending: [Int: () -> Void] = [:]
    private var startedAt: [Int: TimeInterval] = [:]
    private var isFlushing = false

    func begin() -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        while let head = order.first, pending[head] == nil,
              now - (startedAt[head] ?? now) > Self.staleAfter {
            drop(head)
        }
        let sequence = nextSequence
        nextSequence += 1
        order.append(sequence)
        startedAt[sequence] = now
        flush()
        return sequence
    }

    func commit(_ sequence: Int, action: @escaping () -> Void) {
        guard sequence >= 0, order.contains(sequence) else {
            action()
            return
        }
        pending[sequence] = action
        flush()
    }

    func cancel(_ sequence: Int) {
        guard sequence >= 0 else { return }
        drop(sequence)
        flush()
    }

    /// 键盘收起时清空，旧按键之后的提交按「不在队列里」直接执行。
    func reset() {
        order.removeAll()
        pending.removeAll()
        startedAt.removeAll()
    }

    private func drop(_ sequence: Int) {
        pending[sequence] = nil
        startedAt[sequence] = nil
        order.removeAll { $0 == sequence }
    }

    private func flush() {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let sequence = order.first, let action = pending[sequence] {
            drop(sequence)
            action()
        }
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
    /// 空格等键要先长按激活，再拖动才生效，避免轻点空格时误移光标。
    var dragRequiresLongPress = false
    var dragStep: CGFloat = 10
    /// 拖动时允许的垂直偏移；超过后不再移动光标。
    var dragVerticalLimit: CGFloat?
    /// 普通按键抬起后按按下顺序执行，避免两指快速连打乱序。
    var queuesEvent = true
    var eventSequence = -1
    var onCancelled: (() -> Void)?

    private let normalBackground: UIColor
    private var active = false
    private var touchActive = false
    private var didLongPress = false
    private var didRepeat = false
    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartY: CGFloat = 0
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
        cancelInteraction()
        super.removeFromSuperview()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInteraction() }
    }

    /// 键盘切页、收起或视图重建时调用，停掉计时器并释放队列里的按键。
    func cancelInteraction() {
        let hadTouch = touchActive
        finishTracking()
        if hadTouch { onCancelled?() }
    }

    override var isHighlighted: Bool {
        didSet {
            updateBackground()
            updatePressScale()
        }
    }

    private func updatePressScale() {
        UIView.animate(
            withDuration: 0.06,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.transform = self.isHighlighted
                ? CGAffineTransform(scaleX: 0.96, y: 0.96)
                : .identity
        }
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
        eventSequence = -1
        let location = touch.location(in: self)
        dragStartX = location.x
        dragStartY = location.y
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
        if dragRequiresLongPress && !didLongPress { return result }

        let location = touch.location(in: self)
        let dx = location.x - dragStartX
        let dy = location.y - dragStartY
        if let dragVerticalLimit, abs(dy) > dragVerticalLimit { return result }
        guard abs(dx) >= dragStep else { return result }
        if !isDragging {
            isDragging = true
            didRepeat = true
            cancelRepeatTimers()
        }
        let step = Int(dx / dragStep)
        guard step != lastDragStep else { return result }
        onDrag(CGFloat(step - lastDragStep))
        lastDragStep = step
        return result
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let inside = touch.map {
            bounds.insetBy(dx: -10, dy: -10).contains($0.location(in: self))
        } ?? false
        // cancelInteraction 之后 UIKit 仍可能补发 endTracking，那次触摸已经取消，不能再算轻点。
        let shouldTap = touchActive && inside && !didLongPress && !didRepeat
        finishTracking()
        super.endTracking(touch, with: event)
        if shouldTap {
            onTap?()
        } else {
            onCancelled?()
        }
        eventSequence = -1
    }

    override func cancelTracking(with event: UIEvent?) {
        finishTracking()
        super.cancelTracking(with: event)
        onCancelled?()
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
        if !isHighlighted { transform = .identity }
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
        if isHidden {
            alpha = 0
            transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            isHidden = false
            UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.alpha = 1
                self.transform = .identity
            }
        } else {
            alpha = 1
            transform = .identity
        }
    }

    func hide() {
        isHidden = true
        alpha = 1
        transform = .identity
    }
}
