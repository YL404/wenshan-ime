import UIKit
import os

private let keyboardLog = Logger(subsystem: "im.wenshan.ios.keyboard", category: "lifecycle")

/// 键盘扩展入口：只做布局、渲染和按键转发，输入语义在 KeyboardModel。
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let candidateBar = CandidateBar()
    private let keyboardStack = UIStackView()
    private let root = UIStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var candidateHeightConstraint: NSLayoutConstraint!
    private var metrics = KeyboardMetrics.make(screen: .zero, isPad: false)

    private var shiftButton: KeyButton?
    private var modeButton: KeyButton?
    private var returnButton: KeyButton?
    private var punctuationButton: KeyButton?
    private var punctuationLongPressUsed = false
    private var symbolsOn = false
    private var hasMarkedText = false
    private var isApplyingText = false

    private let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let symbolRows = ["1234567890", "-/:;()¥&@\"", "。？！，、；：…"]

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
        view.backgroundColor = .systemGray5
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
            self.apply(self.model.select(index))
        }
        candidateBar.onPage = { [weak self] delta in
            guard let self else { return }
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
        return KeyboardMetrics.make(
            screen: screen,
            isPad: traitCollection.userInterfaceIdiom == .pad)
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
        punctuationLongPressUsed = false

        if symbolsOn {
            for row in symbolRows {
                keyboardStack.addArrangedSubview(makeRow(row.map { character in
                    makeKey(
                        title: String(character),
                        identifier: "key_\(character)",
                        action: { [weak self] in
                            guard let self else { return }
                            self.apply(self.model.insert(String(character)))
                        })
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
            background: .secondarySystemBackground)
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

        let delete = makeKey(
            title: "⌫",
            identifier: "key_delete",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.backspace())
            },
            background: .secondarySystemBackground)
        delete.accessibilityLabel = "删除"

        let sideWidth = metrics.letterWidth * 1.3
        return makeProportionalRow([(shift, sideWidth), (lettersRow, nil), (delete, sideWidth)])
    }

    private func makeLetterFunctionRow() -> UIStackView {
        let numbers = makeKey(
            title: "123",
            identifier: "key_symbols",
            action: { [weak self] in self?.toggleSymbols() },
            background: .secondarySystemBackground,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)))
        numbers.accessibilityLabel = "数字和符号"

        let punctuation = makeKey(
            title: "。\n，",
            identifier: "key_punctuation",
            action: { [weak self] in
                guard let self else { return }
                if self.punctuationLongPressUsed {
                    self.punctuationLongPressUsed = false
                    return
                }
                self.apply(self.model.punctuate("."))
            },
            background: .systemBackground,
            font: .systemFont(ofSize: max(11, metrics.keyFontSize - 9)))
        punctuation.titleLabel?.numberOfLines = 2
        punctuation.titleLabel?.textAlignment = .center
        punctuation.accessibilityLabel = "句号，长按逗号"
        punctuation.addGestureRecognizer(UILongPressGestureRecognizer(
            target: self, action: #selector(handlePunctuationLongPress(_:))))
        punctuationButton = punctuation

        let mode = makeKey(
            title: "中\n英",
            identifier: "key_mode",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.toggleMode())
            },
            background: .systemBackground,
            font: .systemFont(ofSize: max(11, metrics.keyFontSize - 9)))
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
            background: .systemBackground,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)))
        space.accessibilityLabel = "空格"

        let returnKey = makeKey(
            title: "换行",
            identifier: "key_return",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.returnKey())
            },
            background: .secondarySystemBackground,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)))
        returnKey.accessibilityLabel = "换行"
        returnButton = returnKey

        let unit = metrics.letterWidth
        return makeProportionalRow([
            (numbers, unit * 1.15),
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
            background: .secondarySystemBackground,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)))
        letters.accessibilityLabel = "字母"

        let mode = makeKey(
            title: "中\n英",
            identifier: "key_mode",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.toggleMode())
            },
            background: .systemBackground,
            font: .systemFont(ofSize: max(11, metrics.keyFontSize - 9)))
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
            background: .systemBackground,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)))
        space.accessibilityLabel = "空格"

        let delete = makeKey(
            title: "⌫",
            identifier: "key_delete",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.backspace())
            },
            background: .secondarySystemBackground)
        delete.accessibilityLabel = "删除"

        let returnKey = makeKey(
            title: "换行",
            identifier: "key_return",
            action: { [weak self] in
                guard let self else { return }
                self.apply(self.model.returnKey())
            },
            background: .secondarySystemBackground,
            font: .systemFont(ofSize: max(15, metrics.keyFontSize - 6)))
        returnKey.accessibilityLabel = "换行"
        returnButton = returnKey

        let unit = metrics.letterWidth
        return makeProportionalRow([
            (letters, unit * 1.15),
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
        background: UIColor = .systemBackground,
        font: UIFont? = nil
    ) -> KeyButton {
        let button = KeyButton(
            title: title,
            identifier: identifier,
            font: font ?? .systemFont(ofSize: metrics.keyFontSize),
            background: background)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
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
        candidateBar.setCandidates(model.candidates, status: status)
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
        returnButton?.setTitle(model.returnKeyTitle, for: .normal)
        returnButton?.accessibilityLabel = model.returnKeyTitle
    }

    @objc private func handlePunctuationLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else {
            if gesture.state == .ended { punctuationLongPressUsed = false }
            return
        }
        punctuationLongPressUsed = true
        apply(model.punctuate(","))
    }

    private func toggleSymbols() {
        symbolsOn.toggle()
        renderKeyboardRows()
        render()
    }

    private func apply(_ outcome: KeyboardOutcome) {
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
        render()
    }
}
