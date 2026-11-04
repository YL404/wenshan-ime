import UIKit
import os

private let keyboardLog = Logger(subsystem: "im.wenshan.ios.keyboard", category: "lifecycle")

/// 键盘扩展入口：只做布局、渲染和按键转发，输入语义在 KeyboardModel。
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let toolbarBar = ToolbarBar()
    private let candidateBar = CandidateBar()
    private let candidatePanel = CandidatePanel()
    private let symbolPanel = SymbolPanelView()
    private let topBar = UIView()
    private let keyboardStack = UIStackView()
    private let root = UIStackView()
    private let keyPreview = KeyPreviewView()
    private let keyEvents = KeyEventQueue()
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var heightConstraint: NSLayoutConstraint!
    private var topBarHeightConstraint: NSLayoutConstraint!
    private var metrics = KeyboardMetrics.make(screen: .zero, width: 0, isPad: false, isFloating: false)

    private var shiftButton: KeyButton?
    private var modeButton: KeyButton?
    private var returnButton: KeyButton?
    private var punctuationButton: KeyButton?
    private weak var previewedButton: KeyButton?
    private var layer: Layer = .letters
    private var hasMarkedText = false
    private var isApplyingText = false
    private var isCandidatePanelOpen = false
    private var isSymbolPanelOpen = false

    private enum Layer {
        case letters
        case numbers
    }

    private let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardLog.info("viewDidLoad")
        // 规则层判断中英文之间要不要补空格，读的是宿主正文里光标前的字符。
        model.contextBefore = { [weak self] in
            self?.textDocumentProxy.documentContextBeforeInput ?? ""
        }
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
        closeCandidatePanel()
        closeSymbolPanel()
        layer = .letters
        renderKeyboardRows()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboardLog.info("viewWillDisappear")
        super.viewWillDisappear(animated)
        model.flush()
        model.reset()
        clearMarkedText()
        hidePreview()
        keyEvents.reset()
        closeCandidatePanel()
        closeSymbolPanel()
        candidateBar.setCandidates([])
    }

    override func textDidChange(_ textInput: UITextInput?) {
        // 同一 App 里换输入框只会走到这里，不会重新 viewWillAppear，
        // 回车键的标题和高亮要跟着新输入框的 returnKeyType 走。
        updateContext()
        updateKeys()
        guard !isApplyingText, !isOwnComposition() else { return }
        handleExternalChange()
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        handleExternalChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        handleExternalChange()
    }

    /// 宿主改了正文或光标（点到别处、粘贴、App 自己改内容）：只在组合态重置，
    /// render 会顺带清掉 marked text。
    private func handleExternalChange() {
        closeSymbolPanel()
        guard model.isComposing else { return }
        model.reset()
        render()
    }

    /// 部分宿主会在 setMarkedText 之后异步回调 textDidChange，这时 isApplyingText
    /// 早已复位。光标前仍以当前预编辑串结尾，说明是自己的组合，不算外部改动。
    private func isOwnComposition() -> Bool {
        guard model.isComposing, hasMarkedText else { return false }
        return textDocumentProxy.documentContextBeforeInput?.hasSuffix(model.preedit) ?? false
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

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBarHeightConstraint = topBar.heightAnchor.constraint(equalToConstant: metrics.candidateHeight)
        topBarHeightConstraint.isActive = true

        toolbarBar.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(toolbarBar)
        topBar.addSubview(candidateBar)
        NSLayoutConstraint.activate([
            toolbarBar.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            toolbarBar.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            toolbarBar.topAnchor.constraint(equalTo: topBar.topAnchor),
            toolbarBar.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            candidateBar.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            candidateBar.topAnchor.constraint(equalTo: topBar.topAnchor),
            candidateBar.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
        ])
        candidateBar.isHidden = true

        candidateBar.setCandidateFont(.systemFont(ofSize: metrics.candidateFontSize))
        candidateBar.onSelect = { [weak self] index in
            guard let self else { return }
            self.closeCandidatePanel()
            self.closeSymbolPanel()
            self.playSelectionFeedback()
            self.apply(self.model.select(index))
        }
        candidateBar.onSelectChar = { [weak self] index, last in
            guard let self else { return }
            self.closeCandidatePanel()
            self.closeSymbolPanel()
            self.playSelectionFeedback()
            self.apply(self.model.selectChar(index, last: last))
        }
        candidateBar.onExpand = { [weak self] in
            self?.toggleCandidatePanel()
        }
        candidateBar.onDismiss = { [weak self] in
            guard let self else { return }
            self.closeCandidatePanel()
            self.closeSymbolPanel()
            self.dismissKeyboard()
        }
        toolbarBar.onToggleFullWidth = { [weak self] in
            guard let self else { return }
            self.apply(self.model.toggleFullWidth())
        }
        toolbarBar.onDismiss = { [weak self] in
            guard let self else { return }
            self.closeCandidatePanel()
            self.closeSymbolPanel()
            self.dismissKeyboard()
        }
        toolbarBar.setStatus("加载中…")
        toolbarBar.setFullWidth(model.fullWidth)
        toolbarBar.setFullWidthEnabled(false)
        candidateBar.setCandidates([])

        candidatePanel.isHidden = true
        candidatePanel.onSelect = { [weak self] index in
            guard let self else { return }
            self.closeCandidatePanel()
            self.closeSymbolPanel()
            self.playSelectionFeedback()
            self.apply(self.model.selectGlobal(index))
        }

        symbolPanel.isHidden = true
        symbolPanel.onInsert = { [weak self] symbol in
            guard let self else { return }
            self.closeSymbolPanel()
            self.playSelectionFeedback()
            self.apply(self.model.insert(symbol))
        }
        symbolPanel.onClose = { [weak self] in
            self?.closeSymbolPanel()
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
        root.addArrangedSubview(topBar)
        root.addArrangedSubview(keyboardStack)
        view.addSubview(root)
        view.addSubview(candidatePanel)
        view.addSubview(symbolPanel)
        view.addSubview(keyPreview)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),

            candidatePanel.leadingAnchor.constraint(equalTo: keyboardStack.leadingAnchor),
            candidatePanel.trailingAnchor.constraint(equalTo: keyboardStack.trailingAnchor),
            candidatePanel.topAnchor.constraint(equalTo: keyboardStack.topAnchor),
            candidatePanel.bottomAnchor.constraint(equalTo: keyboardStack.bottomAnchor),

            symbolPanel.leadingAnchor.constraint(equalTo: keyboardStack.leadingAnchor),
            symbolPanel.trailingAnchor.constraint(equalTo: keyboardStack.trailingAnchor),
            symbolPanel.topAnchor.constraint(equalTo: keyboardStack.topAnchor),
            symbolPanel.bottomAnchor.constraint(equalTo: keyboardStack.bottomAnchor),
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
        topBarHeightConstraint.constant = next.candidateHeight
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

        switch layer {
        case .numbers:
            keyboardStack.addArrangedSubview(makeNumberRow(["1", "2", "3"], trailing: makeDeleteKey()))
            keyboardStack.addArrangedSubview(makeNumberRow(["4", "5", "6"], trailing: makeNumberSpaceKey()))
            keyboardStack.addArrangedSubview(makeNumberRow(["7", "8", "9"], trailing: makeNumberReturnKey()))
            keyboardStack.addArrangedSubview(makeNumberBottomRow())
        case .letters:
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

    private func makeNumberRow(_ digits: [String], trailing: KeyButton) -> UIStackView {
        var keys = digits.map { makeNumberKey($0) }
        keys.append(trailing)
        return makeRow(keys)
    }

    private func makeNumberKey(_ digit: String) -> KeyButton {
        let key = makeKey(
            title: digit,
            identifier: "key_number_\(digit)",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.insert(digit))
            },
            font: .systemFont(ofSize: metrics.keyFontSize + 1))
        key.accessibilityLabel = "数字 \(digit)"
        return key
    }

    private func makeNumberSpaceKey() -> KeyButton {
        let space = makeKey(
            title: "空格",
            identifier: "key_space",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.space())
            },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        space.accessibilityLabel = "空格"
        configureSpaceKey(space)
        return space
    }

    private func makeNumberReturnKey() -> KeyButton {
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
        return returnKey
    }

    private func makeNumberBottomRow() -> UIStackView {
        let dot = makeKey(
            title: ".",
            identifier: "key_number_dot",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.insert("."))
            },
            font: .systemFont(ofSize: metrics.keyFontSize + 1))
        dot.accessibilityLabel = "小数点"

        let symbols = makeKey(
            title: "符",
            identifier: "key_symbol_panel",
            action: { [weak self] in self?.showSymbols() },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        symbols.accessibilityLabel = "符号"

        let letters = makeKey(
            title: "ABC",
            identifier: "key_letters",
            action: { [weak self] in self?.showLetters() },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        letters.accessibilityLabel = "字母"

        return makeRow([dot, makeNumberKey("0"), symbols, letters])
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
            action: { [weak self] in self?.showNumbers() },
            background: KeyboardPalette.functionKey,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)),
            showsPreview: false)
        numbers.accessibilityLabel = "数字"
        numbers.accessibilityHint = "长按输入符号"
        numbers.onLongPress = { [weak self] in
            self?.showSymbols()
            return true
        }

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

        let unit = metrics.letterWidth
        var items: [(UIView, CGFloat?)] = [
            (numbers, max(44, unit * 1.15)),
            (punctuation, max(44, unit * 0.65)),
            (space, nil),
            (mode, max(44, unit)),
            (returnKey, max(44, unit * 1.15)),
        ]
        if needsInputModeSwitchKey {
            items.insert((makeGlobeKey(), 44), at: 1)
        }
        return makeProportionalRow(items)
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
        updateTopBar()
        updateCandidateBar()
        updateKeys()
    }

    private func updateTopBar() {
        let composing = model.isComposing
        toolbarBar.isHidden = composing
        candidateBar.isHidden = !composing

        switch model.phase {
        case .loading:
            toolbarBar.setStatus("加载中…")
        case .failed(let reason):
            toolbarBar.setStatus("词表加载失败", isError: true, hint: reason)
        case .ready:
            toolbarBar.setStatus(model.mode == .chinese ? "中文" : "English")
        }
        toolbarBar.setFullWidth(model.fullWidth)
        toolbarBar.setFullWidthEnabled(model.phase == .ready)

        if !composing {
            closeCandidatePanel()
        }
    }

    private func updateCandidateBar() {
        candidateBar.setCandidates(model.candidates)
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

    private func showNumbers() {
        closeCandidatePanel()
        closeSymbolPanel()
        layer = .numbers
        renderKeyboardRows()
        render()
    }

    private func showLetters() {
        closeCandidatePanel()
        closeSymbolPanel()
        layer = .letters
        renderKeyboardRows()
        render()
    }

    private func showSymbols() {
        closeCandidatePanel()
        guard !isSymbolPanelOpen else { return }
        hidePreview()
        symbolPanel.isHidden = false
        isSymbolPanelOpen = true
        updateKeyboardStackInteraction()
        UIAccessibility.post(notification: .screenChanged, argument: symbolPanel)
    }

    private func closeSymbolPanel() {
        guard isSymbolPanelOpen else { return }
        isSymbolPanelOpen = false
        symbolPanel.isHidden = true
        updateKeyboardStackInteraction()
        UIAccessibility.post(
            notification: .screenChanged,
            argument: candidateBar.isHidden ? toolbarBar : candidateBar)
    }

    private func updateKeyboardStackInteraction() {
        let blocked = isCandidatePanelOpen || isSymbolPanelOpen
        keyboardStack.accessibilityElementsHidden = blocked
        keyboardStack.isUserInteractionEnabled = !blocked
    }

    private func toggleCandidatePanel() {
        if isCandidatePanelOpen {
            closeCandidatePanel()
            return
        }
        closeSymbolPanel()
        guard model.isComposing else { return }
        let all = model.allCandidates()
        guard !all.isEmpty else { return }
        candidatePanel.setCandidates(all)
        candidatePanel.isHidden = false
        isCandidatePanelOpen = true
        updateKeyboardStackInteraction()
        candidateBar.setExpanded(true)
        UIAccessibility.post(notification: .screenChanged, argument: candidatePanel)
    }

    private func closeCandidatePanel() {
        guard isCandidatePanelOpen else { return }
        isCandidatePanelOpen = false
        candidatePanel.isHidden = true
        candidatePanel.setCandidates([])
        updateKeyboardStackInteraction()
        candidateBar.setExpanded(false)
        UIAccessibility.post(
            notification: .screenChanged,
            argument: candidateBar.isHidden ? toolbarBar : candidateBar)
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
