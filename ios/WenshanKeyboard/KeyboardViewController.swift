import UIKit

/// 键盘扩展入口：构建 UI、把按键转发给 KeyboardModel、按状态渲染候选条。
/// 输入逻辑都在 KeyboardModel，这里只做渲染和转发。
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    /// 候选条外层：翻页按钮 + 横向滚动区。
    private let candidateBar = UIStackView()
    private let candidateScroll = UIScrollView()
    /// 滚动区里的候选按钮，按内容宽度排，超出横滑。
    private let candidateStack = UIStackView()
    private let keyboardStack = UIStackView()
    private var shiftButton: UIButton?
    private var pagePrevButton: UIButton?
    private var pageNextButton: UIButton?

    private let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let symbolRows = ["1234567890", "-/:;()¥&@\"", "。？！，、；：…"]

    /// 符号页开关：字母页和符号页切换。
    private var symbolsOn = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        render()
        Task { [weak self] in
            await self?.model.load()
            self?.renderCandidates()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { [weak self] in
            await self?.model.load()
            self?.renderCandidates()
        }
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.reset()
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        renderCandidates()
    }

    /// 外部改了正文（换输入框、光标动了）：丢掉组合，重新渲染。
    override func textDidChange(_ textInput: UITextInput?) {
        model.reset()
        renderCandidates()
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        model.reset()
        renderCandidates()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        model.reset()
        renderCandidates()
    }

    // MARK: - UI 构建

    private func buildUI() {
        view.backgroundColor = .systemGray5
        let height = view.heightAnchor.constraint(equalToConstant: 270)
        height.priority = .defaultHigh
        height.isActive = true

        candidateBar.axis = .horizontal
        candidateBar.spacing = 4
        candidateBar.alignment = .fill
        candidateBar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.alwaysBounceHorizontal = true

        candidateStack.axis = .horizontal
        candidateStack.spacing = 4
        candidateStack.alignment = .center
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateStack)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor, constant: 6),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor, constant: -6),
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor),
        ])

        let pagePrev = keyButton("‹", label: "上一页") { [weak self] in
            guard let self else { return }
            self.apply(self.model.page(-1))
        }
        let pageNext = keyButton("›", label: "下一页") { [weak self] in
            guard let self else { return }
            self.apply(self.model.page(1))
        }
        pagePrev.widthAnchor.constraint(equalToConstant: 30).isActive = true
        pageNext.widthAnchor.constraint(equalToConstant: 30).isActive = true
        pagePrevButton = pagePrev
        pageNextButton = pageNext
        candidateBar.addArrangedSubview(pagePrev)
        candidateBar.addArrangedSubview(candidateScroll)
        candidateBar.addArrangedSubview(pageNext)

        keyboardStack.axis = .vertical
        keyboardStack.spacing = 6
        keyboardStack.distribution = .fillEqually
        keyboardStack.alignment = .fill
        renderKeyboardRows()

        let shift = keyButton("⇧", label: "大写") { [weak self] in
            self?.model.toggleShift()
            self?.render()
        }
        shiftButton = shift

        let bottom = UIStackView(arrangedSubviews: [
            keyButton("🌐", label: "切换键盘") { [weak self] in
                self?.advanceToNextInputMode()
            },
            shift,
            keyButton("符", label: "符号") { [weak self] in
                self?.toggleSymbols()
            },
            keyButton("空格", label: "空格") { [weak self] in
                guard let self else { return }
                apply(self.model.space())
            },
            keyButton("⌫", label: "删除") { [weak self] in
                guard let self else { return }
                apply(self.model.backspace())
            },
            keyButton("换行", label: "换行") { [weak self] in
                guard let self else { return }
                apply(self.model.returnKey())
            },
        ])
        bottom.axis = .horizontal
        bottom.spacing = 4
        bottom.distribution = .fillEqually
        bottom.alignment = .fill
        // 底行固定高度，字母三行拿剩余空间（约 49pt/行，接近系统键盘）。
        bottom.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let root = UIStackView(arrangedSubviews: [candidateBar, keyboardStack, bottom])
        root.axis = .vertical
        root.spacing = 6
        root.alignment = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
    }

    private func keyButton(_ title: String, label: String? = nil, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = .secondarySystemBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.accessibilityLabel = label ?? title
        button.addAction(UIAction { _ in
            action()
        }, for: .touchUpInside)
        return button
    }

    /// 按当前页（字母/符号）重建键盘行。字母键进引擎组词，符号键直接插入。
    private func renderKeyboardRows() {
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in symbolsOn ? symbolRows : letterRows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually
            rowStack.alignment = .fill
            for ch in row {
                rowStack.addArrangedSubview(keyButton(String(ch)) { [weak self] in
                    guard let self else { return }
                    if self.symbolsOn {
                        self.apply(self.model.insert(String(ch)))
                    } else {
                        self.type(String(ch))
                    }
                })
            }
            keyboardStack.addArrangedSubview(rowStack)
            rowStack.widthAnchor.constraint(equalTo: keyboardStack.widthAnchor).isActive = true
        }
    }

    // MARK: - 按键转发

    private func type(_ key: String) {
        apply(model.type(key, shift: model.shiftOn))
    }

    /// 字母页和符号页切换：重建键盘行。
    private func toggleSymbols() {
        symbolsOn.toggle()
        renderKeyboardRows()
    }

    // MARK: - 渲染

    private func render() {
        let buffer = model.buffer
        textDocumentProxy.setMarkedText(buffer, selectedRange: NSRange(location: buffer.utf16.count, length: 0))
        renderCandidates()
        updateShiftVisual()
    }

    private func renderCandidates() {
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasCandidates = !model.candidates.isEmpty
        pagePrevButton?.isHidden = !hasCandidates
        pageNextButton?.isHidden = !hasCandidates
        if !hasCandidates {
            candidateStack.addArrangedSubview(makeStatusLabel())
            return
        }
        for (index, text) in model.candidates.enumerated() {
            var config = UIButton.Configuration.plain()
            config.title = text
            config.baseForegroundColor = .label
            config.titleLineBreakMode = .byClipping
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 4, trailing: 6)
            let button = UIButton(configuration: config)
            button.titleLabel?.font = .systemFont(ofSize: 20)
            button.accessibilityLabel = text
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.apply(self.model.select(index))
            }, for: .touchUpInside)
            candidateStack.addArrangedSubview(button)
        }
    }

    /// 候选条占位：按引擎状态显示加载中、失败原因或默认文案。
    private func makeStatusLabel() -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        switch model.phase {
        case .loading:
            label.text = "加载中…"
            label.textColor = .secondaryLabel
        case .failed(let reason):
            label.text = "词表加载失败：\(reason)"
            label.textColor = .systemRed
        case .ready:
            label.text = "文山"
            label.textColor = .secondaryLabel
        }
        return label
    }

    private func updateShiftVisual() {
        guard let shiftButton else { return }
        shiftButton.configuration?.baseBackgroundColor = model.shiftOn ? .systemBlue : .secondarySystemBackground
        shiftButton.configuration?.baseForegroundColor = model.shiftOn ? .white : .label
    }

    private func apply(_ outcome: KeyboardOutcome) {
        switch outcome {
        case .commit(let text):
            // 组合已处理：先摘掉 marked text 再上屏，避免正文和组合区脱节；
            // 连续选词剩下的组合由 render() 重新挂上。
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            if !text.isEmpty {
                textDocumentProxy.insertText(text)
            }
        case .deleteBackward:
            textDocumentProxy.deleteBackward()
        case .handled, .idle:
            break
        }
        render()
    }
}
