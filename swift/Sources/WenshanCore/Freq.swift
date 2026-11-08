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

/// 记录用户实际选过的词，以及「上一个上屏词的末字 → 这个词」的接续，
/// 用来把常用的词和接在它后面的词往前排。只在主线程访问，不加锁。
public final class Freq {
    var counts: [String: UInt32]
    /// 键是「上一个上屏词的末字 \t 当前词」。
    var pairs: [String: UInt32]
    /// 最近一次上屏词的末字，作为下一次候选的上下文。
    var context: String
    var dirty: Int
    let path: String
    /// 上次读入或写出时文件的修改时间，用来发现别的进程改过它。
    var diskStamp: Date?

    public init(
        counts: [String: UInt32] = [:], pairs: [String: UInt32] = [:], path: String = ""
    ) {
        self.counts = counts
        self.pairs = pairs
        self.context = ""
        self.dirty = 0
        self.path = path
    }

    /// 读取词频文件。两列是「词<TAB>次数」，三列是「上文末字<TAB>词<TAB>次数」。
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
                guard !parts[0].isEmpty else { continue }
                f.counts[String(parts[0])] = n
            } else {
                // 三列是二元接续：上文只可能是一个字，多字的是坏行。
                guard !parts[0].isEmpty, parts[0].unicodeScalars.count == 1,
                      !parts[1].isEmpty
                else { continue }
                f.pairs[String(parts[0]) + "\t" + String(parts[1])] = n
            }
        }
        return f
    }

    /// 某个词被选过多少次。
    public func count(_ text: String) -> UInt32 { counts[text] ?? 0 }

    /// 记一次选词：累计词频，并记下它接在上一个词后面的次数。
    /// 上下文取末字而不是整词：整句上屏后也能接着用，词对也更稠密。
    public func bump(_ text: String) {
        guard !text.isEmpty else { return }
        counts[text, default: 0] += 1
        if !context.isEmpty {
            let key = context + "\t" + text
            pairs[key, default: 0] += 1
        }
        if let last = text.last { context = String(last) }
        dirty += 1
    }

    /// 未落盘的选词是否攒够了 saveEvery 次。
    func due() -> Bool { dirty >= saveEvery }

    /// 把词频和二元接续写回磁盘，都按次数从多到少排列，超过上限的淘汰掉。
    public func save() throws {
        guard dirty > 0 else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let texts = cappedKeys(&counts, maxFreqEntries)
        let keys = cappedKeys(&pairs, maxPairEntries)
        var out = ""
        out.reserveCapacity((texts.count + keys.count) * 12)
        for text in texts {
            out += "\(text)\t\(counts[text] ?? 0)\n"
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
    func boost(_ text: String) -> Int64 {
        freqBoost(counts[text] ?? 0) + pairBoost(text)
    }

    /// 直接用词表里的字节查表，省掉调用方先拼字符串。
    func boost(_ raw: UnsafeRawBufferPointer, _ off: Int, _ len: Int) -> Int64 {
        boost(String(decoding: raw[off..<(off + len)], as: UTF8.self))
    }

    func pairBoost(_ text: String) -> Int64 {
        guard !context.isEmpty else { return 0 }
        return Int64(min(pairs[context + "\t" + text] ?? 0, maxPairCount)) * boostPerPair
    }

    /// 任何词能拿到的最大加权，用来在查表前先排除进不了候选的词。
    var maxBoost: Int64 {
        Int64(maxBoostCount) * boostPerPick + Int64(maxPairCount) * boostPerPair
    }
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
