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
}

/// 持有一次输入过程的全部规则状态。只在主线程使用，不加锁。
public final class Session {
    let eng: Engine?
    var mode: Mode = .chinese
    var fullWidth = true
    var punctAlt = [Bool](repeating: false, count: 128)
    var lookbehind: (() -> Unicode.Scalar?)?
    var inline = ""
    var inlineSp = false

    /// 建立规则状态机。eng 可以为 nil，此时只做缓冲和标点规则（用于测试）。
    public init(eng: Engine?) {
        self.eng = eng
    }

    /// 设置「读光标前一个字符」的钩子。平台壳用它查宿主正文，判断中英文之间
    /// 要不要补空格。不设置或返回 nil 时当作前面没有字符。
    public func setLookbehind(_ fn: @escaping () -> Unicode.Scalar?) {
        lookbehind = fn
    }

    public var currentMode: Mode { mode }
    public var isFullWidth: Bool { fullWidth }
    public var inlineText: String { inline }

    /// 当前拼音缓冲。
    public var buffer: String {
        guard let eng else { return "" }
        return String(decoding: eng.buffer, as: UTF8.self)
    }

    /// 应该显示为预编辑的串：临时英文优先，否则是拼音缓冲。
    public var preedit: String {
        if !inline.isEmpty { return inline }
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

    func result(_ text: String, _ consumed: Bool) -> Result {
        Result(text: text, consumed: consumed, mode: mode, fullWidth: fullWidth)
    }

    /// 追加一个字母。临时英文存在时原样追加，否则进入拼音缓冲。
    @discardableResult
    public func type(_ ch: UInt8) -> Result {
        if !inline.isEmpty {
            inline += String(decoding: [ch], as: UTF8.self)
            return result("", true)
        }
        if mode != .chinese || eng == nil {
            return result("", false)
        }
        var c = ch
        if c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") {
            c += UInt8(ascii: "a") - UInt8(ascii: "A")
        }
        guard let eng, eng.type(c) else { return result("", false) }
        return result("", true)
    }

    /// 中文态按住 Shift 打大写字母：没有缓冲时直接上屏，正在打拼音时把已打
    /// 编码接进临时英文串，再从这字母继续。
    @discardableResult
    public func shiftLetter(_ ch: UInt8) -> Result {
        var c = ch
        if c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z") {
            c -= UInt8(ascii: "a") - UInt8(ascii: "A")
        }
        let text = String(decoding: [c], as: UTF8.self)
        if !inline.isEmpty {
            inline += text
            return result("", true)
        }
        if mode != .chinese {
            return direct(text)
        }
        if !buffer.isEmpty {
            inline = buffer + text
            inlineSp = classBefore("") == .cjk
            eng?.reset()
            return result("", true)
        }
        var out = text
        if classBefore("") == .cjk {
            out = " " + out
        }
        return result(out, true)
    }

    /// 直接插入一段固定文本（iOS 的英文字母、数字键、符号页）。组合中的候选
    /// 先上屏。补空格和 macOS 透传按键一致。
    public func direct(_ text: String) -> Result {
        var out = commitPending()
        if let first = text.utf8.first, isASCIIAlnum(first), classBefore(out) == .cjk {
            out += " "
        }
        return result(commitText(out, text), true)
    }

    /// 空格：临时英文结束并补空格；有候选选首选；否则原样上屏。
    /// 没有任何组合时返回 Consumed=false，让平台自己插入空格。
    public func space() -> Result {
        if !inline.isEmpty {
            return result(commitInline("", true), true)
        }
        if mode == .chinese && !buffer.isEmpty {
            return result(commitPending(), true)
        }
        return result("", false)
    }

    /// 回车：临时英文不补空格结束；有缓冲时把编码原样上屏。
    /// 没有组合时返回 Consumed=false，让平台按自己的语义换行。
    public func returnKey() -> Result {
        if !inline.isEmpty {
            // 回车结束不补空格，后面紧接中文也不自动加。
            return result(commitInline("", false), true)
        }
        if mode == .chinese && !buffer.isEmpty {
            return result(commitRaw(""), true)
        }
        return result("", false)
    }

    /// 删除临时英文或拼音缓冲的一格；没有组合时交给平台删正文。
    public func backspace() -> Result {
        if !inline.isEmpty {
            inline.removeLast()
            if inline.isEmpty { inlineSp = false }
            return result("", true)
        }
        if mode == .chinese && !buffer.isEmpty {
            _ = eng?.backspace()
            return result("", true)
        }
        return result("", false)
    }

    /// 取消临时英文或当前拼音组合。
    public func escape() -> Result {
        if !inline.isEmpty {
            inline = ""
            inlineSp = false
            return result("", true)
        }
        if !buffer.isEmpty {
            eng?.reset()
            return result("", true)
        }
        return result("", false)
    }

    /// 翻页。候选为空时返回 Consumed=false；到边界仍算消费，避免 = / - 上屏。
    public func page(_ delta: Int) -> Result {
        if !inline.isEmpty {
            return result(commitInline("", false), false)
        }
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

    /// 把引擎选出的文字按补空格规则上屏。
    func selected(_ r: (String, Bool)) -> Result {
        guard r.1 else { return result("", false) }
        return result(commitText("", r.0), true)
    }

    /// 把 ASCII 标点转成中文标点。组合中的候选先上屏；全半角关闭或表里
    /// 没有这个字符时返回 Consumed=false。
    public func punctuate(_ ch: UInt8) -> Result {
        guard mode == .chinese, fullWidth, let alts = punctTable[ch] else {
            return result("", false)
        }
        let out = commitPending()
        var punct = punctuateChar(ch, alts)
        if ch == UInt8(ascii: ".") && digitBefore(out) {
            punct = "."
        }
        return result(out + punct, true)
    }

    /// 处理交给应用的按键：先把组合上屏，再按光标前的字符决定要不要补空格。
    public func passthrough(_ ch: UInt8) -> Result {
        var out: String
        if ch >= 0x20 {
            out = commitPending()
        } else {
            out = commitInline("", false)
        }
        if isASCIIAlnum(ch) && classBefore(out) == .cjk {
            out += " "
        }
        return result(out, false)
    }

    /// 切换中英模式。切到英文时把没上屏的拼音原样打出去。
    public func toggleMode() -> Result {
        var out = commitInline("", false)
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

    /// 结束临时英文。trailingSpace 为 true 时补一个空格。
    public func commitInline(_ trailingSpace: Bool) -> Result {
        if inline.isEmpty { return result("", false) }
        return result(commitInline("", trailingSpace), true)
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
        inline = ""
        inlineSp = false
    }

    // 下面的上屏辅助函数都接收 pending：本次动作已经拼好、还没写进宿主的
    // 文本，返回追加之后的结果。补空格和数字后半角句号要看「光标前一个
    // 字符」，pending 非空时那个字符是 pending 的末尾。

    /// 结束临时英文，再把拼音缓冲的首选上屏；没有候选时把编码原样上屏。
    func commitPending() -> String {
        let out = commitInline("", false)
        if buffer.isEmpty { return out }
        if let eng {
            let (text, ok) = eng.select(0)
            if ok { return commitText(out, text) }
        }
        return commitRaw(out)
    }

    /// 上屏一段文字，并在中文紧跟英文/数字时补一个空格。
    func commitText(_ pending: String, _ text: String) -> String {
        if text.isEmpty { return pending }
        if classOf(text) == .cjk && classBefore(pending) == .ascii {
            return pending + " " + text
        }
        return pending + text
    }

    /// 把拼音缓冲原样上屏，不做任何转换。
    func commitRaw(_ pending: String) -> String {
        let buf = buffer
        if buf.isEmpty { return pending }
        eng?.reset()
        if classBefore(pending) == .cjk {
            return pending + " " + buf
        }
        return pending + buf
    }

    /// 把临时英文串上屏。空格结束补一个空格；回车结束不补。
    func commitInline(_ pending: String, _ trailingSpace: Bool) -> String {
        if inline.isEmpty { return pending }
        var text = inline
        if inlineSp { text = " " + text }
        if trailingSpace { text += " " }
        inline = ""
        inlineSp = false
        return pending + text
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
