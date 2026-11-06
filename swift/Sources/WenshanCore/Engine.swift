/// 输入缓冲的上限（字节，双拼每音节两字节）。
let maxBuf = 32

/// 单键简码每个字母最多存的候选数；候选窗每页也用它。
let maxCandidates = 9
/// 一页的候选数，对应数字键 1-9。
let pageSize = maxCandidates
/// 只用于 iOS 键盘一次性展开全部候选的网格上限；逐页翻页不受它限制。
let maxPages = 20
/// 纠错段最多保留的候选数。
let maxCorrections = 20

/// 持有一次输入过程的全部状态。只在主线程上被调用，不加锁。
public final class Engine {
    let dict: Dict?
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

    /// 自造词的学习状态：本次组合输入过的全部按键、连续单字选出来的文字。
    var session: [UInt8] = []
    var picked: [UInt8] = []
    var singles = 0

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
            session.removeAll(keepingCapacity: true)
            picked.removeAll(keepingCapacity: true)
            singles = 0
        }
        buf.append(ch)
        session.append(ch)
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

    /// 清空缓冲和这一轮的自造词学习状态。
    public func reset() {
        buf.removeAll(keepingCapacity: true)
        stream = []
        limit = 0
        exhausted = false
        cands = []
        page = 0
        session.removeAll(keepingCapacity: true)
        picked.removeAll(keepingCapacity: true)
        singles = 0
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
        if c.codeLen == 2 {
            singles += 1
            picked.append(contentsOf: text.utf8)
        } else {
            singles = 0
            picked.removeAll(keepingCapacity: true)
        }
        buf.removeFirst(used)
        if buf.isEmpty {
            if singles >= 2 && session.count >= 4 {
                user?.add(
                    code: String(decoding: session, as: UTF8.self),
                    text: String(decoding: picked, as: UTF8.self))
            }
            session.removeAll(keepingCapacity: true)
            picked.removeAll(keepingCapacity: true)
            singles = 0
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
        guard dict != nil, !buf.isEmpty else { return }
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
        self.limit = limit
        exhausted = normal.count < limit
        if exhausted {
            normal.append(contentsOf: corrections(buf, normal))
        }
        stream = normal
        if page * pageSize < stream.count {
            setPage(page)
        }
    }

    /// 纠错候选，按文本去掉正常段里已有的词。只在正常段到底后调用。
    func corrections(_ buf: [UInt8], _ normal: [Candidate]) -> [Candidate] {
        guard let dict else { return [] }
        var corrs = dict.corrections(buf, maxCorrections)
        if let alt = umlautVariant(buf) {
            corrs = mergeCandidates(corrs, dict.corrections(alt, maxCorrections), maxCorrections)
        }
        var out: [Candidate] = []
        for c in corrs where !hasText(normal, c.text) && !hasText(out, c.text) {
            out.append(c)
        }
        return out
    }

    /// 收集一种拼写下的正常候选，最多 limit 个。
    func collect(_ buf: [UInt8], _ limit: Int, _ cands: [Candidate]) -> [Candidate] {
        var cands = cands
        guard let dict else { return cands }
        if buf.count == 1 {
            // 单键：给出这个键开头的最高频词，例如 l → 了。
            cands = mergeCandidates(cands, dict.short(buf[0], freq), limit)
        } else {
            cands = mergeCandidates(cands, dict.lookup(buf, limit: limit, freq: freq), limit)
            for c in dict.compose(buf, limit: limit, freq: freq) {
                cands = insertCandidate(cands, c, limit)
            }
        }
        if let phrases {
            cands = mergeCandidates(cands, phrases.lookup(buf, limit, freq), limit)
        }
        if let user {
            cands = mergeCandidates(cands, user.lookup(buf, limit, freq), limit)
        }
        return cands
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
