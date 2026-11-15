import Foundation

/// 攒够多少次选词才落盘。写在按键路径上，所以频率要低。
let saveEvery = 50

/// 词频表最多保留的词数。超出时写盘前淘汰选得最少的词。
let maxFreqEntries = 20_000

let maxBoostCount: UInt32 = 50
let boostPerPick: Int64 = 1_000_000

/// 二元接续最多保留的词对数、单次接续的封顶次数和每次的加权。
/// 它只把上下文里常接着出现的词往前挪，不该盖过词频本身。
let maxPairEntries = 20_000
let maxPairCount: UInt32 = 20
let boostPerPair: Int64 = 200_000
/// 上下文接续的有效时长（秒）：超过这个时间后不把上一句话的末字带进下一句。
let contextTimeout: TimeInterval = 5.0
/// 组句 DP 选分段时的用户词频加成上限（按编码隔离后不再有异读音劫持问题）。
let composeEdgeFreqBoost = 4.0
/// 组句锁定分段后，末尾段同音备选重排时的用户词频加成上限。
let composeLastFreqBoost = 6.0

/// 一次选词上屏写入的学习增量，供紧接着退格时精确回滚。
struct FreqDelta {
    var codeKey: String?
    var legacyText: String?
    var pairKeys: [String]
    var prevContext: String
    var prevContextAt: TimeInterval
}

/// 记录用户实际选过的词，以及「上一个上屏词的末字 → 这个词」的接续，
/// 用来把常用的词和接在它后面的词往前排。只在主线程访问，不加锁。
public final class Freq {
    /// 兼容/直接按词文本计数的表（多字旧记录或单测构造）；实际选词优先写入 codeCounts。
    var counts: [String: UInt32]
    /// 按「编码 \t 词」隔离的用户词频，避免多音字（「的」de/di）跨读音污染。
    var codeCounts: [String: UInt32]
    /// 键是「上一个上屏词的末字 \t 当前词」。
    var pairs: [String: UInt32]
    /// 最近一次上屏词的末字，作为下一次候选的上下文。
    var context: String
    /// 最近一次更新 context 的时间戳（referenceDate）。
    var contextAt: TimeInterval
    var dirty: Int
    let path: String
    /// 上次读入或写出时文件的修改时间，用来发现别的进程改过它。
    var diskStamp: Date?

    public init(
        counts: [String: UInt32] = [:],
        codeCounts: [String: UInt32] = [:],
        pairs: [String: UInt32] = [:],
        path: String = ""
    ) {
        self.counts = counts
        self.codeCounts = codeCounts
        self.pairs = pairs
        self.context = ""
        self.contextAt = 0
        self.dirty = 0
        self.path = path
    }

    /// 读取词频文件。
    /// - 两列：「词<TAB>次数」（仅保留多字词旧记录；单字旧记录丢弃以防多音字跨音污染）。
    /// - 三列首列为纯 ASCII 小写编码（>=2 字符）：「编码<TAB>词<TAB>次数」。
    /// - 三列首列为单个非 ASCII 汉字：「上文末字<TAB>词<TAB>次数」。
    /// 文件不存在或读不动时返回空表，不影响输入。
    public static func load(_ path: String) -> Freq {
        let f = Freq(path: path)
        f.diskStamp = fileStamp(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return f }
        for line in textLines(String(decoding: data, as: UTF8.self)) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let digits = parts[parts.count - 1]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let n = UInt32(digits)
            else { continue }
            if parts.count == 2 {
                guard parts[0].unicodeScalars.count >= 2 else { continue }
                f.counts[String(parts[0])] = n
            } else {
                guard !parts[0].isEmpty, !parts[1].isEmpty else { continue }
                if isASCIILowerCode(parts[0]) {
                    f.codeCounts[String(parts[0]) + "\t" + String(parts[1])] = n
                } else if parts[0].unicodeScalars.count == 1,
                          let scalar = parts[0].unicodeScalars.first, scalar.value >= 0x80
                {
                    f.pairs[String(parts[0]) + "\t" + String(parts[1])] = n
                }
            }
        }
        return f
    }

    /// 某个词被选过多少次（合并按编码记录与通用计数）。
    public func count(_ text: String) -> UInt32 {
        var total = counts[text] ?? 0
        let suffix = "\t" + text
        for (k, v) in codeCounts where k.hasSuffix(suffix) {
            total = total &+ v
        }
        return total
    }

    /// 某个编码下该词被选过多少次。
    public func count(_ text: String, code: String) -> UInt32 {
        if !code.isEmpty, let c = codeCounts[code + "\t" + text] {
            return c
        }
        return counts[text] ?? 0
    }

    /// 主动清空上下文（切换输入框、输入标点或超时）。
    public func clearContext() {
        context = ""
        contextAt = 0
    }

    func activeContext(now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> String {
        guard !context.isEmpty else { return "" }
        if contextAt > 0, now - contextAt > contextTimeout {
            return ""
        }
        return context
    }

    /// 记一次选词：累计词频，并记下它接在上一个词后面的次数。
    /// 上下文取末字而不是整词：整句上屏后也能接着用，词对也更稠密。
    @discardableResult
    func bump(
        _ text: String, code: String = "",
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> FreqDelta? {
        guard !text.isEmpty else { return nil }
        let prevContext = context
        let prevContextAt = contextAt
        var codeKey: String?
        var legacyText: String?
        if !code.isEmpty, isASCIILowerCode(code[...]) {
            let key = code + "\t" + text
            codeCounts[key, default: 0] += 1
            codeKey = key
        } else {
            counts[text, default: 0] += 1
            legacyText = text
        }
        var pairKeys: [String] = []
        let ctx = activeContext(now: now)
        if !ctx.isEmpty {
            let key = ctx + "\t" + text
            pairs[key, default: 0] += 1
            pairKeys.append(key)
        }
        let isASCIIOnly = text.utf8.allSatisfy { $0 < 0x80 }
        if !isASCIIOnly {
            // 一次上屏可能是一个整句或组句拼出来的长词，把内部的相邻字也记成
            // 单字接续，组句时逐段就能用上，不必等这个词再被单独选一次。
            let chars = Array(text)
            if chars.count > 1 {
                for i in 1..<chars.count {
                    let key = String(chars[i - 1]) + "\t" + String(chars[i])
                    pairs[key, default: 0] += 1
                    pairKeys.append(key)
                }
            }
            if let last = text.last {
                context = String(last)
                contextAt = now
            }
        } else {
            context = ""
            contextAt = 0
        }
        dirty += 1
        return FreqDelta(
            codeKey: codeKey, legacyText: legacyText, pairKeys: pairKeys,
            prevContext: prevContext, prevContextAt: prevContextAt)
    }

    /// 上屏后立即退格：撤销刚刚那次错误选词写入的词频和二元接续。
    func rollback(_ delta: FreqDelta) {
        if let key = delta.codeKey, let n = codeCounts[key] {
            if n <= 1 { codeCounts.removeValue(forKey: key) } else { codeCounts[key] = n - 1 }
        }
        if let text = delta.legacyText, let n = counts[text] {
            if n <= 1 { counts.removeValue(forKey: text) } else { counts[text] = n - 1 }
        }
        for key in delta.pairKeys {
            if let n = pairs[key] {
                if n <= 1 { pairs.removeValue(forKey: key) } else { pairs[key] = n - 1 }
            }
        }
        context = delta.prevContext
        contextAt = delta.prevContextAt
        dirty += 1
    }

    /// 未落盘的选词是否攒够了 saveEvery 次。
    func due() -> Bool { dirty >= saveEvery }

    /// 从候选菜单删词：把这个词的次数和以它为首/尾的接续一起清掉。
    @discardableResult
    public func remove(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let removedCounts = counts.removeValue(forKey: text) != nil
        let suffix = "\t" + text
        let matchingCodeKeys = codeCounts.keys.filter { $0.hasSuffix(suffix) }
        for key in matchingCodeKeys {
            codeCounts.removeValue(forKey: key)
        }
        let prefix = text + "\t"
        let matchingKeys = pairs.keys.filter { $0.hasSuffix(suffix) || $0.hasPrefix(prefix) }
        for key in matchingKeys {
            pairs.removeValue(forKey: key)
        }
        if context == text { clearContext() }
        let removedCodeCounts = !matchingCodeKeys.isEmpty
        let removedPairs = !matchingKeys.isEmpty
        if removedCounts || removedCodeCounts || removedPairs {
            dirty += 1
            return true
        }
        return false
    }

    /// 把词频和二元接续写回磁盘，都按次数从多到少排列，超过上限的淘汰掉。
    public func save() throws {
        guard dirty > 0 else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let texts = cappedKeys(&counts, maxFreqEntries)
        let codeKeys = cappedKeys(&codeCounts, maxFreqEntries)
        let keys = cappedKeys(&pairs, maxPairEntries)
        var out = ""
        out.reserveCapacity((texts.count + codeKeys.count + keys.count) * 14)
        for text in texts {
            out += "\(text)\t\(counts[text] ?? 0)\n"
        }
        for key in codeKeys {
            out += "\(key)\t\(codeCounts[key] ?? 0)\n"
        }
        for key in keys {
            out += "\(key)\t\(pairs[key] ?? 0)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
        dirty = 0
        diskStamp = fileStamp(path)
    }

    /// 文件在上次读写之后被别的进程改过或删掉。
    var changedOnDisk: Bool {
        !path.isEmpty && fileStamp(path) != diskStamp
    }

    /// text 的词频加权，加上「上一个上屏词的末字 → text」的接续加权。
    /// 封顶是为了不让个别词永远霸榜，同时也保证它只影响层内的顺序，
    /// 翻不过「整段匹配」那一层。
    func boost(
        _ text: String, code: String = "",
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Int64 {
        let c = pickCount(text, code: code)
        return freqBoost(c) + pairBoost(text, now: now)
    }

    /// 直接用词表里的字节查表，省掉调用方先拼字符串。
    func boost(
        _ raw: UnsafeRawBufferPointer, _ off: Int, _ len: Int, code: String = "",
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Int64 {
        boost(String(decoding: raw[off..<(off + len)], as: UTF8.self), code: code, now: now)
    }

    func pickCount(_ text: String, code: String) -> UInt32 {
        if !code.isEmpty, let c = codeCounts[code + "\t" + text] {
            return c
        }
        return counts[text] ?? 0
    }

    /// 组句里一段接在上一段（或上文）末字后面时，折算成 log 权重的加成。
    /// 没学过就是 0，冷启动完全靠词频。
    func segmentBoost(_ previousLast: String?, _ text: String) -> Double {
        guard let previousLast, !previousLast.isEmpty,
              let first = text.first, first.unicodeScalars.count == 1
        else { return 0 }
        let key = previousLast + "\t" + String(first)
        let n = min(pairs[key] ?? 0, maxPairCount)
        return n == 0 ? 0 : composePairBoost * log(Double(n) + 1) / log(Double(maxPairCount) + 1)
    }

    /// 组句段内选词时，按用户历史词频折算的 log 权重加成。
    func wordLogBoost(
        _ text: String, code: String = "", maxBoost: Double = composeEdgeFreqBoost
    ) -> Double {
        let n = min(pickCount(text, code: code), maxBoostCount)
        return n == 0 ? 0 : maxBoost * log(Double(n) + 1) / log(Double(maxBoostCount) + 1)
    }

    func pairBoost(
        _ text: String, now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Int64 {
        let ctx = activeContext(now: now)
        guard !ctx.isEmpty else { return 0 }
        return Int64(min(pairs[ctx + "\t" + text] ?? 0, maxPairCount)) * boostPerPair
    }

    /// 任何词能拿到的最大加权，用来在查表前先排除进不了候选的词。
    func maxBoost(now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Int64 {
        let hasFreq = !counts.isEmpty || !codeCounts.isEmpty
        let hasCtx = !activeContext(now: now).isEmpty
        return (hasFreq ? Int64(maxBoostCount) * boostPerPick : 0)
            + (hasCtx ? Int64(maxPairCount) * boostPerPair : 0)
    }
}

@inline(__always)
func isASCIILowerCode(_ s: Substring) -> Bool {
    s.utf8.count >= 2 && s.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
}

/// 按次数降序、同次数按键的字节序排好，超过 cap 的从表里淘汰，返回留下的键。
func cappedKeys(_ table: inout [String: UInt32], _ cap: Int) -> [String] {
    let counts = table
    var keys = Array(counts.keys)
    keys.sort { a, b in
        let ca = counts[a] ?? 0
        let cb = counts[b] ?? 0
        if ca != cb { return ca > cb }
        return a.utf8.lexicographicallyPrecedes(b.utf8)
    }
    if keys.count > cap {
        for key in keys[cap...] { table.removeValue(forKey: key) }
        keys.removeLast(keys.count - cap)
    }
    return keys
}

@inline(__always)
func freqBoost(_ n: UInt32) -> Int64 {
    Int64(min(n, maxBoostCount)) * boostPerPick
}

/// 文件的修改时间，文件不存在时为 nil。不走 URL 的资源缓存，每次都问文件系统。
func fileStamp(_ path: String) -> Date? {
    guard !path.isEmpty else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

/// 按行切分：去掉行尾的 \n，也去掉 \r\n 里的 \r。
func textLines(_ text: String) -> [String] {
    var parts = text.components(separatedBy: "\n")
    if parts.last == "" { parts.removeLast() }
    for i in parts.indices where parts[i].hasSuffix("\r") {
        parts[i].removeLast()
    }
    return parts
}
