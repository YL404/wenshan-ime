import UIKit

/// 键区当前显示的一页。
enum KeyboardLayer {
    case letters
    case numbers
}

/// 按键触发的语义动作。布局只负责把按键接到动作上，VC 用一个 switch 处理全部动作。
enum KeyAction: Equatable {
    case type(String)
    case insert(String)
    case punctuate(String)
    case space
    case returnKey
    /// 长按回车：非默认回车键（发送/搜索等）时插入换行。
    case newline
    case backspace
    /// 删除键左滑，一次删多个。
    case deleteBackward(Int)
    /// 空格键拖动，正数向右。
    case moveCursor(Int)
    /// 长按空格：激活拖动移光标，本身不做事。
    case cursorDrag
    case shift
    case toggleMode
    case showNumbers
    case showLetters
    case showSymbols
    case nextInputMode
}

/// 键区的宿主，通常是键盘 VC。
@MainActor
protocol KeyRowsHost: AnyObject {
    func perform(_ action: KeyAction)
    /// 长按触发 action。返回 false 表示不消费，抬起时仍按轻点处理。
    func performLongPress(_ action: KeyAction) -> Bool
    /// 按下或松开：宿主负责触感和按键预览。
    func keyPressChanged(_ key: KeyButton, pressed: Bool)
}

/// 建好的一页键区，以及按状态要改标题或高亮的几个键。
struct KeyRows {
    var rows: [UIView] = []
    var shift: KeyButton?
    var mode: KeyButton?
    var returnKey: KeyButton?
    var punctuation: KeyButton?
}

/// 按尺寸建一页键区。只在切页或换方向时用，不在每次按键时用。
/// 按键闭包捕获的是这个结构体的副本，host 是弱引用，按键不会反过来持有 VC。
@MainActor
struct KeyRowsBuilder {
    let metrics: KeyboardMetrics
    let showsGlobeKey: Bool
    let keyEvents: KeyEventQueue
    weak var host: KeyRowsHost?

    private static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    func build(_ layer: KeyboardLayer) -> KeyRows {
        var keys = KeyRows()
        switch layer {
        case .numbers:
            let returnKey = makeReturnKey()
            keys.returnKey = returnKey
            keys.rows = [
                makeNumberRow(["1", "2", "3"], trailing: makeDeleteKey()),
                makeNumberRow(["4", "5", "6"], trailing: makeSpaceKey(background: KeyboardPalette.functionKey)),
                makeNumberRow(["7", "8", "9"], trailing: returnKey),
                makeNumberBottomRow(),
            ]
        case .letters:
            let rows = Self.letterRows
            keys.rows = [
                makeRow(rows[0].map(makeLetterKey)),
                makeRow(rows[1].map(makeLetterKey), margin: metrics.letterWidth / 2),
                makeLetterBottomRow(rows[2], keys: &keys),
                makeLetterFunctionRow(keys: &keys),
            ]
        }
        return keys
    }

    // MARK: - 行

    private func makeRow(_ keys: [KeyButton], margin: CGFloat = 0) -> UIStackView {
        let row = UIStackView(arrangedSubviews: keys)
        row.axis = .horizontal
        row.spacing = metrics.gap
        row.distribution = .fillEqually
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        if margin > 0 {
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: margin, bottom: 0, trailing: margin)
        }
        return row
    }

    /// 固定宽度键 + 可伸缩键。用于底行和 Z 行的宽 Shift/删除。
    private func makeProportionalRow(_ items: [(UIView, CGFloat?)]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: items.map { $0.0 })
        row.axis = .horizontal
        row.spacing = metrics.gap
        row.distribution = .fill
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        for (view, width) in items {
            if let width {
                view.widthAnchor.constraint(equalToConstant: width).isActive = true
                view.setContentHuggingPriority(.required, for: .horizontal)
                view.setContentCompressionResistancePriority(.required, for: .horizontal)
            } else {
                view.setContentHuggingPriority(.defaultLow, for: .horizontal)
                view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
        }
        return row
    }

    private func makeNumberRow(_ digits: [String], trailing: KeyButton) -> UIStackView {
        makeRow(digits.map(makeNumberKey) + [trailing])
    }

    private func makeNumberBottomRow() -> UIStackView {
        let dot = makeKey(title: ".", identifier: "key_number_dot", action: .insert("."), font: numberFont)
        dot.accessibilityLabel = "小数点"

        let symbols = makeKey(
            title: "符", identifier: "key_symbol_panel", action: .showSymbols,
            background: KeyboardPalette.functionKey, font: functionFont, showsPreview: false)
        symbols.accessibilityLabel = "符号"

        let letters = makeKey(
            title: "ABC", identifier: "key_letters", action: .showLetters,
            background: KeyboardPalette.functionKey, font: functionFont, showsPreview: false)
        letters.accessibilityLabel = "字母"

        return makeRow([dot, makeNumberKey("0"), symbols, letters])
    }

    private func makeLetterBottomRow(_ row: String, keys: inout KeyRows) -> UIStackView {
        let shift = makeKey(
            title: "⇧", identifier: "key_shift", action: .shift,
            background: KeyboardPalette.functionKey, showsPreview: false)
        shift.accessibilityLabel = "大写"
        keys.shift = shift

        let sideWidth = metrics.letterWidth * 1.3
        return makeProportionalRow([
            (shift, sideWidth),
            (makeRow(row.map(makeLetterKey)), nil),
            (makeDeleteKey(), sideWidth),
        ])
    }

    private func makeLetterFunctionRow(keys: inout KeyRows) -> UIStackView {
        let numbers = makeKey(
            title: "123", identifier: "key_symbols", action: .showNumbers,
            background: KeyboardPalette.functionKey, font: functionFont, showsPreview: false)
        numbers.accessibilityLabel = "数字"
        numbers.accessibilityHint = "长按输入符号"
        setLongPress(numbers, .showSymbols)

        let punctuation = makeKey(
            title: "。\n，", identifier: "key_punctuation", action: .punctuate("."),
            font: smallFont, previewText: "。")
        punctuation.titleLabel?.numberOfLines = 2
        punctuation.titleLabel?.textAlignment = .center
        punctuation.accessibilityLabel = "句号，长按逗号"
        setLongPress(punctuation, .punctuate(","))
        keys.punctuation = punctuation

        let mode = makeKey(
            title: "中\n英", identifier: "key_mode", action: .toggleMode,
            font: smallFont, showsPreview: false)
        mode.titleLabel?.numberOfLines = 2
        mode.titleLabel?.textAlignment = .center
        mode.accessibilityLabel = "切换中英文"
        keys.mode = mode

        let returnKey = makeReturnKey()
        keys.returnKey = returnKey

        let unit = metrics.letterWidth
        var items: [(UIView, CGFloat?)] = [
            (numbers, max(44, unit * 1.15)),
            (punctuation, max(44, unit * 0.65)),
            (makeSpaceKey(background: KeyboardPalette.key), nil),
            (mode, max(44, unit)),
            (returnKey, max(44, unit * 1.15)),
        ]
        if showsGlobeKey {
            items.insert((makeGlobeKey(), 44), at: 1)
        }
        return makeProportionalRow(items)
    }

    // MARK: - 键

    private var functionFont: UIFont { .systemFont(ofSize: max(15, metrics.keyFontSize - 6)) }
    private var smallFont: UIFont { .systemFont(ofSize: max(11, metrics.keyFontSize - 9)) }
    private var numberFont: UIFont { .systemFont(ofSize: metrics.keyFontSize + 1) }

    private func makeLetterKey(_ character: Character) -> KeyButton {
        makeKey(title: String(character), identifier: "key_\(character)", action: .type(String(character)))
    }

    private func makeNumberKey(_ digit: String) -> KeyButton {
        let key = makeKey(title: digit, identifier: "key_number_\(digit)", action: .insert(digit), font: numberFont)
        key.accessibilityLabel = "数字 \(digit)"
        return key
    }

    private func makeSpaceKey(background: UIColor) -> KeyButton {
        let space = makeKey(
            title: "空格", identifier: "key_space", action: .space,
            background: background, font: functionFont, showsPreview: false)
        space.accessibilityLabel = "空格"
        space.accessibilityHint = "长按拖动移动光标"
        space.dragRequiresLongPress = true
        space.dragStep = 5
        space.dragVerticalLimit = 50
        setLongPress(space, .cursorDrag)
        space.onDrag = { delta in
            host?.perform(.moveCursor(Int(delta)))
        }
        return space
    }

    private func makeReturnKey() -> KeyButton {
        let key = makeKey(
            title: "换行", identifier: "key_return", action: .returnKey,
            background: KeyboardPalette.functionKey, font: functionFont, showsPreview: false)
        key.accessibilityLabel = "换行"
        setLongPress(key, .newline)
        return key
    }

    private func makeDeleteKey() -> KeyButton {
        let delete = makeKey(
            title: "⌫", identifier: "key_delete", action: nil,
            background: KeyboardPalette.functionKey, showsPreview: false)
        delete.accessibilityLabel = "删除"
        // 删除按下即生效、按住连发，不进按键队列。
        delete.queuesEvent = false
        delete.triggersOnPress = true
        delete.onRepeat = {
            host?.perform(.backspace)
        }
        delete.onDrag = { delta in
            guard delta < 0 else { return }
            host?.perform(.deleteBackward(Int(-delta)))
        }
        return delete
    }

    private func makeGlobeKey() -> KeyButton {
        let globe = makeKey(
            title: "", identifier: "key_globe", action: .nextInputMode,
            background: KeyboardPalette.functionKey, showsPreview: false)
        let symbol = UIImage.SymbolConfiguration(pointSize: metrics.keyFontSize, weight: .regular)
        globe.setImage(UIImage(systemName: "globe", withConfiguration: symbol), for: .normal)
        globe.tintColor = .label
        globe.accessibilityLabel = "切换键盘"
        return globe
    }

    /// 建一个按键并接好触摸：按下排队、触感和预览交给宿主，抬起后按按下顺序执行 action。
    private func makeKey(
        title: String,
        identifier: String,
        action: KeyAction?,
        background: UIColor = KeyboardPalette.key,
        font: UIFont? = nil,
        showsPreview: Bool = true,
        previewText: String? = nil
    ) -> KeyButton {
        let button = KeyButton(
            title: title,
            identifier: identifier,
            font: font ?? .systemFont(ofSize: metrics.keyFontSize),
            background: background)
        button.showsPreview = showsPreview
        button.previewText = previewText
        let keyEvents = keyEvents
        button.onTap = { [weak button] in
            guard let button, let action else { return }
            keyEvents.commit(button.eventSequence) { host?.perform(action) }
        }
        button.onCancelled = { [weak button] in
            guard let button else { return }
            keyEvents.cancel(button.eventSequence)
        }
        button.onPressChanged = { [weak button] pressed in
            guard let button else { return }
            if pressed, button.queuesEvent {
                button.eventSequence = keyEvents.begin()
            }
            host?.keyPressChanged(button, pressed: pressed)
        }
        return button
    }

    private func setLongPress(_ key: KeyButton, _ action: KeyAction) {
        key.onLongPress = {
            host?.performLongPress(action) ?? false
        }
    }
}
