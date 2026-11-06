import UIKit
import os

private let keyboardLog = Logger(subsystem: "im.wenshan.ios.keyboard", category: "lifecycle")

/// 键盘扩展入口：生命周期、布局、渲染和按键动作分发。输入语义在 KeyboardModel，
/// 键区怎么排在 KeyRowsBuilder，往宿主正文写东西在 DocumentWriter。
final class KeyboardViewController: UIInputViewController {
    /// 盖在键区上的面板，同一时间最多一个。
    private enum Overlay {
        case none
        case candidates
        case symbols
    }

    private let model = KeyboardModel()
    private lazy var writer = DocumentWriter { [unowned self] in self.textDocumentProxy }
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

    private var keys = KeyRows()
    private weak var previewedButton: KeyButton?
    private var layer: KeyboardLayer = .letters
    private var overlay: Overlay = .none

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardLog.info("viewDidLoad")
        // 规则层判断中英文之间要不要补空格，读的是宿主正文里光标前的字符。
        model.contextBefore = { [weak self] in self?.writer.contextBefore ?? "" }
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
        } else {
            model.reloadUserDataIfChanged()
        }
        setOverlay(.none)
        layer = .letters
        renderKeyboardRows()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboardLog.info("viewWillDisappear")
        super.viewWillDisappear(animated)
        model.flush()
        model.reset()
        writer.clearMarkedText()
        hidePreview()
        keyEvents.reset()
        setOverlay(.none)
        candidateBar.setCandidates([])
    }

    override func textDidChange(_ textInput: UITextInput?) {
        // 同一 App 里换输入框只会走到这里，不会重新 viewWillAppear，
        // 回车键的标题和高亮要跟着新输入框的 returnKeyType 走。
        updateContext()
        updateKeys()
        guard !writer.isWriting, !writer.endsWithMarkedText(model.preedit) else { return }
        handleExternalChange()
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        handleExternalChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        handleExternalChange()
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

    /// 宿主改了正文或光标（点到别处、粘贴、App 自己改内容）：只在组合态重置，
    /// render 会顺带清掉 marked text。
    private func handleExternalChange() {
        dismissOverlay(.symbols)
        guard model.isComposing else { return }
        model.reset()
        render()
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
            self.pick(self.model.select(index))
        }
        candidateBar.onSelectChar = { [weak self] index, last in
            guard let self else { return }
            self.pick(self.model.selectChar(index, last: last))
        }
        candidateBar.onExpand = { [weak self] in
            self?.toggleCandidatePanel()
        }
        candidateBar.onDismiss = { [weak self] in
            self?.setOverlay(.none)
            self?.dismissKeyboard()
        }
        toolbarBar.onToggleFullWidth = { [weak self] in
            guard let self else { return }
            self.apply(self.model.toggleFullWidth())
        }
        toolbarBar.onDismiss = { [weak self] in
            self?.setOverlay(.none)
            self?.dismissKeyboard()
        }
        toolbarBar.setStatus("加载中…")
        toolbarBar.setFullWidth(model.fullWidth)
        toolbarBar.setFullWidthEnabled(false)
        candidateBar.setCandidates([])

        candidatePanel.isHidden = true
        candidatePanel.onSelect = { [weak self] index in
            guard let self else { return }
            self.pick(self.model.selectGlobal(index))
        }

        symbolPanel.isHidden = true
        symbolPanel.onInsert = { [weak self] symbol in
            guard let self else { return }
            self.pick(self.model.insert(symbol))
        }
        symbolPanel.onClose = { [weak self] in
            self?.dismissOverlay(.symbols)
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
        // viewDidLoad 时还没挂到窗口，先按视图自身大小估；挂上窗口后
        // viewDidLayoutSubviews 会用真实屏幕尺寸重算。
        let screen = view.window?.windowScene?.screen.bounds.size ?? view.bounds.size
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
        guard next != metrics else { return }
        metrics = next
        heightConstraint.constant = next.totalHeight
        topBarHeightConstraint.constant = next.candidateHeight
        root.spacing = next.gap
        keyboardStack.spacing = next.gap
        candidateBar.setCandidateFont(.systemFont(ofSize: next.candidateFontSize))
        renderKeyboardRows()
        view.setNeedsLayout()
    }

    /// 按当前页重建键区。只在切页/换方向时调用，不在每次按键时调用。
    private func renderKeyboardRows() {
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hidePreview()
        keys = KeyRowsBuilder(
            metrics: metrics,
            showsGlobeKey: needsInputModeSwitchKey,
            keyEvents: keyEvents,
            host: self
        ).build(layer)
        keys.rows.forEach(keyboardStack.addArrangedSubview)
    }

    private func showLayer(_ next: KeyboardLayer) {
        setOverlay(.none)
        layer = next
        renderKeyboardRows()
        render()
    }

    // MARK: - 面板

    /// 切换盖在键区上的面板：处理显隐、键区交互和旁白焦点。
    private func setOverlay(_ next: Overlay) {
        guard next != overlay else { return }
        if overlay == .candidates {
            candidatePanel.setCandidates([])
            candidateBar.setExpanded(false)
        }
        overlay = next
        candidatePanel.isHidden = next != .candidates
        symbolPanel.isHidden = next != .symbols
        keyboardStack.accessibilityElementsHidden = next != .none
        keyboardStack.isUserInteractionEnabled = next == .none
        let focus: UIView
        switch next {
        case .candidates:
            candidateBar.setExpanded(true)
            focus = candidatePanel
        case .symbols:
            hidePreview()
            focus = symbolPanel
        case .none:
            focus = candidateBar.isHidden ? toolbarBar : candidateBar
        }
        UIAccessibility.post(notification: .screenChanged, argument: focus)
    }

    /// 只在指定面板开着时关掉它。
    private func dismissOverlay(_ which: Overlay) {
        if overlay == which {
            setOverlay(.none)
        }
    }

    private func toggleCandidatePanel() {
        if overlay == .candidates {
            setOverlay(.none)
            return
        }
        let all = model.isComposing ? model.allCandidates() : []
        guard !all.isEmpty else {
            dismissOverlay(.symbols)
            return
        }
        candidatePanel.setCandidates(all)
        setOverlay(.candidates)
    }

    /// 从候选条、全部候选或符号面板选中一项：关面板、触感、上屏。
    private func pick(_ outcome: KeyboardOutcome) {
        setOverlay(.none)
        playSelectionFeedback()
        apply(outcome)
    }

    // MARK: - 按键反馈

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

    // MARK: - 引擎和上下文

    private func loadEngine() {
        let directory = AppGroup.keyboardDataDirectory()
        keyboardLog.info("loadEngine data=\(directory.path, privacy: .public)")
        Task { [weak self] in
            await self?.model.load(dataDirectory: directory)
            if case .failed(let reason) = self?.model.phase {
                keyboardLog.error("engine failed: \(reason, privacy: .public)")
            }
            self?.render()
        }
    }

    private func updateContext() {
        model.updateContext(returnKeyType: textDocumentProxy.returnKeyType ?? .default)
    }

    // MARK: - 渲染

    private func render() {
        writer.setMarkedText(model.isComposing ? model.preedit : "")
        updateTopBar()
        candidateBar.setCandidates(model.candidates)
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
            dismissOverlay(.candidates)
        }
    }

    private func updateKeys() {
        let chinese = model.mode == .chinese
        keys.shift?.setTitle(model.shift == .locked ? "⇪" : "⇧", for: .normal)
        keys.shift?.setActive(model.shift.isActive)
        keys.mode?.setActive(!chinese)
        keys.punctuation?.setTitle(chinese ? "。\n，" : ".\n,", for: .normal)
        keys.punctuation?.previewText = chinese ? "。" : "."
        keys.returnKey?.setTitle(model.returnKeyTitle, for: .normal)
        keys.returnKey?.accessibilityLabel = model.returnKeyTitle
        keys.returnKey?.setActive(model.isReturnKeyProminent)
    }

    private func apply(_ outcome: KeyboardOutcome, renderNow: Bool = true) {
        switch outcome {
        case .commit(let text):
            writer.insert(text)
        case .deleteBackward:
            writer.deleteBackward()
        case .handled, .idle:
            break
        }
        if renderNow { render() }
    }

    private func delete(times: Int) {
        guard times > 0 else { return }
        for _ in 0..<times {
            apply(model.backspace(), renderNow: false)
        }
        render()
    }
}

extension KeyboardViewController: KeyRowsHost {
    func perform(_ action: KeyAction) {
        switch action {
        case .type(let key):
            apply(model.type(key))
        case .insert(let text):
            apply(model.insert(text))
        case .punctuate(let ch):
            apply(model.punctuate(ch))
        case .space:
            apply(model.space())
        case .returnKey:
            apply(model.returnKey())
        case .newline:
            apply(.commit("\n"))
        case .backspace:
            apply(model.backspace())
        case .deleteBackward(let times):
            delete(times: times)
        case .moveCursor(let steps):
            guard steps != 0 else { return }
            writer.moveCursor(by: steps)
            playSelectionFeedback()
        case .cursorDrag:
            break
        case .shift:
            model.shiftTapped()
            render()
        case .toggleMode:
            apply(model.toggleMode())
        case .showNumbers:
            showLayer(.numbers)
        case .showLetters:
            showLayer(.letters)
        case .showSymbols:
            setOverlay(.symbols)
        case .nextInputMode:
            advanceToNextInputMode()
        }
    }

    func performLongPress(_ action: KeyAction) -> Bool {
        switch action {
        case .newline:
            // 组合态回车是「确认」，默认回车键本来就换行，这两种情况长按不另做事。
            guard !model.isComposing, model.returnKeyType != .default else { return false }
        case .cursorDrag:
            // 组合态空格是上屏首选，不拖光标。
            return !model.isComposing
        default:
            break
        }
        perform(action)
        return true
    }

    func keyPressChanged(_ key: KeyButton, pressed: Bool) {
        if pressed {
            playKeyFeedback()
            showPreview(for: key)
        } else {
            hidePreview(for: key)
        }
    }
}
