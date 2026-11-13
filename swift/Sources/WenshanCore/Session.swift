import Foundation

/// macOS 和 iOS 共用的输入规则层。
///
/// 平台壳只负责把系统事件或触摸翻译成这里的动作，再把 Result 落到预编辑、
/// 候选条和正文。标点、全半角、中英模式、Shift、临时英文、空格/回车/退格
/// 以及中英文之间的自动补空格都在这里维护，两端不再各写一份。补空格的判断
/// 靠平台壳提供的 lookbehind 读光标前一个字符，规则层不猜正文内容。

/// 输入模式。英文模式只做直通，不参与拼音组句。
public enum Mode: Int, Sendable {
    case chinese = 0
    case english = 1
}

/// 字符的类别，用来判断中英文之间要不要补空格。
enum CharClass {
    case none
    case cjk
    case ascii
}

/// 一次规则动作的结果。Text 已经包含自动补的空格；Consumed 为 false 时
/// 平台按原键处理（例如没有候选时回车换行）。
public struct Result: Equatable, Sendable {
    public var text: String
    public var consumed: Bool
    public var mode: Mode
    public var fullWidth: Bool
    /// 插入 text 之前先删掉光标前这么多字符（智能标点改写刚上屏的字符）。
    public var deleteBefore: Int
    /// 插入 text 之后把光标移动这么多字符，负数往左（成对标点把光标放回中间）。
    public var caretOffset: Int

    public init(
        text: String, consumed: Bool, mode: Mode, fullWidth: Bool,
        deleteBefore: Int = 0, caretOffset: Int = 0
    ) {
        self.text = text
        self.consumed = consumed
        self.mode = mode
        self.fullWidth = fullWidth
        self.deleteBefore = deleteBefore
        self.caretOffset = caretOffset
    }
}

/// 持有一次输入过程的全部规则状态。只在主线程使用，不加锁。
public final class Session {
    let eng: Engine?
    var mode: Mode = .chinese
    var fullWidth = true
    var punctAlt = [Bool](repeating: false, count: 128)
    var lookbehind: (() -> Unicode.Scalar?)?
    /// 当前缓冲是不是从 Shift+大写字母开始的英文段。英文查询和大小写推导
    /// 都看它；普通拼音输入不查英文词表，避免中文候选被英文刷屏。
    var englishRun = false
    /// 最近一次由本会话上屏的 ASCII 标点，供「两秒内重按转中文」判断。
    /// 键盘进程收起时会话会重置，所以只覆盖同一次键盘出现内的手势。
    var lastASCIIDirect: (ch: UInt8, at: TimeInterval)?
    /// 最近一次上屏的中文标点，供「标点后按空格改回 ASCII」判断。
    var lastCJKPunct: (text: String, at: TimeInterval, generation: Int)?
    /// 编辑器代次：平台壳在宿主换输入框/光标时递增，避免手势跨编辑器生效。
    var editorGeneration = 0
    /// 成对标点自动补全，iOS 打开；macOS 保留原来的引号交替行为。
    public var pairPunctuation = false
    /// 智能标点手势（重复转中文、空格转英文），iOS 打开。
    public var smartPunctuation = false
    /// 中文标点后按空格改回 ASCII 的开关，默认关：它改写用户已经看到的字符。
    public var spaceRevertsPunctuation = false
    /// 自己补过的成对标点，最内层在上。宿主不报告光标后文字时用它判断跨过。
    var pairStack: [(close: Unicode.Scalar, generation: Int)] = []
    /// 只处理这三个键的重复转中文，和桌面端保持一致。
    static let repeatablePuncts: Set<UInt8> = [
        UInt8(ascii: ","), UInt8(ascii: "."), UInt8(ascii: ":"),
    ]
    /// 键盘扩展收不到硬件键，成对标点的「跨过」需要读光标后的字符。
    /// 返回 nil 表示宿主没报告，此时按自己补过的记录处理。
    public var lookahead: (() -> Unicode.Scalar?)?

    /// 建立规则状态机。eng 可以为 nil，此时只做缓冲和标点规则（用于测试）。
    public init(eng: Engine?) {
        self.eng = eng
    }

    /// 设置「读光标前一个字符」的钩子。平台壳用它查宿主正文，判断中英文之间
    /// 要不要补空格。不设置或返回 nil 时当作前面没有字符。
    public func setLookbehind(_ fn: @escaping () -> Unicode.Scalar?) {
        lookbehind = fn
    }

    /// 设置「读光标后一个字符」的钩子，只在成对标点跨过时用。
    public func setLookahead(_ fn: @escaping () -> Unicode.Scalar?) {
        lookahead = fn
    }

    /// 宿主换了输入框或光标位置，手势快照作废。
    public func editorDidChange() {
        editorGeneration += 1
        lastASCIIDirect = nil
        lastCJKPunct = nil
        pairStack.removeAll()
    }

    public var currentMode: Mode { mode }
    public var isFullWidth: Bool { fullWidth }
    /// 键盘出现时按偏好设初始模式；输入途中切换只改当前会话。
    public func setMode(_ next: Mode) {
        mode = next
    }
    /// 兼容旧壳：不再有独立临时英文串，组合态一律由缓冲表示。
    public var inlineText: String { "" }

    /// 当前拼音缓冲。
    public var buffer: String {
        guard let eng else { return "" }
        return String(decoding: eng.buffer, as: UTF8.self)
    }

    /// 应该显示为预编辑的串：临时英文优先，否则是拼音缓冲。
    public var preedit: String {
        return buffer
    }

    /// 当前页候选。
    public var candidates: [Candidate] { eng?.candidates ?? [] }

    /// 当前候选页码（0 起），供候选窗显示进度。
    public var pageNo: Int { eng?.pageNo ?? 0 }

    /// 是否还有下一页候选，供候选窗显示「还有更多 / 到底」。
    public var hasNextPage: Bool { eng?.hasNextPage() ?? false }

    /// 第 1 页和后续页的全部候选，供键盘展开显示。
    public var allCandidates: [Candidate] { eng?.allCandidates() ?? [] }

    /// 把用户词频和自造词写盘，force 的含义见 Engine.save。
    public func save(force: Bool) throws {
        try eng?.save(force: force)
    }

    /// 用户数据文件被外部改过时重新读盘，见 Engine.reloadIfChangedOnDisk。
    public func reloadIfChangedOnDisk() {
        eng?.reloadIfChangedOnDisk()
    }

    func result(
        _ text: String, _ consumed: Bool,
        deleteBefore: Int = 0, caretOffset: Int = 0
    ) -> Result {
        Result(
            text: text, consumed: consumed, mode: mode, fullWidth: fullWidth,
            deleteBefore: deleteBefore, caretOffset: caretOffset)
    }

    /// 追加一个字母。英文段里保留大小写，拼音输入归一成小写。
    @discardableResult
    public func type(_ ch: UInt8) -> Result {
        guard mode == .chinese, let eng else { return result("", false) }
        if eng.buffer.isEmpty { englishRun = false }
        var c = ch
        if !englishRun, c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z") {
            c += UInt8(ascii: "a") - UInt8(ascii: "A")
        }
        guard eng.type(c) else { return result("", false) }
        eng.englishQuery = true
        lastASCIIDirect = nil
        lastCJKPunct = nil
        return result("", true)
    }

    /// 中文态 Shift+字母：不再直接上屏，一律追加到组合缓冲。
    /// 小写前缀后接大写（iPhone、GitHub）也靠这条路径保留，后续字母不再
    /// 被归一成小写；英文词表按小写编码查询，显示时按段首大小写推导。
    @discardableResult
    public func shiftLetter(_ ch: UInt8) -> Result {
        var c = ch
        if c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z") {
            c -= UInt8(ascii: "a") - UInt8(ascii: "A")
        }
        if mode != .chinese {
            return direct(String(decoding: [c], as: UTF8.self))
        }
        guard let eng, eng.type(c) else { return result("", false) }
        englishRun = true
        eng.englishQuery = true
        lastASCIIDirect = nil
        lastCJKPunct = nil
        return result("", true)
    }

    /// 直接插入一段固定文本（iOS 的英文字母、数字键、符号页）。组合中的候选
    /// 先上屏。补空格和 macOS 透传按键一致。
    public func direct(_ text: String) -> Result {
        var out = commitPending()
        if let first = text.utf8.first, isASCIIAlnum(first), classBefore(out) == .cjk {
            out += " "
        }
        let inserted = text
        if smartPunctuation, inserted.unicodeScalars.count == 1,
           let scalar = inserted.unicodeScalars.first, scalar.value < 0x80 {
            let ch = UInt8(scalar.value)
            if Self.repeatablePuncts.contains(ch) {
                let now = Date.timeIntervalSinceReferenceDate
                if let last = lastASCIIDirect, last.ch == ch, now - last.at <= 2 {
                    let fallback = String(scalar)
                    lastASCIIDirect = nil
                    // 文档里得确实还是刚才那个 ASCII 字符，否则不改。
                    if lookbehind?() == scalar, let table = punctTable[ch], let cjk = table.first {
                        let res = result(cjk, true, deleteBefore: 1)
                        lastCJKPunct = (cjk, now, editorGeneration)
                        return res
                    }
                    lastASCIIDirect = (ch, now)
                    lastCJKPunct = nil
                    return result(commitText(out, fallback), true)
                }
                lastASCIIDirect = (ch, now)
                lastCJKPunct = nil
                return result(commitText(out, inserted), true)
            }
        }
        lastASCIIDirect = nil
        lastCJKPunct = nil
        return result(commitText(out, inserted), true)
    }

    /// 空格：有候选选首选；否则原样上屏。没有任何组合时返回 Consumed=false。
    public func space() -> Result {
        if mode == .chinese && !buffer.isEmpty {
            return result(commitPending(), true)
        }
        if spaceRevertsPunctuation, let last = lastCJKPunct,
           last.generation == editorGeneration,
           Date.timeIntervalSinceReferenceDate - last.at <= 2,
           let ascii = ASCIIPunct[last.text], lookbehind?() == last.text.unicodeScalars.last {
            lastCJKPunct = nil
            return result(ascii, true, deleteBefore: 1)
        }
        lastCJKPunct = nil
        return result("", false)
    }

    /// 回车：有缓冲时把编码原样上屏（中文态直接打英文的逃生口）。
    public func returnKey() -> Result {
        if mode == .chinese && !buffer.isEmpty {
            return result(commitRaw(""), true)
        }
        return result("", false)
    }

    /// 删除拼音缓冲的一格；没有组合时交给平台删正文。
    public func backspace() -> Result {
        if mode == .chinese && !buffer.isEmpty {
            _ = eng?.backspace()
            if buffer.isEmpty { englishRun = false }
            return result("", true)
        }
        lastASCIIDirect = nil
        lastCJKPunct = nil
        return result("", false)
    }

    /// 长按删除：拼音缓冲一次退一个完整音节；缓冲空了交给平台删正文。
    public func backspaceSyllable() -> Result {
        if mode == .chinese && !buffer.isEmpty {
            _ = eng?.backspaceSyllable()
            if buffer.isEmpty { englishRun = false }
            return result("", true)
        }
        lastASCIIDirect = nil
        lastCJKPunct = nil
        return result("", false)
    }

    /// 取消当前组合。
    public func escape() -> Result {
        if !buffer.isEmpty {
            eng?.reset()
            englishRun = false
            return result("", true)
        }
        return result("", false)
    }

    /// 翻页。候选为空时返回 Consumed=false；到边界仍算消费，避免 = / - 上屏。
    public func page(_ delta: Int) -> Result {
        guard let eng, !eng.candidates.isEmpty else { return result("", false) }
        _ = eng.page(delta)
        return result("", true)
    }

    /// 选中第 i 个候选并上屏。
    public func select(_ i: Int) -> Result {
        guard let eng else { return result("", false) }
        return selected(eng.select(i))
    }

    /// 取第 i 个候选的首字或尾字。
    public func selectChar(_ i: Int, last: Bool) -> Result {
        guard let eng else { return result("", false) }
        return selected(eng.selectChar(i, last: last))
    }

    /// 选出全部候选里的第 i 个并上屏，索引可以落在后续页。
    public func selectGlobal(_ i: Int) -> Result {
        guard let eng else { return result("", false) }
        return selected(eng.selectGlobal(i))
    }

    /// 取全部候选里第 i 个候选的首字或尾字，索引可以落在后续页。
    public func selectCharGlobal(_ i: Int, last: Bool) -> Result {
        guard let eng else { return result("", false) }
        return selected(eng.selectCharGlobal(i, last: last))
    }

    /// 把引擎选出的文字按补空格规则上屏。
    func selected(_ r: (String, Bool)) -> Result {
        guard r.1 else { return result("", false) }
        if buffer.isEmpty { englishRun = false }
        return result(commitText("", r.0), true)
    }

    /// 把 ASCII 标点转成中文标点。组合中的候选先上屏；全半角关闭或表里
    /// 没有这个字符时返回 Consumed=false。
    public func punctuate(_ ch: UInt8) -> Result {
        guard mode == .chinese, fullWidth, let alts = punctTable[ch] else {
            return result("", false)
        }
        let out = commitPending()
        let now = Date.timeIntervalSinceReferenceDate

        // 右半边的键先处理：光标后已有配对字符就只跨过去，不写第二个。
        if pairPunctuation, let close = rightHalf[ch] {
            let right = lookahead?()
            let pending = pairStack.last?.close
            if right == close || (right == nil && pending == close) {
                if pending == close { pairStack.removeLast() }
                lastASCIIDirect = nil
                lastCJKPunct = nil
                return result(out, true, caretOffset: 1)
            }
        }

        var punct: String
        if pairPunctuation && alts.count == 2,
           let openScalar = alts[0].unicodeScalars.first, alts[0].unicodeScalars.count == 1,
           let closeScalar = alts[1].unicodeScalars.first, alts[1].unicodeScalars.count == 1 {
            // 成对标点打开时，引号优先检查是不是跨过右半边，否则总是成对打开，
            // 不再受交替开关影响输出单个右引号。
            let right = lookahead?()
            let pending = pairStack.last?.close
            if right == closeScalar || (right == nil && pending == closeScalar) {
                if pending == closeScalar { pairStack.removeLast() }
                lastASCIIDirect = nil
                lastCJKPunct = nil
                return result(out, true, caretOffset: 1)
            }
            pairStack.append((closeScalar, editorGeneration))
            lastASCIIDirect = nil
            lastCJKPunct = nil
            return result(out + String(openScalar) + String(closeScalar), true, caretOffset: -1)
        } else {
            punct = punctuateChar(ch, alts)
        }
        if ch == UInt8(ascii: ".") && digitBefore(out) {
            punct = "."
        }
        if pairPunctuation, let scalar = punct.unicodeScalars.first,
           punct.unicodeScalars.count == 1 {
            // 右半边：光标后（或自己补过的栈顶）已经是它就只跨过去。
            if let close = pairedCloses[scalar] {
                let right = lookahead?()
                let pending = pairStack.last?.close
                if right == close || (right == nil && pending == close) {
                    if pending == close { pairStack.removeLast() }
                    lastASCIIDirect = nil
                    lastCJKPunct = nil
                    return result(out, true, caretOffset: 1)
                }
            }
            // 左半边：一次写一对，光标放回中间，右半边由上面的跨过逻辑处理。
            if let close = pairedOpens[scalar] {
                pairStack.append((close, editorGeneration))
                lastCJKPunct = nil
                return result(out + String(scalar) + String(close), true, caretOffset: -1)
            }
        }
        if punct.unicodeScalars.count == 1 && ASCIIPunct[punct] != nil {
            lastCJKPunct = (punct, now, editorGeneration)
        } else {
            lastCJKPunct = nil
        }
        lastASCIIDirect = nil
        return result(out + punct, true)
    }

    /// 处理交给应用的按键：先把组合上屏，再按光标前的字符决定要不要补空格。
    public func passthrough(_ ch: UInt8) -> Result {
        var out = commitPending()
        if isASCIIAlnum(ch) && classBefore(out) == .cjk {
            out += " "
        }
        return result(out, false)
    }

    /// 切换中英模式。切到英文时把没上屏的拼音原样打出去。
    public func toggleMode() -> Result {
        var out = ""
        if mode == .chinese {
            out = commitRaw(out)
            mode = .english
        } else {
            mode = .chinese
        }
        return result(out, true)
    }

    /// 切换标点全角/半角。
    public func toggleFullWidth() -> Result {
        fullWidth.toggle()
        return result("", true)
    }

    /// 把未完成的输入上屏并清干净，用于停用输入法或应用主动结束输入。
    public func finish() -> Result {
        let out = commitPending()
        reset()
        return result(out, !out.isEmpty)
    }

    /// 清空当前组合，不删除已经上屏的文本，也不改变中英模式和全半角。
    public func reset() {
        eng?.reset()
        englishRun = false
        lastASCIIDirect = nil
        lastCJKPunct = nil
        pairStack.removeAll()
    }

    // 下面的上屏辅助函数都接收 pending：本次动作已经拼好、还没写进宿主的
    // 文本，返回追加之后的结果。补空格和数字后半角句号要看「光标前一个
    // 字符」，pending 非空时那个字符是 pending 的末尾。

    /// 把拼音缓冲的首选上屏；没有候选时把编码原样上屏。
    func commitPending() -> String {
        if buffer.isEmpty { return "" }
        if let eng {
            let (text, ok) = eng.select(0)
            if ok { return commitText("", text) }
        }
        return commitRaw("")
    }

    /// 上屏一段文字，并在中文紧跟英文/数字时补一个空格。
    func commitText(_ pending: String, _ text: String) -> String {
        if text.isEmpty { return pending }
        let c = classOf(text)
        let before = classBefore(pending)
        if (c == .cjk && before == .ascii) || (c == .ascii && before == .cjk) {
            return pending + " " + text
        }
        return pending + text
    }

    /// 把拼音缓冲原样上屏，不做任何转换。
    func commitRaw(_ pending: String) -> String {
        let buf = buffer
        if buf.isEmpty { return pending }
        eng?.reset()
        englishRun = false
        if classBefore(pending) == .cjk {
            return pending + " " + buf
        }
        return pending + buf
    }

    /// 光标前一个字符：pending 非空时取它的末字，否则问宿主正文。
    func charBefore(_ pending: String) -> Unicode.Scalar? {
        if !pending.isEmpty {
            return pending.unicodeScalars.last
        }
        return lookbehind?()
    }

    /// 光标前一个字符的类别，用于判断要不要补空格。
    func classBefore(_ pending: String) -> CharClass {
        guard let r = charBefore(pending) else { return .none }
        return classOf(r)
    }

    /// 光标前一个字符是不是 ASCII 数字，用于数字后的半角句号。
    func digitBefore(_ pending: String) -> Bool {
        guard let r = charBefore(pending), r.value < 0x80 else { return false }
        return isASCIIDigit(UInt8(r.value))
    }

    func punctuateChar(_ ch: UInt8, _ alts: [String]) -> String {
        if alts.count == 1 { return alts[0] }
        let i = punctAlt[Int(ch)] ? 1 : 0
        punctAlt[Int(ch)].toggle()
        return alts[i]
    }
}

@inline(__always)
func isASCIIDigit(_ ch: UInt8) -> Bool {
    ch >= UInt8(ascii: "0") && ch <= UInt8(ascii: "9")
}

@inline(__always)
func isASCIIAlnum(_ ch: UInt8) -> Bool {
    isASCIIDigit(ch)
        || (ch >= UInt8(ascii: "a") && ch <= UInt8(ascii: "z"))
        || (ch >= UInt8(ascii: "A") && ch <= UInt8(ascii: "Z"))
}

/// 判断一个字符属于哪一类。
func classOf(_ r: Unicode.Scalar) -> CharClass {
    if r.properties.isIdeographic { return .cjk }
    if r.value < 0x80 && isASCIIAlnum(UInt8(r.value)) { return .ascii }
    return .none
}

/// 判断一段要上屏的文字属于哪一类，用于决定要不要在前面补空格。
func classOf(_ s: String) -> CharClass {
    if let first = s.unicodeScalars.first, first.properties.isIdeographic {
        return .cjk
    }
    if let first = s.utf8.first, isASCIIAlnum(first) {
        return .ascii
    }
    return .none
}

/// 中文标点。只有一个元素的直接替换；有多个元素的按次序交替（左右引号）。
/// 表里没有的字符照常交给应用，避免影响写代码时打的 - / = + * | 之类。
let punctTable: [UInt8: [String]] = [
    UInt8(ascii: ","): ["，"],
    UInt8(ascii: "."): ["。"],
    UInt8(ascii: "?"): ["？"],
    UInt8(ascii: "!"): ["！"],
    UInt8(ascii: ":"): ["："],
    UInt8(ascii: ";"): ["；"],
    UInt8(ascii: "("): ["（"],
    UInt8(ascii: ")"): ["）"],
    UInt8(ascii: "<"): ["《"],
    UInt8(ascii: ">"): ["》"],
    UInt8(ascii: "["): ["【"],
    UInt8(ascii: "]"): ["】"],
    UInt8(ascii: "{"): ["「"],
    UInt8(ascii: "}"): ["」"],
    UInt8(ascii: "/"): ["、"],
    UInt8(ascii: "\\"): ["、"],
    UInt8(ascii: "~"): ["～"],
    UInt8(ascii: "^"): ["……"],
    UInt8(ascii: "_"): ["——"],
    UInt8(ascii: "$"): ["￥"],
    UInt8(ascii: "\""): ["“", "”"],
    UInt8(ascii: "'"): ["‘", "’"],
]

/// ASCII 标点 → 中文标点，供「空格把刚上屏的中文标点改回 ASCII」反查。
let ASCIIPunct: [String: String] = [
    "，": ",", "。": ".", "：": ":", "？": "?", "！": "!", "；": ";",
    "、": "/", "～": "~", "……": "^", "——": "_", "￥": "$",
]

/// 成对标点：左半边 → 右半边。右半边的键（) > ] } 等）只跨过，不写第二个。
let pairedOpens: [Unicode.Scalar: Unicode.Scalar] = [
    "（": "）", "《": "》", "【": "】", "「": "」", "〈": "〉",
    "(": ")", "[": "]", "{": "}", "<": ">",
    "“": "”", "‘": "’", "\"": "\"", "'": "'",
]

let pairedCloses: [Unicode.Scalar: Unicode.Scalar] = [
    "）": "）", "》": "》", "】": "】", "」": "」", "〉": "〉",
    ")": ")", "]": "]", "}": "}", ">": ">",
    "”": "”", "’": "’",
]

/// ASCII 右半键 → 中文右半字符，让「)」这类键直接走跨过判断。
let rightHalf: [UInt8: Unicode.Scalar] = [
    UInt8(ascii: ")"): "）", UInt8(ascii: ">"): "》",
    UInt8(ascii: "]"): "】", UInt8(ascii: "}"): "」",
]
