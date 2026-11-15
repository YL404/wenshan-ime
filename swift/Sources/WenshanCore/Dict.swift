import Foundation

/// 词表二进制格式（小端）：
///
///     [0:6]   magic "WSIME2"
///     [6:8]   保留
///     [8:12]  条目数 n
///     [12:16] 字符串区长度
///     [16:20] 单字母简码条数 m
///     [20:24] 静态二元搭配条数 b
///     之后 n×16 主记录、m×16 简码记录、字符串区，最后是 b×12 静态二元搭配记录。
///
/// 主记录按编码升序、同编码按权重降序排列，所以一次二分就能定位前缀区间。
/// 简码记录是每个字母开头权重最高的若干条，按字母分组，供单键输入使用。
/// 静态二元搭配记录按 64 位 FNV-1a 哈希升序排列，供组句 DP 做零分配共现查表。
let dictMagicBytes = Array("WSIME2".utf8)
let headerSize = 24
let recordSize = 16
let bigramRecordSize = 12

/// 一次前缀查询最多检查的条目数，防止两字母前缀退化成全表扫描。
let maxScan = 20_000

// 拼接参数：单个词最多覆盖 8 个音节；每多切一个词扣 segmentPenalty。
// 单字权重普遍在百万级（自然对数 14-17），所以这个惩罚必须大于它，
// 否则「级+许」这种高频单字凑出来的东西会压过真正的词「继续」。
let maxWordSyllables = 8
let segmentPenalty = 20.0
/// 单音节段额外惩罚（单位是 log 权重）：单字表权重普遍比词库高出两个数量级，
/// 防止两个高频单字（「地+而」）在组句时拆散常用两字词（「第二」）。
let singleCharPenalty = 3.5
let altPerSegment = 12
let lastSegmentScan = 24
let lastSegmentAlts = 5
/// 组句换字副本折扣，单位是 log 权重。只给最后一段出备选，前面各段锁定
/// 最优拼法；副本是备选而不是另一条独立句子，不该和主拼法抢同一层。
let composeVariantPenalty = 8.0
/// 组句逐段接续的加权，单位是 log 权重。首段接上文末字，后续段接前段末字。
/// 单次接最大约 composePairBoost，足够在学过后把换字副本翻上来。
let composePairBoost = 8.0
/// 组句总得分映射回整型权重时的基准偏移和缩放，保留多段长句与换字副本的相对排序。
let composeScoreOffset = 100.0
let composeScoreScale = 10_000.0
/// 组句静态二元搭配的最高对数加权。
let composeStaticBigramBoost = 5.0
let composeBeamWidth = 2
/// 数字后面输入量词时的层内提权。
let classifierBoost: Int64 = 20_000_000
let classifiers: Set<String> = [
    "个", "只", "名", "位", "口", "头", "匹", "条", "群", "批", "伙",
    "张", "把", "件", "台", "部", "块", "根", "颗", "粒", "滴", "片",
    "年", "月", "周", "天", "日", "岁", "秒", "分", "刻", "代", "期", "届", "任",
    "米", "寸", "尺", "里", "斤", "两", "吨", "克", "升", "元", "角", "毛",
    "次", "遍", "回", "场", "趟", "句", "段", "页", "行", "节", "门", "类", "种", "项",
    "套", "辆", "架", "艘", "座", "栋", "间", "所", "家", "封", "份", "支", "枝", "盏", "双", "对", "副",
]

public enum DictError: Error, CustomStringConvertible {
    case badHeader
    case truncated

    public var description: String {
        switch self {
        case .badHeader: return "dict: 文件头不对"
        case .truncated: return "dict: 文件被截断"
        }
    }
}

/// 一个候选词。
public struct Candidate: Equatable, Sendable {
    public var text: String
    /// 编码长度（字节），选词后要从输入缓冲里去掉这么多。
    public var codeLen: Int
    var score: Int64
    /// 命中的完整编码（供按编码隔离的用户词频学习）。
    var code: String

    init(_ text: String, _ codeLen: Int, _ score: Int64, code: String = "") {
        self.text = text
        self.codeLen = codeLen
        self.score = score
        self.code = code
    }
}

/// 构建词表时的一条记录。
public struct Entry: Equatable, Sendable {
    public var code: String
    public var text: String
    public var weight: UInt32

    public init(code: String, text: String, weight: UInt32) {
        self.code = code
        self.text = text
        self.weight = weight
    }
}

/// 构建词表时的一条静态二元搭配记录。
public struct BigramEntry: Equatable, Sendable {
    public var hash: UInt64
    public var weight: UInt32

    public init(hash: UInt64, weight: UInt32) {
        self.hash = hash
        self.weight = weight
    }
}

/// 确定性 64 位 FNV-1a 哈希，供 dictgen 与运行时二进制检索共用。
@inline(__always)
public func bigramHash(_ left: String, _ right: String) -> UInt64 {
    var h: UInt64 = 14_695_981_039_346_656_037
    let prime: UInt64 = 1_099_511_628_211
    for b in left.utf8 {
        h ^= UInt64(b)
        h &*= prime
    }
    h ^= 0xFF
    h &*= prime
    for b in right.utf8 {
        h ^= UInt64(b)
        h &*= prime
    }
    return h
}

/// 同一编码下的一种写法。
struct AltText {
    var text: String
    var weight: UInt32
}

// 候选分六层：编码刚好用完缓冲的最优先（打 ni 给「你」，打 nihk 给「你好」），
// 其次是组句拼出来的整句，再次是还没打完的真实长词，然后是单字辅码，
// 最后是用掉前几个键的短词。
// 组句不是词库里的词，单列一层，免得它按合成权重压过同编码的真实词。
// 辅码单字不是词组，单列在真实长词之后、两键短匹配之前，免得高频单字（yyg「应」）
// 在三键简拼时抢走两字词（yygl「应该」）的首位。
// 层号放在高位，层内按词频排。tierTypo 留给纠错候选，永远在正常候选之后。
let tierTypo = 0
let tierShort = 1
let tierAux = 2
let tierLong = 3
let tierCompose = 4
let tierExact = 5
/// 英文候选独占一层：精确命中整串时，若中文有整段真词则排其后，否则直排首位；
/// 前缀补全追加在正常候选末尾。
/// 用层号把它们和组句、词库真词隔离开，位置由 Engine 单独安插。
let tierEnglishExact = 6
let tierEnglishPrefix = 1
let tierEnglishRaw = 0

/// 每多一个未打完的整音节，长词前缀的词表权重右移的位数（除以 8）。
/// 让三键简拼时两字词不被更长的多字词淹没，同时保留高频三字词与用户词频加权。
let longExtraSyllableShift = 3

/// 英文候选的分数：层号占高位，权重只决定同层内的顺序。
@inline(__always)
func englishScore(_ tier: Int, _ weight: UInt32) -> Int64 {
    Int64(tier) << 40 | Int64(weight)
}

@inline(__always)
func candidateScore(_ weight: UInt32, _ codeLen: Int, _ bufLen: Int) -> Int64 {
    var tier = Int64(tierShort)
    if codeLen == bufLen {
        tier = Int64(tierExact)
    } else if codeLen > bufLen {
        tier = Int64(tierLong)
        let extraSyllables = (codeLen - bufLen) / 2
        if extraSyllables > 0 {
            let shifted = Int64(weight) >> min(32, extraSyllables * longExtraSyllableShift)
            return tier << 40 | shifted
        }
    }
    // 覆盖按键多的短词更具体，奇偶缓冲都排在覆盖少的单字前面：
    // 打 wofaxmv 时「我发现」不沉到「握」「窝」后面，打 dierpy 时「第二」不沉到「地」「第」后面。
    if tier == Int64(tierShort) {
        return tier << 40 | Int64(codeLen) << 32 | Int64(weight)
    }
    return tier << 40 | Int64(weight)
}

/// 词表条目的分数。三键编码只可能来自单字辅码（词的编码都是偶数），它不是
/// 一个打完的词，降到辅码层让真实词组优先。
@inline(__always)
func lookupScore(_ weight: UInt32, _ codeLen: Int, _ bufLen: Int) -> Int64 {
    if codeLen == 3 && bufLen == 3 {
        return Int64(tierAux) << 40 | Int64(weight)
    }
    return candidateScore(weight, codeLen, bufLen)
}

@inline(__always)
func readU32(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
    UInt32(p[o])
        | UInt32(p[o + 1]) << 8
        | UInt32(p[o + 2]) << 16
        | UInt32(p[o + 3]) << 24
}

@inline(__always)
func readU32(_ data: Data, _ o: Int) -> UInt32 {
    data.withUnsafeBytes { readU32($0, o) }
}

@inline(__always)
func readU64(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
    UInt64(readU32(p, o)) | (UInt64(readU32(p, o + 4)) << 32)
}

@inline(__always)
func writeU32(_ p: inout [UInt8], _ o: Int, _ v: UInt32) {
    p[o] = UInt8(truncatingIfNeeded: v)
    p[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    p[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
    p[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
}

@inline(__always)
func writeU64(_ p: inout [UInt8], _ o: Int, _ v: UInt64) {
    writeU32(&p, o, UInt32(truncatingIfNeeded: v))
    writeU32(&p, o + 4, UInt32(truncatingIfNeeded: v >> 32))
}

/// 数 UTF-8 字节里的码点数。
@inline(__always)
func runeCount(_ p: UnsafeRawBufferPointer, _ off: Int, _ len: Int) -> Int {
    var count = 0
    var i = 0
    while i < len {
        let b = p[off + i]
        if b < 0x80 {
            i += 1
        } else if b < 0xE0 {
            i += 2
        } else if b < 0xF0 {
            i += 3
        } else {
            i += 4
        }
        count += 1
    }
    return count
}

@inline(__always)
func decode(_ p: UnsafeRawBufferPointer, _ off: Int, _ len: Int) -> String {
    String(decoding: p[off..<(off + len)], as: UTF8.self)
}

/// 映射到内存的词表，只读。持有 Data，查询时临时取字节指针，不做拷贝。
public struct Dict: Sendable {
    let data: Data
    let n: Int
    let shortCount: Int
    let bigramCount: Int
    /// 字符串区在 data 里的起始位置。
    let blobStart: Int
    /// 静态二元搭配区在 data 里的起始位置。
    let bigramStart: Int

    public init(data: Data) throws {
        guard data.count >= headerSize,
              data.prefix(dictMagicBytes.count).elementsEqual(dictMagicBytes)
        else {
            throw DictError.badHeader
        }
        let n = Int(readU32(data, 8))
        let blobLen = Int(readU32(data, 12))
        let short = Int(readU32(data, 16))
        let bigrams = Int(readU32(data, 20))
        let recEnd = headerSize + (n + short) * recordSize
        let bigramStart = recEnd + blobLen
        guard recEnd <= data.count,
              bigramStart <= data.count,
              bigramStart + bigrams * bigramRecordSize <= data.count
        else {
            throw DictError.truncated
        }
        self.data = data
        self.n = n
        self.shortCount = short
        self.bigramCount = bigrams
        self.blobStart = recEnd
        self.bigramStart = bigramStart
    }

    /// 条目数。
    public var count: Int { n }
}

extension Dict {
    @inline(__always)
    func codeRange(_ raw: UnsafeRawBufferPointer, _ i: Int) -> (offset: Int, length: Int) {
        let r = headerSize + i * recordSize
        return (blobStart + Int(readU32(raw, r)), Int(raw[r + 12]))
    }

    @inline(__always)
    func textRange(_ raw: UnsafeRawBufferPointer, _ i: Int) -> (offset: Int, length: Int) {
        let r = headerSize + i * recordSize
        return (blobStart + Int(readU32(raw, r + 4)), Int(raw[r + 13]))
    }

    @inline(__always)
    func weight(_ raw: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
        readU32(raw, headerSize + i * recordSize + 8)
    }

    /// 返回第一个编码不小于 prefix 的条目下标。
    func lowerBound(_ raw: UnsafeRawBufferPointer, _ prefix: UnsafeBufferPointer<UInt8>) -> Int {
        var lo = 0
        var hi = n
        while lo < hi {
            let mid = (lo + hi) >> 1
            let (off, len) = codeRange(raw, mid)
            var order = 0
            let m = min(len, prefix.count)
            var k = 0
            while k < m {
                let a = raw[off + k]
                let b = prefix[k]
                if a != b {
                    order = a < b ? -1 : 1
                    break
                }
                k += 1
            }
            if order == 0 {
                if len == prefix.count {
                    order = 0
                } else {
                    order = len < prefix.count ? -1 : 1
                }
            }
            if order < 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    @inline(__always)
    func codeHasPrefix(
        _ raw: UnsafeRawBufferPointer, _ i: Int, _ prefix: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        let (off, len) = codeRange(raw, i)
        guard len >= prefix.count else { return false }
        var k = 0
        while k < prefix.count {
            if raw[off + k] != prefix[k] { return false }
            k += 1
        }
        return true
    }

    @inline(__always)
    func codeEquals(
        _ raw: UnsafeRawBufferPointer, _ i: Int, _ code: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        codeRange(raw, i).length == code.count && codeHasPrefix(raw, i, code)
    }

    /// 编码以缓冲开头的词，加上前半段已经打完的词，按权重合并排序。
    public func lookup(
        _ buf: [UInt8], limit: Int, freq: Freq?, afterDigit: Bool = false
    ) -> [Candidate] {
        guard buf.count >= 2, limit > 0, n > 0 else { return [] }
        let now = Date.timeIntervalSinceReferenceDate
        let maxFreqBoost = freq?.maxBoost(now: now) ?? 0
        return data.withUnsafeBytes { raw in
            buf.withUnsafeBufferPointer { p in
                var best: [Candidate] = []
                // 已打完的更短词：只需在等长段里找，代价很小。
                var l = 2
                while l < p.count {
                    best = exactInto(
                        raw, best, UnsafeBufferPointer(rebasing: p[0..<l]), p.count, limit, freq,
                        maxFreqBoost: maxFreqBoost, now: now, afterDigit: afterDigit)
                    l += 2
                }
                // 整个缓冲：前缀匹配，含还没打完的长词。
                return prefixInto(
                    raw, best, p, limit, freq,
                    maxFreqBoost: maxFreqBoost, now: now, afterDigit: afterDigit)
            }
        }
    }

    func prefixInto(
        _ raw: UnsafeRawBufferPointer, _ best: [Candidate],
        _ prefix: UnsafeBufferPointer<UInt8>, _ limit: Int, _ f: Freq?,
        maxFreqBoost: Int64, now: TimeInterval,
        afterDigit: Bool = false
    ) -> [Candidate] {
        var best = best
        var scanned = 0
        var i = lowerBound(raw, prefix)
        while i < n && scanned < maxScan {
            guard codeHasPrefix(raw, i, prefix) else { break }
            scanned += 1
            let codeLen = codeRange(raw, i).length
            best = offer(
                raw, best, i, codeLen,
                lookupScore(weight(raw, i), codeLen, prefix.count), prefix.count, limit, f,
                maxFreqBoost: maxFreqBoost, now: now, afterDigit: afterDigit)
            i += 1
        }
        return best
    }

    func exactInto(
        _ raw: UnsafeRawBufferPointer, _ best: [Candidate],
        _ code: UnsafeBufferPointer<UInt8>, _ bufLen: Int, _ limit: Int, _ f: Freq?,
        maxFreqBoost: Int64, now: TimeInterval,
        afterDigit: Bool = false
    ) -> [Candidate] {
        var best = best
        var i = lowerBound(raw, code)
        while i < n {
            guard codeEquals(raw, i, code) else { break }
            best = offer(
                raw, best, i, code.count,
                lookupScore(weight(raw, i), code.count, bufLen), bufLen, limit, f,
                maxFreqBoost: maxFreqBoost, now: now, afterDigit: afterDigit)
            i += 1
        }
        return best
    }

    /// 把第 i 条以基础分 base 合进 best。前缀扫描一次要看上万条，绝大多数
    /// 进不了前 limit 个：先用词频加权的上限判断，再查实际词频，都过了才
    /// 复制词条文本，省掉热路径上的绝大部分分配。
    func offer(
        _ raw: UnsafeRawBufferPointer, _ best: [Candidate], _ i: Int, _ codeLen: Int,
        _ base: Int64, _ bufLen: Int, _ limit: Int, _ f: Freq?,
        maxFreqBoost: Int64, now: TimeInterval,
        afterDigit: Bool = false
    ) -> [Candidate] {
        let extraCeiling: Int64 = afterDigit && codeLen == 2 ? classifierBoost : 0
        if !admits(best, limit, base + maxFreqBoost + extraCeiling, codeLen) {
            return best
        }
        let (off, len) = textRange(raw, i)
        let runes = runeCount(raw, off, len)
        // 辅码单字是「单字加部首码」，不是词。无论是三键前缀还是四键撞码，
        // 都不应按单字词频压过真实词组，统一放到 tierAux（高于普通两键短匹配）；
        // 若已打超它的编码长度（tierShort），也保持在常规权重，不抢短词的字节长度加成。
        let aux = codeLen > 2 && runes == 1
        let adjusted: Int64
        if aux {
            let auxTier = codeLen >= bufLen ? Int64(tierAux) : Int64(tierShort)
            adjusted = auxTier << 40 | Int64(weight(raw, i))
        } else {
            adjusted = base
        }
        let canBeClassifier = afterDigit && codeLen == 2 && runes == 1
        if !admits(best, limit, adjusted + maxFreqBoost + (canBeClassifier ? classifierBoost : 0), codeLen) {
            return best
        }
        let text = decode(raw, off, len)
        let digitBonus: Int64 = (canBeClassifier && classifiers.contains(text))
            ? classifierBoost : 0
        if maxFreqBoost == 0 {
            let score = adjusted + digitBonus
            if !admits(best, limit, score, codeLen) {
                return best
            }
            let (codeOff, _) = codeRange(raw, i)
            return insertCandidate(
                best, Candidate(text, codeLen, score, code: decode(raw, codeOff, codeLen)), limit)
        }
        let (codeOff, _) = codeRange(raw, i)
        let codeStr = decode(raw, codeOff, codeLen)
        let score = adjusted + digitBonus + (f?.boost(text, code: codeStr, now: now) ?? 0)
        if !admits(best, limit, score, codeLen) {
            return best
        }
        return insertCandidate(best, Candidate(text, codeLen, score, code: codeStr), limit)
    }

    /// 返回某个字母开头的最高频词，用于单键输入（比如 l 打「了」）。
    public func short(_ letter: UInt8, _ f: Freq?, afterDigit: Bool = false) -> [Candidate] {
        guard shortCount > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            var out: [Candidate] = []
            let base = headerSize + n * recordSize
            var i = 0
            while i < shortCount {
                let r = base + i * recordSize
                let codeLen = Int(raw[r + 12])
                if codeLen >= 2, raw[blobStart + Int(readU32(raw, r))] == letter {
                    let codeOff = blobStart + Int(readU32(raw, r))
                    let codeStr = decode(raw, codeOff, codeLen)
                    let textOff = blobStart + Int(readU32(raw, r + 4))
                    let textLen = Int(raw[r + 13])
                    let text = decode(raw, textOff, textLen)
                    let digitBonus: Int64 = (afterDigit && classifiers.contains(text))
                        ? classifierBoost : 0
                    out.append(
                        Candidate(
                            text, codeLen,
                            candidateScore(readU32(raw, r + 8), codeLen, 1)
                                + digitBonus
                                + (f?.boost(text, code: codeStr) ?? 0),
                            code: codeStr))
                }
                i += 1
            }
            return out
        }
    }

    /// 二分查静态二元搭配权重。零分配。
    func bigramWeight(_ raw: UnsafeRawBufferPointer, _ left: String, _ right: String) -> UInt32 {
        guard bigramCount > 0, !left.isEmpty, !right.isEmpty else { return 0 }
        let target = bigramHash(left, right)
        var lo = 0
        var hi = bigramCount
        while lo < hi {
            let mid = (lo + hi) >> 1
            let h = readU64(raw, bigramStart + mid * bigramRecordSize)
            if h < target {
                lo = mid + 1
            } else if h > target {
                hi = mid
            } else {
                return readU32(raw, bigramStart + mid * bigramRecordSize + 8)
            }
        }
        return 0
    }

    func staticBigramBoost(_ raw: UnsafeRawBufferPointer, _ left: String?, _ right: String) -> Double {
        guard let left, !left.isEmpty else { return 0 }
        let w = bigramWeight(raw, left, right)
        guard w > 0 else { return 0 }
        return composeStaticBigramBoost * min(1.0, log(Double(w) + 1) / log(500_000.0))
    }

    /// 一个词条是不是单字辅码。词编码每个音节两键，单字只有两键编码；
    /// 更长的单字编码都是辅码，不能当词组参与组句。
    @inline(__always)
    func isAuxEntry(_ raw: UnsafeRawBufferPointer, _ i: Int) -> Bool {
        guard codeRange(raw, i).length > 2 else { return false }
        let (off, len) = textRange(raw, i)
        return runeCount(raw, off, len) == 1
    }

    /// 编码恰好等于 code 的真实词最高权重。辅码单字不算词。
    func exactWeight(
        _ raw: UnsafeRawBufferPointer, _ code: UnsafeBufferPointer<UInt8>
    ) -> (UInt32, Bool) {
        var i = lowerBound(raw, code)
        while i < n {
            guard codeEquals(raw, i, code) else { break }
            if !isAuxEntry(raw, i) {
                return (weight(raw, i), true)
            }
            i += 1
        }
        return (0, false)
    }

    func exactWeight(_ raw: UnsafeRawBufferPointer, _ code: [UInt8]) -> (UInt32, Bool) {
        code.withUnsafeBufferPointer { exactWeight(raw, $0) }
    }

    /// 词库里是否已存在编码恰好等于 code、文本等于 text 的真实词条目。
    func containsExact(_ code: [UInt8], _ text: String) -> Bool {
        guard n > 0 else { return false }
        return data.withUnsafeBytes { raw in
            code.withUnsafeBufferPointer { p in
                var i = lowerBound(raw, p)
                while i < n {
                    guard codeEquals(raw, i, p) else { break }
                    if !isAuxEntry(raw, i) {
                        let (off, len) = textRange(raw, i)
                        if decode(raw, off, len) == text { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }

    /// 编码恰好等于 code 的前 n 种真实词写法，权重从高到低。
    func exactAlts(_ raw: UnsafeRawBufferPointer, _ code: [UInt8], _ limit: Int) -> [AltText] {
        code.withUnsafeBufferPointer { p in
            var out: [AltText] = []
            var i = lowerBound(raw, p)
            while i < self.n && out.count < limit {
                guard codeEquals(raw, i, p) else { break }
                if !isAuxEntry(raw, i) {
                    let (off, len) = textRange(raw, i)
                    out.append(AltText(text: decode(raw, off, len), weight: weight(raw, i)))
                }
                i += 1
            }
            return out
        }
    }
}

/// 把整个缓冲切成若干词，返回若干种拼法（最优的一种加上逐段换同音词的变体）。
public extension Dict {
    func compose(_ buf: [UInt8], limit: Int, freq: Freq?) -> [Candidate] {
        guard buf.count >= 4, n > 0, limit > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            buf.withUnsafeBufferPointer { p in
                composeRaw(raw, p, limit, freq)
            }
        }
    }
}

extension Dict {
    func composeRaw(
        _ raw: UnsafeRawBufferPointer, _ p: UnsafeBufferPointer<UInt8>,
        _ limit: Int, _ freq: Freq?
    ) -> [Candidate] {
        let odd = p.count % 2 == 1
        let syls = p.count / 2
        let total = odd ? syls + 1 : syls
        struct BeamState {
            var score: Double
            var prevIdx: Int
            var prevBeam: Int
            var segs: Int
            var alt: AltText
            var code: String
            var lastChar: String
            var prevLastChar: String?
            var prevWord: String?
            var lastFinal: UInt8
        }
        var beams = [[BeamState]](repeating: [], count: total + 1)
        let activeCtx = freq?.activeContext()
        let initialCtx = (activeCtx?.isEmpty ?? true) ? nil : activeCtx
        beams[0] = [
            BeamState(
                score: 0, prevIdx: -1, prevBeam: -1, segs: 0,
                alt: AltText(text: "", weight: 0), code: "",
                lastChar: "", prevLastChar: nil, prevWord: nil, lastFinal: 0)
        ]

        let scanPerEdge = (freq == nil && bigramCount == 0) ? 1 : altPerSegment

        func insertBeam(_ to: Int, _ candidate: BeamState) {
            var list = beams[to]
            if let sameIdx = list.firstIndex(where: { $0.alt.text == candidate.alt.text }) {
                if candidate.score > list[sameIdx].score {
                    list[sameIdx] = candidate
                    list.sort { $0.score > $1.score }
                    beams[to] = list
                }
                return
            }
            list.append(candidate)
            list.sort { $0.score > $1.score }
            if list.count > composeBeamWidth {
                list.removeLast()
            }
            beams[to] = list
        }

        func edge(_ from: Int, _ to: Int, _ code: [UInt8], _ final: UInt8?) {
            guard !beams[from].isEmpty else { return }
            let alts = exactAlts(raw, code, scanPerEdge)
            guard !alts.isEmpty else { return }
            let codeStr = String(decoding: code, as: UTF8.self)
            let charPenalty = (to - from == 1) ? singleCharPenalty : 0.0
            for (bIdx, prevState) in beams[from].enumerated() {
                let previousLast = from == 0 ? initialCtx : prevState.lastChar
                let previousWord = from == 0 ? nil : prevState.alt.text
                var winner: AltText?
                var bestGain = -Double.infinity
                for alt in alts {
                    let g = log(Double(alt.weight) + 1)
                        + (freq?.wordLogBoost(alt.text, code: codeStr) ?? 0)
                        + (freq?.segmentBoost(previousLast, alt.text) ?? 0)
                        + staticBigramBoost(raw, previousWord, alt.text)
                    if g > bestGain {
                        bestGain = g
                        winner = alt
                    }
                }
                guard let picked = winner else { continue }
                let nextScore = prevState.score + bestGain - segmentPenalty - charPenalty
                // 如果只看末词去重，保留一条第二高分路径以便后续静态搭配反超。
                let nextState = BeamState(
                    score: nextScore,
                    prevIdx: from,
                    prevBeam: bIdx,
                    segs: prevState.segs + 1,
                    alt: picked,
                    code: codeStr,
                    lastChar: picked.text.last.map(String.init) ?? "",
                    prevLastChar: previousLast,
                    prevWord: previousWord,
                    lastFinal: final ?? 0)
                insertBeam(to, nextState)
                // 若有第二个不同写法且分差不远，也尝试保留到 beam 中供后续二元搭配竞争。
                if beams[to].count < composeBeamWidth && alts.count > 1 && bigramCount > 0 {
                    var runnerUp: AltText?
                    var runnerGain = -Double.infinity
                    for alt in alts where alt.text != picked.text {
                        let g = log(Double(alt.weight) + 1)
                            + (freq?.wordLogBoost(alt.text, code: codeStr) ?? 0)
                            + (freq?.segmentBoost(previousLast, alt.text) ?? 0)
                            + staticBigramBoost(raw, previousWord, alt.text)
                        if g > runnerGain {
                            runnerGain = g
                            runnerUp = alt
                        }
                    }
                    if let second = runnerUp {
                        insertBeam(
                            to,
                            BeamState(
                                score: prevState.score + runnerGain - segmentPenalty - charPenalty,
                                prevIdx: from,
                                prevBeam: bIdx,
                                segs: prevState.segs + 1,
                                alt: second,
                                code: codeStr,
                                lastChar: second.text.last.map(String.init) ?? "",
                                prevLastChar: previousLast,
                                prevWord: previousWord,
                                lastFinal: final ?? 0))
                    }
                }
            }
        }

        for i in 0..<syls {
            if beams[i].isEmpty { continue }
            var j = i + 1
            while j <= syls && j - i <= maxWordSyllables {
                edge(i, j, Array(p[(i * 2)..<(j * 2)]), nil)
                j += 1
            }
        }

        // 末尾那个声母音节：词跨 [i,total) 的编码是 buf[i*2:] 再补一个韵母键。
        if odd {
            let from = max(0, total - maxWordSyllables)
            if from <= syls {
                for i in from...syls {
                    if beams[i].isEmpty { continue }
                    var code = Array(p[(i * 2)..<p.count])
                    for f in UInt8(ascii: "a")...UInt8(ascii: "z") {
                        code.append(f)
                        edge(i, total, code, f)
                        code.removeLast()
                    }
                }
            }
        }
        guard let winnerState = beams[total].first(where: { $0.segs >= 2 }) else { return [] }
        guard let winnerBeamIdx = beams[total].firstIndex(where: {
            $0.segs == winnerState.segs && $0.alt.text == winnerState.alt.text
        }) else { return [] }

        // 回溯出每段选中的状态。
        var pathStates: [BeamState] = []
        pathStates.reserveCapacity(winnerState.segs)
        var curIdx = total
        var curBeam = winnerBeamIdx
        while curIdx > 0 {
            let st = beams[curIdx][curBeam]
            pathStates.append(st)
            curIdx = st.prevIdx
            curBeam = st.prevBeam
        }
        pathStates.reverse()

        // 每段的同音备选：普通段直接取 buf 切片；末尾声母段要补上选中的韵母键。
        // 前面各段只用 DP 已选定的最优写法；只为最后一段拉取并重排更多同音备选。
        let lastIdx = pathStates.count - 1
        let lastState = pathStates[lastIdx]
        let lastCode = Array(lastState.code.utf8)
        let rawLastAlts = exactAlts(raw, lastCode, lastSegmentScan)
        if rawLastAlts.isEmpty { return [] }
        func lastSegScore(_ x: AltText) -> Double {
            log(Double(x.weight) + 1)
                + (freq?.wordLogBoost(x.text, code: lastState.code, maxBoost: composeLastFreqBoost) ?? 0)
                + (freq?.segmentBoost(lastState.prevLastChar, x.text) ?? 0)
                + staticBigramBoost(raw, lastState.prevWord, x.text)
        }
        let rankedLast = rawLastAlts.sorted { x, y in
            let sx = lastSegScore(x)
            let sy = lastSegScore(y)
            if sx != sy { return sx > sy }
            return x.weight > y.weight
        }
        var lastAlts = Array(rankedLast.prefix(lastSegmentAlts))
        if !lastAlts.contains(where: { $0.text == lastState.alt.text }) {
            lastAlts.insert(lastState.alt, at: 0)
            if lastAlts.count > lastSegmentAlts { lastAlts.removeLast() }
        }
        let mainLast = lastAlts[0]
        let mainLastScore = lastSegScore(mainLast)
        let basePrefixScore = winnerState.score - lastSegScore(lastState.alt)
            + (freq?.wordLogBoost(lastState.alt.text, code: lastState.code) ?? 0)
            + (freq?.segmentBoost(lastState.prevLastChar, lastState.alt.text) ?? 0)
            + staticBigramBoost(raw, lastState.prevWord, lastState.alt.text)
        // 用实际整条路径分（保持末段按 lastSegScore 的排序不变）。
        let prefixOnlyScore = winnerState.score - (
            log(Double(lastState.alt.weight) + 1)
            + (freq?.wordLogBoost(lastState.alt.text, code: lastState.code) ?? 0)
            + (freq?.segmentBoost(lastState.prevLastChar, lastState.alt.text) ?? 0)
            + staticBigramBoost(raw, lastState.prevWord, lastState.alt.text)
        )
        _ = basePrefixScore

        let bufCode = String(decoding: p, as: UTF8.self)
        var out: [Candidate] = []
        func emit(_ alt: AltText, isVariant: Bool) {
            var bytes: [UInt8] = []
            for k in 0..<lastIdx {
                bytes.append(contentsOf: pathStates[k].alt.text.utf8)
            }
            bytes.append(contentsOf: alt.text.utf8)
            let totalLog = prefixOnlyScore + lastSegScore(alt) + segmentPenalty
            // 换字副本比主拼法轻一档：段内选择已经在 DP 里按词频和接续定好，
            // 副本只作为可选的次选，不另造一条同分段句子。
            let variant = isVariant ? composeVariantPenalty : 0.0
            let logScore = totalLog - variant
            let w = (logScore + composeScoreOffset) * composeScoreScale
            let text = String(decoding: bytes, as: UTF8.self)
            let score = (Int64(tierCompose) << 40 | Int64(clampWeight(w)))
                + (freq?.boost(text, code: bufCode) ?? 0)
            out = insertCandidate(out, Candidate(text, p.count, score, code: bufCode), limit)
        }
        _ = mainLastScore
        emit(mainLast, isVariant: false)
        // 只为最后一段出同音备选：前面的段换字会一口气刷出整屏同义副本，
        // 把「这个」「输入法」这些真正可选的短词挤到后面。末尾段是用户
        // 正在敲的那一截，换字最可能是想要的，也最不影响已稳定的前文。
        for alt in lastAlts.dropFirst() {
            emit(alt, isVariant: true)
        }
        return out
    }
}

func clampWeight(_ w: Double) -> UInt32 {
    if w <= 0 { return 0 }
    if w > Double(UInt32.max) { return UInt32.max }
    return UInt32(w)
}

/// a 是否该排在 b 前面：先看分数，同分时编码短的更具体。
@inline(__always)
func better(_ a: Candidate, _ b: Candidate) -> Bool {
    if a.score != b.score {
        return a.score > b.score
    }
    return a.codeLen < b.codeLen
}

/// 分数 score、编码长 codeLen 的候选能否进入按 better 排好、最多 limit 个的 best。
@inline(__always)
func admits(_ best: [Candidate], _ limit: Int, _ score: Int64, _ codeLen: Int) -> Bool {
    if best.count < limit { return true }
    guard let last = best.last else { return true }
    return score > last.score || (score == last.score && codeLen < last.codeLen)
}

/// 把 c 插入按分数降序排列的列表，保持长度不超过 limit，并按文本去重。
func insertCandidate(_ best: [Candidate], _ c: Candidate, _ limit: Int) -> [Candidate] {
    var best = best
    for b in best where b.text == c.text {
        if b.score >= c.score { return best }
        break
    }
    var pos = best.count
    for (i, b) in best.enumerated() where better(c, b) {
        pos = i
        break
    }
    if pos >= limit { return best }
    best.insert(c, at: pos)
    if best.count > limit {
        best.removeLast()
    }
    // 去重：插入后可能和后面的同名词重复
    var i = pos + 1
    while i < best.count {
        if best[i].text == c.text {
            best.remove(at: i)
            break
        }
        i += 1
    }
    return best
}

// 一级简码是自然码传统的一键简码，单键输入时排在最前。
// 光靠词频定不出来：词库里「了」的字频权重只有 349 万，「来」有 1483 万。
let singleKey: [UInt8: String] = [
    UInt8(ascii: "q"): "请", UInt8(ascii: "w"): "我", UInt8(ascii: "e"): "而",
    UInt8(ascii: "r"): "人", UInt8(ascii: "t"): "他", UInt8(ascii: "y"): "一",
    UInt8(ascii: "u"): "是", UInt8(ascii: "i"): "出", UInt8(ascii: "o"): "欧",
    UInt8(ascii: "p"): "片", UInt8(ascii: "a"): "按", UInt8(ascii: "s"): "三",
    UInt8(ascii: "d"): "的", UInt8(ascii: "f"): "分", UInt8(ascii: "g"): "个",
    UInt8(ascii: "h"): "和", UInt8(ascii: "j"): "就", UInt8(ascii: "k"): "可",
    UInt8(ascii: "l"): "了", UInt8(ascii: "z"): "在", UInt8(ascii: "x"): "小",
    UInt8(ascii: "c"): "才", UInt8(ascii: "v"): "这", UInt8(ascii: "b"): "不",
    UInt8(ascii: "n"): "你", UInt8(ascii: "m"): "们",
]

/// 单键候选的起始权重，只用于定序，不代表真实词频。
let shortBaseWeight: UInt32 = 2_000_000_000

/// 算出每个字母的单键候选，按字母分组。每条给一个递减的合成权重，
/// 让存储顺序就是显示顺序。
func shortLists(_ entries: [Entry]) -> [Entry] {
    var per = [[Entry]](repeating: [], count: 26)
    var curated = [Entry?](repeating: nil, count: 26)
    for e in entries {
        let code = Array(e.code.utf8)
        // 单键候选只从两键单字里选，别把三、四码的辅码条目也算进来。
        guard code.count == 2, code[0] >= UInt8(ascii: "a"), code[0] <= UInt8(ascii: "z")
        else { continue }
        // 单键只给单字，避免「版权」「三国群英传」这类高频长词混进来。
        guard e.text.unicodeScalars.count == 1 else { continue }
        let i = Int(code[0] - UInt8(ascii: "a"))
        if let want = singleKey[code[0]], e.text == want, curated[i] == nil {
            curated[i] = e
        }
        var list = per[i]
        var pos = list.count
        for (j, x) in list.enumerated() where e.weight > x.weight {
            pos = j
            break
        }
        if pos >= maxCandidates { continue }
        list.insert(e, at: pos)
        if list.count > maxCandidates {
            list.removeLast()
        }
        per[i] = list
    }

    var out: [Entry] = []
    for i in 0..<26 {
        var list = per[i]
        if let c = curated[i] {
            // 把约定的简码提到最前，其余顺延。
            list.removeAll { $0.text == c.text }
            list.insert(c, at: 0)
            if list.count > maxCandidates {
                list.removeLast(list.count - maxCandidates)
            }
        }
        for (rank, e) in list.enumerated() {
            var e = e
            e.weight = shortBaseWeight - UInt32(rank) * 1_000_000
            out.append(e)
        }
    }
    return out
}

/// 把 entries 写成词表格式。写之前按 Code 升序、同 Code 按 Weight 降序排好，
/// 二分查找依赖这个顺序。同编码同权重再按词条字节序排，同一份输入每次生成的
/// 文件都一样，不随调用方的字典遍历顺序变化。
public func writeDict(_ entries: [Entry]) -> Data {
    writeDict(entries, bigrams: [])
}

/// 把 entries 和可选的静态二元搭配表写成词表格式。写之前按 Code 升序、同 Code 按
/// Weight 降序排好，二分查找依赖这个顺序。同编码同权重再按词条字节序排，同一份
/// 输入每次生成的文件都一样，不随调用方的字典遍历顺序变化。
public func writeDict(_ entries: [Entry], bigrams: [BigramEntry]) -> Data {
    let sorted = entries.sorted { a, b in
        if a.code != b.code {
            return a.code.utf8.lexicographicallyPrecedes(b.code.utf8)
        }
        if a.weight != b.weight {
            return a.weight > b.weight
        }
        return a.text.utf8.lexicographicallyPrecedes(b.text.utf8)
    }
    let shorts = shortLists(sorted)
    let all = sorted + shorts
    var sortedBigrams: [BigramEntry] = []
    if !bigrams.isEmpty {
        let byHash = bigrams.sorted { $0.hash < $1.hash }
        sortedBigrams.reserveCapacity(byHash.count)
        for b in byHash {
            if let last = sortedBigrams.last, last.hash == b.hash {
                if b.weight > last.weight {
                    sortedBigrams[sortedBigrams.count - 1].weight = b.weight
                }
            } else {
                sortedBigrams.append(b)
            }
        }
    }

    var blob: [UInt8] = []
    blob.reserveCapacity(all.reduce(0) { $0 + $1.code.utf8.count + $1.text.utf8.count })
    var recs: [UInt8] = []
    recs.reserveCapacity(all.count * recordSize)
    for e in all {
        let codeOff = blob.count
        blob.append(contentsOf: e.code.utf8)
        let textOff = blob.count
        blob.append(contentsOf: e.text.utf8)
        var r = [UInt8](repeating: 0, count: recordSize)
        writeU32(&r, 0, UInt32(codeOff))
        writeU32(&r, 4, UInt32(textOff))
        writeU32(&r, 8, e.weight)
        r[12] = UInt8(truncatingIfNeeded: e.code.utf8.count)
        r[13] = UInt8(truncatingIfNeeded: e.text.utf8.count)
        recs.append(contentsOf: r)
    }

    var bigramBytes: [UInt8] = []
    if !sortedBigrams.isEmpty {
        bigramBytes.reserveCapacity(sortedBigrams.count * bigramRecordSize)
        for b in sortedBigrams {
            var r = [UInt8](repeating: 0, count: bigramRecordSize)
            writeU64(&r, 0, b.hash)
            writeU32(&r, 8, b.weight)
            bigramBytes.append(contentsOf: r)
        }
    }

    var head = [UInt8](repeating: 0, count: headerSize)
    for (i, b) in dictMagicBytes.enumerated() {
        head[i] = b
    }
    writeU32(&head, 8, UInt32(sorted.count))
    writeU32(&head, 12, UInt32(blob.count))
    writeU32(&head, 16, UInt32(shorts.count))
    writeU32(&head, 20, UInt32(sortedBigrams.count))
    return Data(head + recs + blob + bigramBytes)
}
