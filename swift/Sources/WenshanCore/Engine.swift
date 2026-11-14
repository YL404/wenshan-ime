/// 输入缓冲的上限（字节，双拼每音节两字节）。
let maxBuf = 32

/// 单键简码每个字母最多存的候选数，也是候选页大小的上限（数字键 1-9）。
public let maxCandidates = 9
/// 测试代码沿用的旧常量名，值等于默认页大小。
let pageSize = maxCandidates
/// 只用于 iOS 键盘一次性展开全部候选的网格上限；逐页翻页不受它限制。
let maxPages = 20
/// 纠错段最多保留的候选数。
let maxCorrections = 20

/// 持有一次输入过程的全部状态。只在主线程上被调用，不加锁。
public final class Engine {
    let dict: Dict?
    var english: EnglishDict?
    var freq: Freq?
    var user: UserDict?
    var phrases: UserDict?
    var buf: [UInt8] = []

    /// 单一有序候选流：正常候选按分数降序，词库到底后把纠错候选接在末尾。
    /// 翻页只是对它的窗口切片，首页和后续页不再各算一份，边界因此是连续的。
    var stream: [Candidate] = []
    var limit = 0
    var exhausted = false
    var cands: [Candidate] = []
    var page = 0

    /// 自造词的学习状态：连续单字选出来的文字，以及这些字实际占用的编码。
    /// 只记连续单字那一段，前面选过的多字词不能算进它的编码里。
    var picked: [UInt8] = []
    var pickedCode: [UInt8] = []
    var singles = 0
    /// 整段缓冲分步选词的状态（用于学入「词+字」「字+词」这类三音节自造词）。
    var sessionText: [UInt8] = []
    var sessionCode: [UInt8] = []
    var sessionSteps = 0
    var sessionValid = true

    /// 建立引擎。dict 可以为 nil，此时只做缓冲管理（用于纯按键测试）。
    public init(dict: Dict?) {
        self.dict = dict
    }

    /// 挂上用户词频表，之后选词会累计、候选会按使用习惯重排。
    public func setFreq(_ f: Freq) { freq = f }

    /// 挂上自造词表。
    public func setUserDict(_ u: UserDict) { user = u }

    /// 挂上只读的自定义短语表。它和自造词共用格式，但不会被写回。
    public func setPhrases(_ p: UserDict) { phrases = p }

    /// 挂上独立英文词表。中文态字母串会补充英文候选，不影响主词表查询。
    public func setEnglishDict(_ d: EnglishDict) { english = d }

    /// 候选长按菜单：把词置顶到当前编码，或从自造词和词频里删掉。
    /// 改动后立刻重建候选并落盘。
    @discardableResult
    public func manage(_ text: String, pin: Bool) -> Bool {
        guard !text.isEmpty else { return false }
        var changed = false
        if pin {
            let code = String(decoding: buf, as: UTF8.self)
            changed = user?.pin(text, code: code) ?? false
        } else {
            changed = (freq?.remove(text) ?? false) || changed
            changed = (user?.remove(text) ?? false) || changed
        }
        if changed {
            refresh()
            try? save(force: true)
        }
        return changed
    }

    /// 这一轮缓冲要不要查英文词表。中文态字母输入由 Session 打开，
    /// 纯拼音组句（例如先选词后剩余缓冲）不需要被英文候选干扰。
    public var englishQuery = false

    /// 候选页大小（1...maxCandidates）。macOS 固定 9，iOS 按自己的偏好设置。
    public var pageSize = maxCandidates {
        didSet { pageSize = min(max(1, pageSize), maxCandidates) }
    }

    /// 字母键在键区坐标里的矩形，按 a...z 索引。nil 表示没有几何数据
    /// （macOS 硬件键盘或测试），纠错退回不看落点。
    public var keyFrames: [KeyFrame?] = Array(repeating: nil, count: 26)
    /// 每个字母键按下时的真实落点。键区坐标，nil 表示没记录。
    public var touchPoints: [KeyPoint?] = Array(repeating: nil, count: 26)

    /// 按下字母键时记下真实落点，供纠错比较「按到的键」和「想打的键」。
    public func setTouchPoint(_ letter: UInt8, _ point: KeyPoint?) {
        guard let index = letterIndex(letter) else { return }
        touchPoints[index] = point
    }

    /// 注册 26 个字母键的几何。布局变化后由平台壳整体重设。
    public func setKeyFrames(_ frames: [KeyFrame?]) {
        keyFrames = Array(frames.prefix(26))
        while keyFrames.count < 26 { keyFrames.append(nil) }
    }

    /// 纠错替换 from → to 时，落点离 to 的键心比离 from 更近就加分。
    /// 分数只影响纠错候选之间的先后，不越过正常候选。
    public func typoBonus(_ from: UInt8, _ to: UInt8) -> Double {
        guard let fi = letterIndex(from), let ti = letterIndex(to),
              let point = touchPoints[fi],
              let pressed = keyFrames[fi], let target = keyFrames[ti]
        else { return 0 }
        func distance(_ a: KeyPoint, _ b: KeyFrame) -> Double {
            let dx = a.x - b.centerX
            let dy = a.y - b.centerY
            return (dx * dx + dy * dy).squareRoot()
        }
        let toPressed = distance(point, pressed)
        let toTarget = distance(point, target)
        let width = max(pressed.width, 1)
        return min(4, max(0, (toPressed - toTarget) / width * 4))
    }

    /// 词频、自造词或短语文件被别的进程改过或删掉时（主 App 清空学习记录、
    /// 用户手动删文件、另一个键盘进程写过），丢掉内存里的副本重新读盘，
    /// 否则下次写盘会把已清空的内容原样写回去。磁盘为准：未落盘的改动不保留，
    /// 调用方应在会话之间（已经 save 过之后）调用。
    public func reloadIfChangedOnDisk() {
        if let f = freq, f.changedOnDisk { freq = Freq.load(f.path) }
        if let u = user, u.changedOnDisk { user = UserDict.load(u.path) }
        if let p = phrases, p.changedOnDisk { phrases = UserDict.load(p.path) }
    }

    /// 把用户词频和自造词写回磁盘。force 为 false 时词频攒够次数才写，
    /// force 为 true 时只要有改动就写。
    public func save(force: Bool) throws {
        var firstError: Error?
        do {
            if force || (freq?.due() ?? false) {
                try freq?.save()
            }
        } catch {
            firstError = error
        }
        do {
            try user?.save()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    /// 当前的按键缓冲。
    public var buffer: [UInt8] { buf }

    /// 当前页的候选，第一个是默认上屏项。
    public var candidates: [Candidate] { cands }

    /// 当前页码（0 起）。
    public var pageNo: Int { page }

    /// 追加一个字母。返回 false 表示缓冲已满，按键未消费。
    public func type(_ ch: UInt8) -> Bool {
        if buf.count >= maxBuf { return false }
        if buf.isEmpty {
            picked.removeAll(keepingCapacity: true)
            pickedCode.removeAll(keepingCapacity: true)
            singles = 0
            sessionText.removeAll(keepingCapacity: true)
            sessionCode.removeAll(keepingCapacity: true)
            sessionSteps = 0
            sessionValid = true
            englishQuery = false
        }
        buf.append(ch)
        refresh()
        return true
    }

    /// 删掉一个字母。返回 false 表示缓冲本来就是空的。
    public func backspace() -> Bool {
        guard !buf.isEmpty else { return false }
        buf.removeLast()
        refresh()
        return true
    }

    /// 长按删除：一次退掉缓冲末尾一个完整音节（双拼两键）。
    /// 末尾只剩半个音节时退掉它；缓冲空了之后不再继续删正文。
    public func backspaceSyllable() -> Bool {
        guard !buf.isEmpty else { return false }
        let drop = buf.count % 2 == 0 ? 2 : 1
        buf.removeLast(min(drop, buf.count))
        refresh()
        return true
    }

    /// 清空缓冲和这一轮的自造词学习状态。
    public func reset() {
        buf.removeAll(keepingCapacity: true)
        stream = []
        limit = 0
        exhausted = false
        cands = []
        page = 0
        englishQuery = false
        picked.removeAll(keepingCapacity: true)
        pickedCode.removeAll(keepingCapacity: true)
        singles = 0
        sessionText.removeAll(keepingCapacity: true)
        sessionCode.removeAll(keepingCapacity: true)
        sessionSteps = 0
        sessionValid = true
    }

    /// 取出第 i 个候选并把它占用的编码从缓冲里去掉，返回上屏文本。
    /// 剩余缓冲会重新查词，所以可以连续选词。
    public func select(_ i: Int) -> (String, Bool) {
        selectCandidate(i, nil)
    }

    /// 取出第 i 个候选的首字或尾字。编码消耗和 select 一样。
    public func selectChar(_ i: Int, last: Bool) -> (String, Bool) {
        selectCandidate(i) { text in
            let scalars = text.unicodeScalars
            guard let first = scalars.first else { return "" }
            return last ? String(scalars.last ?? first) : String(first)
        }
    }

    func selectCandidate(_ i: Int, _ pick: ((String) -> String)?) -> (String, Bool) {
        guard i >= 0, i < cands.count else { return ("", false) }
        let c = cands[i]
        var text = c.text
        if let pick {
            text = pick(text)
            if text.isEmpty { return ("", false) }
        }
        // 候选的编码可能比缓冲长（词还没打全，例如 wofax 选「我发现」），
        // 这种情况把缓冲整个消耗掉即可。
        var used = c.codeLen
        if used > buf.count { used = buf.count }
        freq?.bump(text)
        // 连续单字选词说明词库里没有这个词，组合结束后记成自造词。
        // 编码只取这串单字自己占用的按键，不能带上前面选过的多字词。
        if c.codeLen == 2 {
            singles += 1
            picked.append(contentsOf: text.utf8)
            pickedCode.append(contentsOf: buf.prefix(used))
        } else {
            singles = 0
            picked.removeAll(keepingCapacity: true)
            pickedCode.removeAll(keepingCapacity: true)
        }
        let stepScalars = text.unicodeScalars
        let isPureChineseStep = pick == nil
            && c.codeLen <= buf.count
            && used % 2 == 0
            && !stepScalars.isEmpty
            && stepScalars.count * 2 == used
            && stepScalars.allSatisfy { $0.value >= 0x80 && $0.properties.isIdeographic }
        if sessionValid && isPureChineseStep {
            sessionSteps += 1
            sessionText.append(contentsOf: text.utf8)
            sessionCode.append(contentsOf: buf.prefix(used))
        } else {
            sessionValid = false
        }
        buf.removeFirst(used)
        if buf.isEmpty {
            if singles >= 2 && pickedCode.count >= 4 {
                user?.add(
                    code: String(decoding: pickedCode, as: UTF8.self),
                    text: String(decoding: picked, as: UTF8.self))
            } else if sessionValid && sessionSteps == 2 && sessionCode.count == 6 {
                let code = umlautVariant(sessionCode) ?? sessionCode
                let phrase = String(decoding: sessionText, as: UTF8.self)
                if !(dict?.containsExact(code, phrase) ?? false) {
                    user?.add(code: String(decoding: code, as: UTF8.self), text: phrase)
                }
            }
            picked.removeAll(keepingCapacity: true)
            pickedCode.removeAll(keepingCapacity: true)
            singles = 0
            sessionText.removeAll(keepingCapacity: true)
            sessionCode.removeAll(keepingCapacity: true)
            sessionSteps = 0
            sessionValid = true
            englishQuery = false
        }
        refresh()
        return (text, true)
    }

    /// 重建候选流并回到第 1 页。每次按键算到第 2 页：候选窗要靠 HasNextPage
    /// 判断有没有下一页，一次算够免得每键重算两遍。
    func refresh() {
        stream = []
        limit = 0
        exhausted = false
        cands = []
        page = 0
        guard !buf.isEmpty else { return }
        if dict == nil, english == nil { return }
        ensure(2 * pageSize)
    }

    /// 保证 stream 至少有 n 个候选，或已经到底。limit 按指数增长，避免每翻
    /// 一页都全量重算；扩大上限只在尾部追加更低分的候选，前面的顺序不变。
    func ensure(_ n: Int) {
        while stream.count < n && !exhausted {
            rebuild(max(n, limit * 2, pageSize))
        }
    }

    /// 重新计算正常候选到 limit 个。不足说明词库到底，顺带把纠错候选接在末尾。
    func rebuild(_ limit: Int) {
        var normal = collect(buf, limit, [])
        // j/q/x/y 后的 ü 在自然码里按 v 键存，但 Rime 也接受照拼音写成 u。
        if let alt = umlautVariant(buf) {
            normal = collect(alt, limit, normal)
        }
        let directExactMatch = (normal.first?.score ?? 0) >> 40 >= Int64(tierExact)
        normal = mergeCandidates(normal, mixedCandidates(buf, limit), limit)
        self.limit = limit
        exhausted = normal.count < limit
        if exhausted {
            normal.append(contentsOf: corrections(buf, normal))
        }
        stream = englishCandidates(
            normal, includeTail: exhausted, directExactMatch: directExactMatch)
        if page * pageSize < stream.count {
            setPage(page)
        }
    }

    /// 英文候选的安插规则：精确命中整串的英文词在中文也有整段真词（tierExact）
    /// 且全小写输入时放在第 2 位；若中文只是前缀、辅码单字、组句拼接、纠错、混输
    /// 或用户输入了大写，英文精确词直接放首位。前缀补全追加在末尾，都不命中时给原文兜底。
    /// 大小写由预编辑串推导，词库里的 display 只作为基准形态。
    func englishCandidates(
        _ normal: [Candidate], includeTail: Bool, directExactMatch: Bool
    ) -> [Candidate] {
        guard let english, englishQuery, !buf.isEmpty else { return normal }
        let lower = Array(String(decoding: buf, as: UTF8.self).lowercased().utf8)
        guard lower.count >= englishMinExact,
              lower.allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") })
        else { return normal }
        let exact = english.lookup(lower, exactOnly: true, limit: englishMaxCandidates)
        let prefix = lower.count >= englishMinPrefix
            ? english.lookup(lower, exactOnly: false, limit: englishMaxCandidates + exact.count)
                .filter { !$0.exact }
            : []
        var out = normal
        if exact.isEmpty && prefix.isEmpty {
            guard includeTail else { return out }
            // 词表不认识这串字母：给一条原文兜底，让「中文态直接打英文」仍可选。
            let raw = englishDisplay(String(decoding: buf, as: UTF8.self))
            if !hasText(out, raw) {
                out.append(Candidate(raw, buf.count, englishScore(tierEnglishRaw, 0)))
            }
            return out
        }
        let hasUppercase = buf.contains { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }
        // 中文没有命中整段真词（仅前缀/辅码单字/组句拼接/纠错/混输），或用户主动按了 Shift，
        // 精确英文词直接排首位；中文整段真词（如「你」「哈哈」「那么」）在全小写下保持首位。
        var at = (hasUppercase || !directExactMatch) ? 0 : min(1, out.count)
        var shown = Set<String>()
        for m in exact {
            let text = englishDisplay(m.display)
            shown.insert(text)
            if hasText(out, text) { continue }
            out.insert(Candidate(text, buf.count, englishScore(tierEnglishExact, m.weight)), at: at)
            at += 1
        }
        if includeTail {
            var inserted = 0
            for m in prefix {
                let text = englishDisplay(m.display)
                if shown.contains(text) || hasText(out, text) { continue }
                shown.insert(text)
                out.append(Candidate(
                    text, buf.count,
                    englishScore(tierEnglishPrefix, m.weight)))
                inserted += 1
                if inserted >= englishMaxCandidates { break }
            }
        }
        return out
    }

    /// 按预编辑串的大小写推导显示形态：首字母大写 → Title，前两个大写 → ALL CAPS，
    /// 其余保持原样。词库里已带混合大小写的专名（GitHub、MacBook）原样保留。
    func englishDisplay(_ word: String) -> String {
        englishDisplay(word, for: buf)
    }

    func englishDisplay(_ word: String, for bytes: [UInt8]) -> String {
        let upperCount = bytes.prefix(2).filter {
            $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")
        }.count
        if upperCount == 2 { return word.uppercased() }
        if let first = bytes.first, first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z") {
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return word
    }

    /// 纠错候选，按文本去掉正常段里已有的词。只在正常段到底后调用。
    func corrections(_ buf: [UInt8], _ normal: [Candidate]) -> [Candidate] {
        guard let dict else { return [] }
        let bonus = hasTouchGeometry ? typoBonus : nil
        var corrs = dict.corrections(buf, maxCorrections, touchBonus: bonus)
        if let alt = umlautVariant(buf) {
            corrs = mergeCandidates(
                corrs, dict.corrections(alt, maxCorrections, touchBonus: bonus), maxCorrections)
        }
        var out: [Candidate] = []
        for c in corrs where !hasText(normal, c.text) && !hasText(out, c.text) {
            out.append(c)
        }
        return out
    }

    /// 几何全齐、且这串缓冲里的字母都有落点时，纠错才按落点加权。
    /// 只按本次缓冲判断：没碰过的键不该让整句纠错退回不加权。
    private var hasTouchGeometry: Bool {
        keyFrames.allSatisfy { $0 != nil }
            && buf.allSatisfy { letter in
                guard let index = letterIndex(letter) else { return true }
                return touchPoints[index] != nil
            }
    }

    /// 收集一种拼写下的正常候选，最多 limit 个。
    func collect(_ buf: [UInt8], _ limit: Int, _ cands: [Candidate]) -> [Candidate] {
        var cands = cands
        guard let dict else { return cands }
        if buf.count == 1 {
            // 单键：给出这个键开头的最高频词，例如 l → 了。
            cands = mergeCandidates(cands, dict.short(buf[0], freq), limit)
        } else {
            cands = collectDict(buf, limit, cands)
        }
        if let phrases {
            cands = mergeCandidates(cands, phrases.lookup(buf, limit, freq), limit)
        }
        if let user {
            cands = mergeCandidates(cands, user.lookup(buf, limit, freq), limit)
        }
        return cands
    }

    func collectDict(_ code: [UInt8], _ limit: Int, _ cands: [Candidate]) -> [Candidate] {
        var cands = cands
        guard let dict, code.count >= 2 else { return cands }
        cands = mergeCandidates(cands, dict.lookup(code, limit: limit, freq: freq), limit)
        for c in dict.compose(code, limit: limit, freq: freq) {
            cands = insertCandidate(cands, c, limit)
        }
        return cands
    }

    /// 中英混输候选：缓冲里有大写字母（由 Shift 引入）时，把末尾至少两键的纯小写
    /// 双拼后缀拆出来查中文词和组句，再和前面的单大写字母、全大写缩写或已命中的
    /// 英文词用空格拼成混排候选。全小写输入不进这条路径，避免干扰双拼简拼和纠错。
    func mixedCandidates(_ buf: [UInt8], _ limit: Int) -> [Candidate] {
        guard dict != nil, buf.count >= 3, limit > 0,
              let lastUpper = buf.lastIndex(where: { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }),
              lastUpper + 2 < buf.count
        else { return [] }
        let tailStart = lastUpper + 1
        guard buf[tailStart...].allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") })
        else { return [] }

        var out: [Candidate] = []
        for splitAt in tailStart...(buf.count - 2) {
            let prefix = Array(buf[0..<splitAt])
            guard let prefixText = mixedPrefix(prefix) else { continue }
            let tail = Array(buf[splitAt..<buf.count])
            var chinese = collectDict(tail, limit, [])
            if let alt = umlautVariant(tail) {
                chinese = collectDict(alt, limit, chinese)
            }
            for c in chinese {
                let text = prefixText + " " + c.text
                let score = c.score + (freq?.boost(text) ?? 0)
                out = insertCandidate(out, Candidate(text, splitAt + c.codeLen, score), limit)
            }
        }
        return out
    }

    func mixedPrefix(_ prefix: [UInt8]) -> String? {
        if prefix.count == 1 {
            return String(decoding: prefix, as: UTF8.self)
        }
        if prefix.allSatisfy({ $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }) {
            return String(decoding: prefix, as: UTF8.self)
        }
        guard let english else { return nil }
        let lower = Array(String(decoding: prefix, as: UTF8.self).lowercased().utf8)
        guard lower.count >= englishMinExact,
              lower.allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }),
              let match = english.lookup(lower, exactOnly: true, limit: 1).first
        else { return nil }
        return englishDisplay(match.display, for: prefix)
    }

    /// 把当前页指向 stream 的第 target 页切片。调用前须保证该页有候选。
    func setPage(_ target: Int) {
        let start = target * pageSize
        let end = min((target + 1) * pageSize, stream.count)
        page = target
        cands = Array(stream[start..<end])
    }

    /// 翻页。delta 为 +1/-1，返回 false 表示没有翻动（已到首页/末页）。
    public func page(_ delta: Int) -> Bool {
        if delta == 0 || stream.isEmpty { return false }
        let target = page + delta
        if target < 0 { return false }
        ensure((target + 1) * pageSize)
        if target * pageSize >= stream.count { return false }
        setPage(target)
        return true
    }

    /// 是否还有下一页。按需把流补到下一页页尾再判断。
    public func hasNextPage() -> Bool {
        if stream.isEmpty { return false }
        ensure((page + 2) * pageSize)
        return stream.count > (page + 1) * pageSize
    }

    /// 流里的全部候选（最多 maxPages 页），供键盘一次展开。它只补建流，不改变当前页。
    public func allCandidates() -> [Candidate] {
        if stream.isEmpty { return [] }
        ensure(maxPages * pageSize)
        return Array(stream[..<min(maxPages * pageSize, stream.count)])
    }

    /// 选出流里的第 i 个候选，索引可以落在后续页。
    public func selectGlobal(_ i: Int) -> (String, Bool) {
        if i < 0 { return ("", false) }
        ensure(i + 1)
        if i >= stream.count { return ("", false) }
        cands = stream
        return select(i)
    }

    /// 选出流里第 i 个候选的首字或尾字，索引可以落在后续页。
    public func selectCharGlobal(_ i: Int, last: Bool) -> (String, Bool) {
        if i < 0 { return ("", false) }
        ensure(i + 1)
        if i >= stream.count { return ("", false) }
        cands = stream
        return selectChar(i, last: last)
    }
}

func hasText(_ cands: [Candidate], _ text: String) -> Bool {
    for c in cands where c.text == text {
        return true
    }
    return false
}

/// 把 j/q/x/y + u 的两键组合改写成 j/q/x/y + v。
/// 双拼里每个音节固定两键，所以按位置判断不会误伤别的韵母。
func umlautVariant(_ buf: [UInt8]) -> [UInt8]? {
    var out: [UInt8]?
    var changed = false
    var i = 0
    while i + 1 < buf.count {
        let c = buf[i]
        if (c == UInt8(ascii: "j") || c == UInt8(ascii: "q")
            || c == UInt8(ascii: "x") || c == UInt8(ascii: "y"))
            && buf[i + 1] == UInt8(ascii: "u")
        {
            if out == nil { out = buf }
            out![i + 1] = UInt8(ascii: "v")
            changed = true
        }
        i += 2
    }
    return changed ? out : nil
}

/// 合并两种拼写写法的候选，保持分层与词频顺序。
func mergeCandidates(_ a: [Candidate], _ b: [Candidate], _ limit: Int) -> [Candidate] {
    if b.isEmpty { return a }
    var out: [Candidate] = []
    out.reserveCapacity(limit)
    for list in [a, b] {
        for c in list {
            out = insertCandidate(out, c, limit)
        }
    }
    return out
}
