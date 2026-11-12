import Foundation

/// 独立英文词表二进制格式（小端）：
///
///     [0:6]   magic "WSENG1"
///     [6:8]   保留
///     [8:12]  词条数 n
///     [12:16] 字符串区长度
///     [16:20] 保留
///     之后 n×16 记录，最后是小写编码和显示词形的字符串区。
///
/// 记录按小写编码升序、同编码按权重降序、同权重按词形字节序排好，
/// 前缀查询和主词表一样是二分定位。英文词表独立于 dict.bin：两者编码空间
/// 不同（一个是双拼，一个是字母串），混在一张表里会污染组句和辅码判断。
let englishMagicBytes = Array("WSENG1".utf8)
let englishHeaderSize = 20
let englishRecordSize = 16
let englishMaxScan = 2000

/// 一次英文前缀查询最多给出的候选数。中文候选仍占首页前几位。
let englishMaxCandidates = 5
/// 精确命中整串的英文词从 2 个字母起就给（api、app 这类短词）。
let englishMinExact = 2
/// 只匹配到前缀的补全词要 5 个字母以上才给，避免打两个键就刷出整屏英文。
let englishMinPrefix = 5

/// 英文词表查不到时的兜底候选：把预编辑原文作为一条可选项上屏。
public struct EnglishFallback: Equatable, Sendable {
    public var text: String
}

public enum EnglishDictError: Error, CustomStringConvertible {
    case badHeader
    case truncated

    public var description: String {
        switch self {
        case .badHeader: return "english: 文件头不对"
        case .truncated: return "english: 文件被截断"
        }
    }
}

/// 英文词典里的一条记录。小写编码用来查，display 保留词库里的大小写形态。
public struct EnglishEntry: Equatable, Sendable {
    public var code: String
    public var display: String
    public var weight: UInt32

    public init(code: String, display: String, weight: UInt32) {
        self.code = code
        self.display = display
        self.weight = weight
    }
}

/// 映射到内存的英文词表，只读。运行时不做词形变化，大小写推导在规则层完成。
public struct EnglishDict: Sendable {
    let data: Data
    let n: Int
    let blobStart: Int

    public init(data: Data) throws {
        guard data.count >= englishHeaderSize,
              data.prefix(englishMagicBytes.count).elementsEqual(englishMagicBytes)
        else {
            throw EnglishDictError.badHeader
        }
        let n = Int(readU32(data, 8))
        let blobLen = Int(readU32(data, 12))
        let end = englishHeaderSize + n * englishRecordSize
        guard end <= data.count, end + blobLen <= data.count else {
            throw EnglishDictError.truncated
        }
        self.data = data
        self.n = n
        self.blobStart = end
    }

    public var count: Int { n }
}

extension EnglishDict {
    @inline(__always)
    func codeRange(_ raw: UnsafeRawBufferPointer, _ i: Int) -> (offset: Int, length: Int) {
        let r = englishHeaderSize + i * englishRecordSize
        return (blobStart + Int(readU32(raw, r)), Int(raw[r + 12]))
    }

    @inline(__always)
    func displayRange(_ raw: UnsafeRawBufferPointer, _ i: Int) -> (offset: Int, length: Int) {
        let r = englishHeaderSize + i * englishRecordSize
        return (blobStart + Int(readU32(raw, r + 4)), Int(raw[r + 13]))
    }

    @inline(__always)
    func weight(_ raw: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
        readU32(raw, englishHeaderSize + i * englishRecordSize + 8)
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
            if order == 0 { order = len < prefix.count ? -1 : (len == prefix.count ? 0 : 1) }
            if order < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    @inline(__always)
    func codeHasPrefix(
        _ raw: UnsafeRawBufferPointer, _ i: Int, _ prefix: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        let (off, len) = codeRange(raw, i)
        guard len >= prefix.count else { return false }
        for k in 0..<prefix.count where raw[off + k] != prefix[k] { return false }
        return true
    }

    /// 按小写前缀查词，返回 (显示词形, 是否精确等于前缀, 权重)。
    /// 精确命中和按权重最高的前缀词分开返回，调用方据此决定插入位次。
    public func lookup(_ prefix: [UInt8], exactOnly: Bool, limit: Int) -> [EnglishMatch] {
        guard limit > 0, n > 0, !prefix.isEmpty else { return [] }
        return data.withUnsafeBytes { raw in
            prefix.withUnsafeBufferPointer { p in
                var out: [EnglishMatch] = []
                var i = lowerBound(raw, p)
                var scanned = 0
                while i < n && scanned < englishMaxScan {
                    guard codeHasPrefix(raw, i, p) else { break }
                    scanned += 1
                    let (_, len) = codeRange(raw, i)
                    let exact = len == p.count
                    if !exactOnly || exact {
                        let (doff, dlen) = displayRange(raw, i)
                        out.append(EnglishMatch(
                            display: decode(raw, doff, dlen), exact: exact,
                            weight: weight(raw, i)))
                    }
                    i += 1
                    if out.count >= limit && !exactOnly { break }
                    if exactOnly && exact && out.count >= limit { break }
                }
                // 前缀按权重排序：词库文件顺序只保证编码升序，同前缀内部要重排。
                out.sort { a, b in
                    if a.exact != b.exact { return a.exact }
                    if a.weight != b.weight { return a.weight > b.weight }
                    return a.display.utf8.lexicographicallyPrecedes(b.display.utf8)
                }
                return out
            }
        }
    }
}

/// 一条英文查询结果。
public struct EnglishMatch: Equatable, Sendable {
    public var display: String
    public var exact: Bool
    public var weight: UInt32
}

/// 把英文词条写成二进制。同一小写编码同一词形只留一份，取较高权重。
public func writeEnglishDict(_ entries: [EnglishEntry]) -> Data {
    var best: [String: EnglishEntry] = [:]
    for e in entries {
        let key = e.code + "\u{0}" + e.display
        if let old = best[key] {
            if e.weight > old.weight { best[key] = e }
        } else {
            best[key] = e
        }
    }
    let sorted = best.values.sorted { a, b in
        if a.code != b.code {
            return a.code.utf8.lexicographicallyPrecedes(b.code.utf8)
        }
        if a.weight != b.weight { return a.weight > b.weight }
        return a.display.utf8.lexicographicallyPrecedes(b.display.utf8)
    }

    var blob: [UInt8] = []
    blob.reserveCapacity(sorted.reduce(0) { $0 + $1.code.utf8.count + $1.display.utf8.count })
    var recs: [UInt8] = []
    recs.reserveCapacity(sorted.count * englishRecordSize)
    for e in sorted {
        let codeOff = blob.count
        blob.append(contentsOf: e.code.utf8)
        let displayOff = blob.count
        blob.append(contentsOf: e.display.utf8)
        var r = [UInt8](repeating: 0, count: englishRecordSize)
        writeU32(&r, 0, UInt32(codeOff))
        writeU32(&r, 4, UInt32(displayOff))
        // 低 24 位存权重，高 8 位空出来留作记录长度区。
        writeU32(&r, 8, e.weight)
        r[12] = UInt8(truncatingIfNeeded: e.code.utf8.count)
        r[13] = UInt8(truncatingIfNeeded: e.display.utf8.count)
        recs.append(contentsOf: r)
    }

    var head = [UInt8](repeating: 0, count: englishHeaderSize)
    for (i, b) in englishMagicBytes.enumerated() { head[i] = b }
    writeU32(&head, 8, UInt32(sorted.count))
    writeU32(&head, 12, UInt32(blob.count))
    return Data(head + recs + blob)
}
