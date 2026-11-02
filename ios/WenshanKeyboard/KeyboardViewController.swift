import UIKit
import os

private let keyboardLog = Logger(subsystem: "im.wenshan.ios.keyboard", category: "lifecycle")

/// 键盘扩展入口：只做布局、渲染和按键转发，输入语义在 KeyboardModel。
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let candidateBar = CandidateBar()
    private let keyboardStack = UIStackView()
    private let root = UIStackView()
    private let keyPreview = KeyPreviewView()
    private let keyEvents = KeyEventQueue()
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var heightConstraint: NSLayoutConstraint!
    private var candidateHeightConstraint: NSLayoutConstraint!
    private var metrics = KeyboardMetrics.make(screen: .zero, width: 0, isPad: false, isFloating: false)

    private var shiftButton: KeyButton?
    private var modeButton: KeyButton?
    private var returnButton: KeyButton?
    private var punctuationButton: KeyButton?
    private weak var previewedButton: KeyButton?
    private var symbolsOn = false
    private var hasMarkedText = false
    private var isApplyingText = false

    private let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let symbolRows = ["1234567890", "-/:;()¥&@\"", "。？！，、；：…"]
    private static let symbolAlternates: [String: String] = [
        "。": "…", "，": "、", "？": "！", "！": "？",
        "：": "；", "；": "：", "、": "，", "…": "。",
        "-": "—", "/": "\\", "(": "[", ")": "]",
        "¥": "$", "@": "#", "&": "*", "\"": "'", "'": "\"",
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardLog.info("viewDidLoad")
        buildUI()
        loadEngine()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateContext()
        keyFeedback.prepare()
        selectionFeedback.prepare()
        if model.phase != .ready {
            loadEngine()
        }
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboardLog.info("viewWillDisappear")
        super.viewWillDisappear(animated)
        model.flush()
        model.reset()
        clearMarkedText()
        hidePreview()
        candidateBar.setCandidates([], status: nil)
    }
    /// 外部改正文：只在组合态重置，避免每次选词都误清状态。
    override func textDidChange(_ textInput: UITextInput?) {
        guard !isApplyingText, model.isComposing else { return }
        model.reset()
        render()
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        guard model.isComposing else { return }
        model.reset()
        clearMarkedText()
        render()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        guard model.isComposing else { return }
        model.reset()
        clearMarkedText()
        render()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updateMetrics()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateMetrics()
    }

    // MARK: - UI

    private func buildUI() {
        metrics = currentMetrics()

        heightConstraint = view.heightAnchor.constraint(equalToConstant: metrics.totalHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        candidateHeightConstraint = candidateBar.heightAnchor.constraint(equalToConstant: metrics.candidateHeight)
        candidateHeightConstraint.isActive = true
        candidateBar.setCandidateFont(.systemFont(ofSize: metrics.candidateFontSize))
        candidateBar.onSelect = { [weak self] index in
            guard let self else { return }
            self.playSelectionFeedback()
            self.apply(self.model.select(index))
        }
        candidateBar.onPage = { [weak self] delta in
            guard let self else { return }
            self.playSelectionFeedback()
            self.apply(self.model.page(delta))
        }
        candidateBar.onDismiss = { [weak self] in
            self?.dismissKeyboard()
        }

        keyboardStack.axis = .vertical
        keyboardStack.spacing = metrics.gap
        keyboardStack.distribution = .fillEqually
        keyboardStack.alignment = .fill
        keyboardStack.translatesAutoresizingMaskIntoConstraints = false

        root.axis = .vertical
        root.spacing = metrics.gap
        root.alignment = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(candidateBar)
        root.addArrangedSubview(keyboardStack)
        view.addSubview(root)
        view.addSubview(keyPreview)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])

        renderKeyboardRows()
    }

    private func currentMetrics() -> KeyboardMetrics {
        let screen = view.window?.windowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
        let width = view.bounds.width > 0 ? view.bounds.width : screen.width
        let isPad = traitCollection.userInterfaceIdiom == .pad
        let isFloating = isPad && width < screen.width * 0.9 && width < screen.height
        return KeyboardMetrics.make(
            screen: screen,
            width: width,
            isPad: isPad,
            isFloating: isFloating)
    }

    private func updateMetrics() {
        let next = currentMetrics()
        guard next.totalHeight != metrics.totalHeight
            || next.candidateHeight != metrics.candidateHeight
            || next.gap != metrics.gap
            || next.keyFontSize != metrics.keyFontSize
            || next.candidateFontSize != metrics.candidateFontSize
            || next.letterWidth != metrics.letterWidth
        else { return }
        metrics = next
        heightConstraint.constant = next.totalHeight
        candidateHeightConstraint.constant = next.candidateHeight
        root.spacing = next.gap
        keyboardStack.spacing = next.gap
        candidateBar.setCandidateFont(.systemFont(ofSize: next.candidateFontSize))
        renderKeyboardRows()
        view.setNeedsLayout()
    }

    /// 按当前页重建键盘行。只在切页/换方向时调用，不在每次按键时调用。
    private func renderKeyboardRows() {
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        shiftButton = nil
        modeButton = nil
        returnButton = nil
        punctuationButton = nil
        hidePreview()

        if symbolsOn {
            for row in symbolRows {
                keyboardStack.addArrangedSubview(makeRow(row.map { character in
                    let text = String(character)
                    return makeKey(
                        title: text,
                        identifier: "key_\(character)",
                        action: { [weak self] in
                            guard let self else { return }
                            self.apply(self.model.insert(text))
                        },
                        longPressText: Self.symbolAlternates[text])
                }))
            }
            keyboardStack.addArrangedSubview(makeSymbolBottomRow())
        } else {
            for (index, row) in letterRows.enumerated() {
                if index == 2 {
                    keyboardStack.addArrangedSubview(makeLetterBottomRow(row))
                } else {
                    keyboardStack.addArrangedSubview(makeRow(row.map { character in
                        makeKey(
                            title: String(character),
                            identifier: "key_\(character)",
                            action: { [weak self] in
                                guard let self else { return }
                                self.apply(self.model.type(String(character)))
                            })
                    }, margin: index == 1 ? metrics.letterWidth / 2 : 0))
                }
            }
            keyboardStack.addArrangedSubview(makeLetterFunctionRow())
        }
    }

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

    private func makeLetterBottomRow(_ row: String) -> UIStackView {
        let shift = makeKey(
            title: "⇧",
            identifier: "key_shift",
            action: { [weak self] in
                guard let self else { return }
                self.model.shiftTapped()
                self.render()
            },
            background: KeyboardPalette.functionKey,
            showsPreview: false)
        shift.accessibilityLabel = "大写"
        shiftButton = shift

        let letters = row.map { character in
            makeKey(
                title: String(character),
                identifier: "key_\(character)",
                action: { [weak self] in
                    guard let self else { return }
                    self.apply(self.model.type(String(character)))
                })
        }
        let lettersRow = makeRow(letters)

        let delete = makeDeleteKey()

        let sideWidth = metrics.letterWidth * 1.3
        return makeProportionalRow([(shift, sideWidth), (lettersRow, nil), (delete, sideWidth)])
    }

    private func makeLetterFunctionRow() -> UIStackView {
        let numbers = makeKey(
            title: "123",
            identifier: "key_symbols",
            action: { [weak self] in self?.toggleSymbols() },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        numbers.accessibilityLabel = "数字和符号"

        let punctuation = makeKey(
            title: "。\n，",
            identifier: "key_punctuation",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.punctuate("."))
            },
            font: .systemFont(ofSize: max(11, metrics.keyFontSize - 9)),
            previewText: "。")
        punctuation.titleLabel?.numberOfLines = 2
        punctuation.titleLabel?.textAlignment = .center
        punctuation.accessibilityLabel = "句号，长按逗号"
        punctuation.onLongPress = { [weak self] in
            guard let self else { return false }
            self.apply(self.model.punctuate(","))
            return true
        }
        punctuationButton = punctuation

        let mode = makeKey(
            title: "中\n英",
            identifier: "key_mode",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.toggleMode())
            },
            font: .systemFont(ofSize: max(11, metrics.keyFontSize - 9)),
            showsPreview: false)
        mode.titleLabel?.numberOfLines = 2
        mode.titleLabel?.textAlignment = .center
        mode.accessibilityLabel = "切换中英文"
        modeButton = mode

        let space = makeKey(
            title: "空格",
            identifier: "key_space",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.space())
            },
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        space.accessibilityLabel = "空格"
        configureSpaceKey(space)

        let returnKey = makeKey(
            title: "换行",
            identifier: "key_return",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.returnKey())
            },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        returnKey.accessibilityLabel = "换行"
        configureReturnKey(returnKey)
        returnButton = returnKey

        let globe = makeGlobeKey()
        let unit = metrics.letterWidth
        return makeProportionalRow([
            (numbers, unit * 1.15),
            (globe, unit * 0.75),
            (punctuation, unit * 0.65),
            (space, nil),
            (mode, unit),
            (returnKey, unit * 1.15),
        ])
    }

    private func makeSymbolBottomRow() -> UIStackView {
        let letters = makeKey(
            title: "ABC",
            identifier: "key_letters",
            action: { [weak self] in self?.toggleSymbols() },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        letters.accessibilityLabel = "字母"

        let mode = makeKey(
            title: "中\n英",
            identifier: "key_mode",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.toggleMode())
            },
            font: .systemFont(ofSize: max(11, metrics.keyFontSize - 9)),
            showsPreview: false)
        mode.titleLabel?.numberOfLines = 2
        mode.titleLabel?.textAlignment = .center
        mode.accessibilityLabel = "切换中英文"
        modeButton = mode

        let space = makeKey(
            title: "空格",
            identifier: "key_space",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.space())
            },
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        space.accessibilityLabel = "空格"
        configureSpaceKey(space)

        let delete = makeDeleteKey()

        let returnKey = makeKey(
            title: "换行",
            identifier: "key_return",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.returnKey())
            },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        returnKey.accessibilityLabel = "换行"
        configureReturnKey(returnKey)
        returnButton = returnKey

        let globe = makeGlobeKey()
        let unit = metrics.letterWidth
        return makeProportionalRow([
            (letters, unit * 1.15),
            (globe, unit * 0.75),
            (mode, unit),
            (space, nil),
            (delete, unit),
            (returnKey, unit * 1.15),
        ])
    }

    private func makeKey(
        title: String,
        identifier: String,
        action: @escaping () -> Void,
        background: UIColor = KeyboardPalette.key,
        font: UIFont? = nil,
        showsPreview: Bool = true,
        previewText: String? = nil,
        longPressText: String? = nil
    ) -> KeyButton {
        let button = KeyButton(
            title: title,
            identifier: identifier,
            font: font ?? .systemFont(ofSize: metrics.keyFontSize),
            background: background)
        button.showsPreview = showsPreview
        button.previewText = previewText
        button.onTap = { [weak self, weak button] in
            guard let self, let button else { return }
            self.keyEvents.commit(button.eventSequence) { action() }
        }
        button.onCancelled = { [weak self, weak button] in
            guard let self, let button else { return }
            self.keyEvents.cancel(button.eventSequence)
        }
        button.onPressChanged = { [weak self, weak button] pressed in
            guard let self, let button else { return }
            if pressed {
                if button.queuesEvent {
                    button.eventSequence = self.keyEvents.begin()
                }
                self.playKeyFeedback()
                self.showPreview(for: button)
            } else {
                self.hidePreview(for: button)
            }
        }
        if let longPressText {
            button.accessibilityHint = "长按输入\(longPressText)"
            button.onLongPress = { [weak self] in
                guard let self else { return false }
                self.apply(self.model.insert(longPressText))
                return true
            }
        }
        return button
    }

    private func makeDeleteKey() -> KeyButton {
        let delete = makeKey(
            title: "⌫",
            identifier: "key_delete",
            action: {},
            background: KeyboardPalette.functionKey,
            showsPreview: false)
        delete.accessibilityLabel = "删除"
        delete.queuesEvent = false
        delete.triggersOnPress = true
        delete.onRepeat = { [weak self] in
            guard let self else { return }
            self.apply(self.model.backspace())
        }
        delete.onDrag = { [weak self] delta in
            self?.deleteByDrag(delta)
        }
        return delete
    }

    private func makeGlobeKey() -> KeyButton {
        let globe = makeKey(
            title: "",
            identifier: "key_globe",
            action: { [weak self] in self?.advanceToNextInputMode() },
            background: KeyboardPalette.functionKey,
            showsPreview: false)
        let symbol = UIImage.SymbolConfiguration(
            pointSize: metrics.keyFontSize,
            weight: .regular)
        globe.setImage(UIImage(systemName: "globe", withConfiguration: symbol), for: .normal)
        globe.tintColor = .label
        globe.accessibilityLabel = "切换键盘"
        return globe
    }

    private func configureReturnKey(_ key: KeyButton) {
        key.onLongPress = { [weak self] in
            guard let self, !self.model.isComposing, self.model.returnKeyType != .default else {
                return false
            }
            self.apply(.commit("\n"))
            return true
        }
    }

    private func configureSpaceKey(_ key: KeyButton) {
        key.dragRequiresLongPress = true
        key.dragStep = 5
        key.dragVerticalLimit = 50
        key.accessibilityHint = "长按拖动移动光标"
        key.onLongPress = { [weak self] in
            guard let self, !self.model.isComposing else { return false }
            return true
        }
        key.onDrag = { [weak self] delta in
            self?.moveCursor(by: Int(delta))
        }
    }

    private func moveCursor(by steps: Int) {
        guard steps != 0 else { return }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: steps)
        playSelectionFeedback()
    }

    private func playKeyFeedback() {
        guard hasFullAccess else { return }
        keyFeedback.impactOccurred(intensity: 0.7)
        keyFeedback.prepare()
    }

    private func playSelectionFeedback() {
        guard hasFullAccess else { return }
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
    }

    private func showPreview(for button: KeyButton) {
        guard button.showsPreview, !button.isHidden else { return }
        let text = button.previewText ?? button.title(for: .normal) ?? ""
        guard !text.isEmpty else { return }
        let frame = button.convert(button.bounds, to: view)
        previewedButton = button
        keyPreview.show(
            text: text,
            keyFrame: frame,
            font: .systemFont(ofSize: metrics.keyFontSize + 4),
            in: view)
    }

    private func hidePreview(for button: KeyButton? = nil) {
        guard button == nil || previewedButton === button else { return }
        previewedButton = nil
        keyPreview.hide()
    }

    private func deleteByDrag(_ delta: CGFloat) {
        guard delta < 0 else { return }
        delete(times: Int(-delta))
    }

    private func delete(times: Int) {
        guard times > 0 else { return }
        for _ in 0..<times {
            apply(model.backspace(), renderNow: false)
        }
        render()
    }

    // MARK: - 引擎和上下文

    private func loadEngine() {
        let directory = dataDirectory()
        keyboardLog.info("loadEngine data=\(directory.path, privacy: .public)")
        Task { [weak self] in
            await self?.model.load(dataDirectory: directory)
            if case .failed(let reason) = self?.model.phase {
                keyboardLog.error("engine failed: \(reason, privacy: .public)")
            }
            self?.render()
        }
    }

    /// App Group 可写时用共享目录；否则退回扩展自己的 Documents。
    private func dataDirectory() -> URL {
        let fm = FileManager.default
        if let group = AppGroup.dataDirectoryURL {
            do {
                try fm.createDirectory(at: group, withIntermediateDirectories: true)
                let probe = group.appendingPathComponent(".write-test")
                try Data().write(to: probe, options: .atomic)
                try? fm.removeItem(at: probe)
                return group
            } catch {
                // 没有 Full Access 时 App Group 可能只读，继续走沙箱。
            }
        }
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fallback = documents.appendingPathComponent("Wenshan", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private func updateContext() {
        model.updateContext(returnKeyType: textDocumentProxy.returnKeyType ?? .default)
    }

    // MARK: - 渲染

    private func render() {
        updateMarkedText()
        updateCandidateBar()
        updateKeys()
    }

    private func updateCandidateBar() {
        let status: String?
        switch model.phase {
        case .loading:
            status = "加载中…"
        case .failed(let reason):
            status = "词表加载失败：\(reason)"
        case .ready:
            status = model.mode == .chinese ? "文山" : "English"
        }
        candidateBar.setCandidates(model.candidates, status: status, preedit: model.preedit)
    }

    private func updateMarkedText() {
        let text = model.isComposing ? model.preedit : ""
        if text.isEmpty {
            clearMarkedText()
            return
        }
        isApplyingText = true
        textDocumentProxy.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0))
        isApplyingText = false
        hasMarkedText = true
    }

    private func clearMarkedText() {
        guard hasMarkedText else { return }
        isApplyingText = true
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        isApplyingText = false
        hasMarkedText = false
    }

    private func updateKeys() {
        shiftButton?.setTitle(model.shift == .locked ? "⇪" : "⇧", for: .normal)
        shiftButton?.setActive(model.shift.isActive)
        modeButton?.setActive(model.mode == .english)
        punctuationButton?.setTitle(model.mode == .chinese ? "。\n，" : ".\n,", for: .normal)
        punctuationButton?.previewText = model.mode == .chinese ? "。" : "."
        returnButton?.setTitle(model.returnKeyTitle, for: .normal)
        returnButton?.accessibilityLabel = model.returnKeyTitle
        returnButton?.setActive(model.isReturnKeyProminent)
    }

    private func toggleSymbols() {
        symbolsOn.toggle()
        renderKeyboardRows()
        render()
    }

    private func apply(_ outcome: KeyboardOutcome, renderNow: Bool = true) {
        switch outcome {
        case .commit(let text):
            isApplyingText = true
            if hasMarkedText {
                textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                hasMarkedText = false
            }
            if !text.isEmpty {
                textDocumentProxy.insertText(text)
            }
            isApplyingText = false
        case .deleteBackward:
            isApplyingText = true
            textDocumentProxy.deleteBackward()
            isApplyingText = false
        case .handled, .idle:
            break
        }
        if renderNow { render() }
    }
}
