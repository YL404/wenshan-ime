import UIKit
import os
import WenshanCore

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
    private var keyFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var keyFeedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle = .medium
    private var keyFeedbackIntensity: CGFloat? = 0.8
    private let diagnostic = KeyboardDiagnostic()
    private var heightConstraint: NSLayoutConstraint!
    private var topBarHeightConstraint: NSLayoutConstraint!
    private var metrics = KeyboardMetrics.make(screen: .zero, width: 0, isPad: false, isFloating: false)

    private var keys = KeyRows()
    private weak var previewedButton: KeyButton?
    private var layer: KeyboardLayer = .letters
    private var overlay: Overlay = .none
    private var candidatePanelItems: [String] = []

    override func loadView() {
        // 原生皮肤：键盘底板交给 UIInputView 的系统材质，不再画自己的背景。
        let inputView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = false
        view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardLog.info("viewDidLoad")
        // 规则层判断中英文之间要不要补空格，读的是宿主正文里光标前的字符。
        model.contextBefore = { [weak self] in self?.writer.contextBefore ?? "" }
        model.contextAfter = { [weak self] in self?.writer.contextAfter ?? "" }
        buildUI()
        loadEngine()
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitPreferredContentSizeCategory.self,
        ]) { (self: KeyboardViewController, _) in
            self.traitsDidChange()
        }
        diagnostic.log("keyboard_loaded", memory: true)
        render()
        diagnostic.log("keyboard_built", memory: true)
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
            applySettings()
        }
        setOverlay(.none)
        layer = .letters
        renderKeyboardRows()
        registerKeyGeometry()
        render()
        diagnostic.log("keyboard_shown", memory: true)
        diagnostic.log("focus_in", memory: true)
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
        diagnostic.log("keyboard_hidden", memory: true)
    }

    override func willTransition(
        to newCollection: UITraitCollection,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.willTransition(to: newCollection, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.traitsDidChange()
            self?.registerKeyGeometry()
        }
    }

    private func traitsDidChange() {
        candidateBar.setCandidateFont(currentCandidateFont())
        candidatePanel.setFont(currentCandidateFont())
        updateKeys()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        diagnostic.log("memory_warning", memory: true)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        // 同一 App 里换输入框只会走到这里，不会重新 viewWillAppear，
        // 回车键的标题和高亮要跟着新输入框的 returnKeyType 走。
        updateContext()
        updateKeys()
        guard !writer.isOwnAsyncChange(preedit: model.preedit) else { return }
        handleExternalChange()
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        guard !writer.isOwnAsyncChange(preedit: model.preedit) else { return }
        handleExternalChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        guard !writer.isOwnAsyncChange(preedit: model.preedit) else { return }
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
        registerKeyGeometry()
    }

    /// 宿主改了正文或光标（点到别处、粘贴、App 自己改内容）：只在组合态重置，
    /// render 会顺带清掉 marked text。
    private func handleExternalChange() {
        dismissOverlay(.symbols)
        model.editorDidChange()
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

        candidateBar.setCandidateFont(currentCandidateFont())
        candidatePanel.setFont(currentCandidateFont())
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
        candidateBar.onManage = { [weak self] index, pin in
            self?.manageCandidate(index, pin: pin)
        }
        toolbarBar.onToggleFullWidth = { [weak self] in
            guard let self else { return }
            self.apply(self.model.toggleFullWidth())
        }
        toolbarBar.onDismiss = { [weak self] in
            self?.setOverlay(.none)
            self?.dismissKeyboard()
        }
        candidateBar.setCandidates([])

        candidatePanel.isHidden = true
        candidatePanel.onSelect = { [weak self] index in
            guard let self else { return }
            self.pick(self.model.selectGlobal(index))
        }
        candidatePanel.menuProvider = { [weak self] index in
            self?.candidateMenu(for: index)
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
        view.backgroundColor = .clear
        topBar.backgroundColor = .clear
        keyboardStack.backgroundColor = .clear
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
        candidateBar.setCandidateFont(currentCandidateFont())
        candidatePanel.setFont(currentCandidateFont())
        renderKeyboardRows()
        view.setNeedsLayout()
    }

    /// 候选字号按 Dynamic Type 缩放，键帽字号固定（键帽触摸目标不随字号变）。
    private func currentCandidateFont() -> UIFont {
        let size = KeyboardSettings.candidateFontSize(
            base: metrics.candidateFontSize, traits: traitCollection,
            isPad: traitCollection.userInterfaceIdiom == .pad)
        return .systemFont(ofSize: size)
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
        for button in allKeyButtons(in: keys.rows) {
            button.keyArea = keyboardStack
        }
    }

    /// 把 26 个字母键的矩形注册给规则层，触点纠错按真实落点加权。
    private func registerKeyGeometry() {
        guard layer == .letters, keyboardStack.bounds.width > 0 else { return }
        var frames: [KeyFrame?] = Array(repeating: nil, count: 26)
        for button in allKeyButtons(in: keys.rows) {
            guard let letter = button.keyLetter,
                  button.bounds.width > 0, button.bounds.height > 0
            else { continue }
            let rect = button.convert(button.bounds, to: keyboardStack)
            frames[Int(letter - UInt8(ascii: "a"))] = KeyFrame(
                x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
        guard frames.allSatisfy({ $0 != nil }) else { return }
        model.setKeyFrames(frames)
    }

    /// Z 行字母键包在嵌套堆栈里，递归收集键区里全部 KeyButton。
    private func allKeyButtons(in views: [UIView]) -> [KeyButton] {
        var buttons: [KeyButton] = []
        var stack = views
        while let current = stack.popLast() {
            if let button = current as? KeyButton {
                buttons.append(button)
            } else {
                stack.append(contentsOf: current.subviews)
            }
        }
        return buttons
    }

    private func showLayer(_ next: KeyboardLayer) {
        setOverlay(.none)
        layer = next
        renderKeyboardRows()
        view.setNeedsLayout()
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
        // 面板不画底板时，把键帽一起隐掉，只留 UIInputView 的系统键盘材质。
        // 键区仍占着布局，收起面板后原位恢复。
        keyboardStack.alpha = next == .none ? 1 : 0
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
        candidatePanelItems = all
        candidatePanel.setCandidates(all)
        setOverlay(.candidates)
    }

    /// 候选长按菜单：取首/尾字，以及置顶或删除词条。
    private func candidateMenu(for index: Int) -> UIMenu? {
        guard index < candidatePanelItems.count else { return nil }
        let text = candidatePanelItems[index]
        var actions: [UIMenuElement] = []
        if text.count > 1 {
            actions.append(UIAction(title: "取首字") { [weak self] _ in
                self?.pick(self?.model.selectCharGlobal(index, last: false) ?? .idle)
            })
            actions.append(UIAction(title: "取尾字") { [weak self] _ in
                self?.pick(self?.model.selectCharGlobal(index, last: true) ?? .idle)
            })
        }
        actions.append(UIAction(title: "置顶此候选") { [weak self] _ in
            self?.manageCandidate(index, pin: true)
        })
        actions.append(UIAction(title: "删除此候选", attributes: .destructive) { [weak self] _ in
            self?.manageCandidate(index, pin: false)
        })
        return UIMenu(children: actions)
    }

    /// 候选条用当前页索引，展开面板用全量索引，两者都交给规则层管理。
    private func manageCandidate(_ index: Int, pin: Bool) {
        let text = overlay == .candidates
            ? (candidatePanelItems.indices.contains(index) ? candidatePanelItems[index] : nil)
            : (model.candidates.indices.contains(index) ? model.candidates[index] : nil)
        guard let text else { return }
        guard model.manage(text, pin: pin) else { return }
        playSelectionFeedback()
        if overlay == .candidates {
            let all = model.allCandidates()
            candidatePanelItems = all
            candidatePanel.setCandidates(all)
        }
        render()
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
        if let intensity = keyFeedbackIntensity {
            keyFeedback.impactOccurred(intensity: intensity)
        } else {
            keyFeedback.impactOccurred()
        }
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
        model.load(dataDirectory: directory)
        applySettings()
        if case .failed(let reason) = model.phase {
            keyboardLog.error("engine failed: \(reason, privacy: .public)")
        }
    }

    /// 每次键盘出现把共享偏好应用到规则层和 UI，不重建引擎会话。
    private func applySettings() {
        let startup = KeyboardSettings.startupMode
        model.setMode(startup)
        model.setCandidatePageSize(KeyboardSettings.candidatePageSize)
        model.setSpaceRevertsPunctuation(KeyboardSettings.spaceRevertsPunctuation)
        model.setSmartPunctuation(true)
        let (style, intensity) = KeyboardSettings.hapticStyle()
        if style != keyFeedbackStyle {
            keyFeedback = UIImpactFeedbackGenerator(style: style)
            keyFeedbackStyle = style
        }
        keyFeedbackIntensity = intensity
        diagnostic.isEnabled = KeyboardSettings.diagnosticLog
        candidateBar.setCandidateFont(currentCandidateFont())
        candidatePanel.setFont(currentCandidateFont())
        updateKeys()
        diagnostic.log("preferences_applied", memory: true)
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
        keys.mode?.setTitle(chinese ? "中" : "英", for: .normal)
        keys.mode?.accessibilityLabel = chinese ? "中文模式，点击切换英文" : "英文模式，点击切换中文"
        keys.punctuation?.setTitle(chinese ? "。\n，" : ".\n,", for: .normal)
        keys.punctuation?.previewText = chinese ? "。" : "."
        keys.returnKey?.setTitle(model.returnKeyTitle, for: .normal)
        keys.returnKey?.accessibilityLabel = model.returnKeyTitle
        keys.returnKey?.setActive(model.isReturnKeyProminent)
    }

    private func apply(_ outcome: KeyboardOutcome, renderNow: Bool = true) {
        switch outcome {
        case .commit(let text, let deleteBefore, let caretOffset):
            if deleteBefore > 0 { writer.deleteBackward(times: deleteBefore) }
            writer.insert(text)
            if caretOffset != 0 { writer.moveCursor(by: caretOffset) }
            if caretOffset < 0, text.count >= -caretOffset {
                let split = text.index(text.endIndex, offsetBy: caretOffset)
                writer.recordOwnEdit(
                    beforeSuffix: String(text[..<split]),
                    afterPrefix: String(text[split...]))
            } else if caretOffset > 0 {
                writer.recordOwnEdit(beforeSuffix: "", afterPrefix: "")
            } else if !text.isEmpty {
                writer.recordOwnEdit(beforeSuffix: text, afterPrefix: "")
            }
        case .deleteBackward:
            writer.clearRecentOwnEdit()
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
        case .backspaceSyllable:
            apply(model.backspaceSyllable())
        case .deleteBackward(let times):
            delete(times: times)
        case .moveCursor(let steps):
            guard steps != 0 else { return }
            writer.clearRecentOwnEdit()
            writer.moveCursor(by: steps)
            playSelectionFeedback()
        case .cursorDrag:
            break
        case .shift:
            model.shiftTapped()
            render()
        case .toggleMode:
            let outcome = model.toggleMode()
            if KeyboardSettings.rememberMode {
                KeyboardSettings.lastMode = model.mode == .chinese ? "chinese" : "english"
            }
            apply(outcome)
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
            if let letter = key.keyLetter, let point = key.touchPoint {
                model.setTouchPoint(letter, point)
            }
            playKeyFeedback()
            showPreview(for: key)
        } else {
            hidePreview(for: key)
        }
    }
}
