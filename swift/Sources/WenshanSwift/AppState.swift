import AppKit
import InputMethodKit
import WenshanCore

/// 输入法进程的全部状态。IMK 回调和候选窗都在主线程，所以整类标 @MainActor。
@MainActor
final class AppState {
    static let shared = AppState()

    let engine: Engine
    let session: Session
    let candidates = CandidateWindow()
    let dictCount: Int
    /// 词表打不开的原因。输入法是常驻进程，崩了系统会反复拉起再崩，
    /// 所以这时不退出，按无词表运行：拼音只能按原样上屏。
    let dictError: String?
    let debugKeys: Bool

    var currentClient: (any IMKTextInput)?
    var caret = NSRect.zero
    var caretValid = false

    // 用来区分「按住 Shift 打大写」和「轻点 Shift 切中英」。
    var shiftDown = false
    var shiftUsed = false

    var hudToken = 0

    private init() {
        var dict: Dict?
        var dictError: String?
        if let url = Paths.dictURL() {
            do {
                dict = try Dict(data: Data(contentsOf: url, options: .mappedIfSafe))
            } catch {
                dictError = "词表加载失败: \(error)"
            }
        } else {
            dictError = "缺少 dict.bin：app 的 Resources 里没有，当前目录也没有"
        }
        self.dictError = dictError
        dictCount = dict?.count ?? 0
        debugKeys = FileManager.default.fileExists(atPath: Paths.debugFlag.path)

        engine = Engine(dict: dict)
        engine.setFreq(Freq.load(Paths.freq.path))
        engine.setUserDict(UserDict.load(Paths.userDict.path))
        engine.setPhrases(UserDict.load(Paths.phrases.path))
        session = Session(eng: engine)

        // 补空格的判断要读宿主正文：光标前一个字符。查不到就当前面没有字符。
        session.setLookbehind { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let client = self.currentClient else { return nil }
                return self.characterBefore(client)
            }
        }
    }

    func start() {
        if let dictError {
            Log.shared.write("\(dictError)；按无词表运行")
        } else {
            Log.shared.write("词表 \(dictCount) 条，来自 \(Paths.dictURL()?.path ?? "?")")
        }
        if debugKeys { Log.shared.write("调试模式：打印每个按键") }
        Log.shared.write("用户数据目录 \(Paths.appSupport.path)")
    }

    // MARK: - IMK 回调

    func handle(_ event: NSEvent, client: any IMKTextInput) -> Bool {
        let type = event.type
        let mods = event.modifierFlags
        if debugKeys {
            Log.shared.write(
                "key type=\(type.rawValue) code=\(event.keyCode) mods=\(mods.rawValue) "
                    + "mode=\(session.currentMode) buf=\(session.buffer) inline=\(session.inlineText)")
        }

        if type == .flagsChanged {
            handleFlags(mods, keyCode: event.keyCode)
            return false
        }
        if type != .keyDown { return false }
        // 按住 Shift 期间按过别的键，松开时就不算「轻点」。
        if shiftDown { shiftUsed = true }

        let raw = event.characters?.utf8.first ?? 0
        var ch = raw
        if ch >= 0x41 && ch <= 0x5A { ch += 0x20 }  // A-Z -> a-z
        let keyCode = event.keyCode

        // 带 Command/Control/Option 的组合键一律放行，交给应用自己处理。
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return false
        }
        // 英文直通模式：按键交给应用，补空格仍由规则层判断。
        if session.currentMode == .english {
            let res = session.passthrough(ch)
            if !res.text.isEmpty { insertText(client, res.text) }
            return false
        }

        // 中文态按住 Shift 打大写字母：没有缓冲时直接上屏；正在打拼音时
        // 把已打的编码接进临时英文串，再从这字母继续。
        if raw >= 0x41 && raw <= 0x5A && mods.contains(.shift) {
            return commit(client, session.shiftLetter(raw))
        }
        // Shift+空格：全角/半角标点切换。临时英文里仍然按空格结束。
        if keyCode == keySpace && mods.contains(.shift) {
            if !session.inlineText.isEmpty {
                return commit(client, session.space())
            }
            let res = session.toggleFullWidth()
            showHUD(res.fullWidth ? "全角" : "半角")
            return true
        }

        switch keyCode {
        case keyDelete:
            return commit(client, session.backspace())
        case keyEscape:
            return commit(client, session.escape())
        case keyReturn, keyKeypadEnter:
            // 回车把缓冲里的字母原样上屏，中文状态下不用切模式就能打英文。
            return commit(client, session.returnKey())
        case keySpace:
            return commit(client, session.space())
        case keyTab:
            // 临时英文里 Tab 先结束英文，再交给应用切换焦点，不补空格。
            if !session.inlineText.isEmpty {
                _ = commit(client, session.commitInline(false))
                return false
            }
            return commit(client, session.space())
        case keyPageUp:
            return page(client, -1)
        case keyPageDown:
            return page(client, 1)
        default:
            break
        }

        if !session.buffer.isEmpty && ch >= 0x31 && ch <= 0x39 {
            if commit(client, session.select(Int(ch - 0x31))) { return true }
        }
        // [ / ] 取当前候选的首字 / 尾字，编码消耗和正常选词一样。
        if !session.buffer.isEmpty && (ch == 0x5B || ch == 0x5D) {
            if commit(client, session.selectChar(0, last: ch == 0x5D)) { return true }
        }
        // = / - 翻页。候选窗开着时由输入法接管，到边界也不再当字符上屏。
        if !session.candidates.isEmpty && (ch == 0x3D || ch == 0x2D) {
            if page(client, ch == 0x2D ? -1 : 1) { return true }
        }
        if ch >= 0x61 && ch <= 0x7A {
            return commit(client, session.type(raw))
        }
        // 标点：先把已经输入的词上屏，再插入中文标点，这个键被消费掉。
        if commit(client, session.punctuate(ch)) { return true }
        // 其他可打印字符：先把已经输入的词上屏，这个键照常交给应用。
        let res = session.passthrough(ch)
        if !res.text.isEmpty {
            insertText(client, res.text)
            applyPreedit(client)
        }
        return false
    }

    func activate(_ sender: Any?) {
        session.reset()
        // 停用时已经写过盘；这期间文件被删或被改（README 里「删掉文件即清空」），
        // 以磁盘为准重新读，免得下次写盘把旧内容写回去。
        session.reloadIfChangedOnDisk()
        caretValid = false
        shiftDown = false
        shiftUsed = false
        if let client = sender as? any IMKTextInput {
            retainClient(client)
        }
        candidates.hide()
        Log.shared.write("activate mode=\(session.currentMode)")
        // 英文模式下切回来要能看见状态，否则就像「打不出中文」。
        if dictError != nil {
            showHUD("词表缺失")
        } else if session.currentMode == .english {
            showHUD("英")
        }
    }

    func deactivate(_ sender: Any?) {
        finishInput(sender)
    }

    func commitComposition(_ sender: Any?) {
        finishInput(sender)
    }

    // MARK: - 上屏与预编辑

    /// 把规则层消费掉的按键结果写回应用：有文字先上屏，再刷新预编辑和候选窗。
    func commit(_ client: any IMKTextInput, _ res: Result) -> Bool {
        guard res.consumed else { return false }
        if !res.text.isEmpty {
            insertText(client, res.text)
        }
        applyPreedit(client)
        return true
    }

    /// 翻页。临时英文里翻页键先结束英文，键再交给应用。
    func page(_ client: any IMKTextInput, _ delta: Int) -> Bool {
        let res = session.page(delta)
        if !res.text.isEmpty {
            insertText(client, res.text)
            applyPreedit(client)
        }
        if res.consumed {
            showCandidates(client)
        }
        return res.consumed
    }

    /// 把当前预编辑串写给前台应用，并更新候选窗。
    func applyPreedit(_ client: any IMKTextInput) {
        retainClient(client)
        let text = session.preedit
        if text.isEmpty {
            clearMarked(client)
            candidates.hide()
            caretValid = false
            return
        }
        // 在写预编辑之前查光标：这时前台应用还没开始排版，查询不需要等它。
        if !caretValid {
            caret = caretRect(client)
            caretValid = true
        }
        // 光标停在预编辑串末尾。
        setMarked(client, text, selection: NSRange(location: text.utf16.count, length: 0))
        showCandidates(client)
    }

    func insertText(_ client: any IMKTextInput, _ text: String) {
        guard responds(client, "insertText:replacementRange:") else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func setMarked(_ client: any IMKTextInput, _ text: String, selection: NSRange) {
        guard responds(client, "setMarkedText:selectionRange:replacementRange:") else { return }
        client.setMarkedText(
            text, selectionRange: selection,
            replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func clearMarked(_ client: any IMKTextInput) {
        setMarked(client, "", selection: NSRange(location: 0, length: 0))
    }

    /// IMK 客户端理论上都要实现 IMKTextInput，但真有不实现的应用：对它发消息
    /// 会抛 NSException，输入法是常驻进程，一个异常就没了。
    func responds(_ client: any IMKTextInput, _ selector: String) -> Bool {
        (client as AnyObject).responds(to: NSSelectorFromString(selector))
    }

    func retainClient(_ client: any IMKTextInput) {
        currentClient = client
    }

    func finishInput(_ sender: Any?) {
        let client = (sender as? any IMKTextInput) ?? currentClient
        let res = session.finish()
        if !res.text.isEmpty, let client {
            insertText(client, res.text)
        }
        caretValid = false
        if let client {
            clearMarked(client)
        }
        candidates.hide()
        currentClient = nil
        saveLearning()
    }

    func saveLearning() {
        do {
            try session.save(force: true)
        } catch {
            Log.shared.write("保存词频或自造词失败: \(error)")
        }
    }

    func showCandidates(_ client: any IMKTextInput) {
        let cands = session.candidates
        if cands.isEmpty {
            candidates.hide()
            return
        }
        candidates.show(cands, caret: caret, hasNext: session.hasNextPage)
    }

    // MARK: - Shift / 模式提示

    /// 处理 Shift 按下/松开。只有按下期间没打过别的键才算轻点。
    func handleFlags(_ mods: NSEvent.ModifierFlags, keyCode: UInt16) {
        guard keyCode == keyLeftShift || keyCode == keyRightShift else { return }
        let down = mods.contains(.shift)
        if down && !shiftDown {
            shiftDown = true
            // 和 Cmd/Ctrl/Option 一起按的 Shift 不算轻点。
            shiftUsed = mods.contains(.command) || mods.contains(.control) || mods.contains(.option)
        } else if !down && shiftDown {
            shiftDown = false
            if !shiftUsed { toggleMode() }
        }
    }

    /// 在中文/英文直通之间切换。切到英文时把没上屏的拼音按原样打出去。
    func toggleMode() {
        let res = session.toggleMode()
        caretValid = false
        if !res.text.isEmpty, let client = currentClient {
            insertText(client, res.text)
        }
        if let client = currentClient {
            applyPreedit(client)
        } else {
            candidates.hide()
        }
        showHUD(res.mode == .english ? "英" : "中")
    }

    /// 显示一小段模式提示（中文/英文/全角/半角），0.9 秒后自动收起。
    func showHUD(_ text: String) {
        hudToken += 1
        let token = hudToken
        let caret = currentClient.map { caretRect($0) } ?? mouseCaret()
        candidates.showText(text, caret: caret)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard let self, self.hudToken == token else { return }
            self.candidates.hideHUD()
        }
    }

    // MARK: - 光标

    /// 取预编辑串第一个字符的位置。IMK 客户端用的是
    /// attributesForCharacterIndex:lineHeightRectangle:（Squirrel 同款）。
    func caretRect(_ client: any IMKTextInput) -> NSRect {
        if responds(client, "attributesForCharacterIndex:lineHeightRectangle:") {
            var rect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            if validCaret(rect) { return rect }
        }
        return mouseCaret()
    }

    func mouseCaret() -> NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x, y: p.y - 24, width: 2, height: 16)
    }

    func validCaret(_ rect: NSRect) -> Bool {
        rect.width > 0 && rect.height > 0 && rect.height < 200
            && rect.minX > -10000 && rect.minY > -10000
    }

    /// 取光标前一个字符，用来判断中英文之间要不要补空格。
    /// 不是所有 IMK 客户端都实现或都肯给正文，取不到就返回 nil。
    func characterBefore(_ client: any IMKTextInput) -> Unicode.Scalar? {
        guard responds(client, "attributedSubstringFromRange:"),
              responds(client, "selectedRange")
        else { return nil }
        var loc = client.selectedRange().location
        // 组合中光标停在预编辑串末尾，要越过它看正文。
        if responds(client, "markedRange") {
            let marked = client.markedRange()
            if marked.length > 0 && marked.location != NSNotFound {
                loc = marked.location
            }
        }
        guard loc != 0, loc != NSNotFound else { return nil }
        // 往前多取一格，代理对和组合字符才不会被切一半。
        let start = loc >= 2 ? loc - 2 : 0
        guard let attr = client.attributedSubstring(
            from: NSRange(location: start, length: loc - start))
        else { return nil }
        return attr.string.unicodeScalars.last
    }

    // MARK: - 演示

    /// --demo 用：拿真实词表的候选在屏幕中间摆一条，方便截图检查外观。
    func demo() {
        for ch in "nihk".utf8 {
            _ = session.type(ch)
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let caret = NSRect(x: screen.midX - 120, y: screen.midY, width: 2, height: 18)
        candidates.show(session.candidates, caret: caret, hasNext: session.hasNextPage)
        Log.shared.write("demo: \(session.candidates.map(\.text))")
    }
}

private let keyDelete: UInt16 = 51
private let keyEscape: UInt16 = 53
private let keySpace: UInt16 = 49
private let keyReturn: UInt16 = 36
private let keyKeypadEnter: UInt16 = 76
private let keyTab: UInt16 = 48
private let keyPageUp: UInt16 = 116
private let keyPageDown: UInt16 = 121
private let keyLeftShift: UInt16 = 56
private let keyRightShift: UInt16 = 60
