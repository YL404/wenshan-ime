import Foundation

/// 攒够多少次选词才落盘。写在按键路径上，所以频率要低。
let saveEvery = 50

/// 词频表最多保留的词数。超出时写盘前淘汰选得最少的词。
let maxFreqEntries = 20_000

let maxBoostCount: UInt32 = 50
let boostPerPick: Int64 = 1_000_000

/// 记录用户实际选过的词，用来把常用的词往前排。只在主线程访问，不加锁。
public final class Freq {
    var counts: [String: UInt32]
    var dirty: Int
    let path: String
    /// 上次读入或写出时文件的修改时间，用来发现别的进程改过它。
    var diskStamp: Date?

    public init(counts: [String: UInt32] = [:], path: String = "") {
        self.counts = counts
        self.dirty = 0
        self.path = path
    }

    /// 读取词频文件。文件不存在或读不动时返回空表，不影响输入。
    public static func load(_ path: String) -> Freq {
        let f = Freq(path: path)
        f.diskStamp = fileStamp(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return f }
        for line in textLines(String(decoding: data, as: UTF8.self)) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let digits = parts[1]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let n = UInt32(digits)
            else { continue }
            f.counts[String(parts[0])] = n
        }
        return f
    }

    /// 某个词被选过多少次。
    public func count(_ text: String) -> UInt32 { counts[text] ?? 0 }

    /// 记一次选词。
    public func bump(_ text: String) {
        guard !text.isEmpty else { return }
        counts[text, default: 0] += 1
        dirty += 1
    }

    /// 未落盘的选词是否攒够了 saveEvery 次。
    func due() -> Bool { dirty >= saveEvery }

    /// 把词频写回磁盘，按次数从多到少排列，超过 maxFreqEntries 的部分淘汰掉。
    public func save() throws {
        guard dirty > 0 else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var texts = Array(counts.keys)
        texts.sort { a, b in
            let ca = counts[a] ?? 0
            let cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
        if texts.count > maxFreqEntries {
            for text in texts[maxFreqEntries...] {
                counts.removeValue(forKey: text)
            }
            texts.removeLast(texts.count - maxFreqEntries)
        }
        var out = ""
        out.reserveCapacity(texts.count * 8)
        for text in texts {
            out += "\(text)\t\(counts[text] ?? 0)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
        dirty = 0
        diskStamp = fileStamp(path)
    }

    /// 文件在上次读写之后被别的进程改过或删掉。
    var changedOnDisk: Bool {
        !path.isEmpty && fileStamp(path) != diskStamp
    }

    /// text 的词频加权。封顶是为了不让个别词永远霸榜，同时也保证它只影响
    /// 层内的顺序，翻不过「整段匹配」那一层。
    func boost(_ text: String) -> Int64 {
        freqBoost(counts[text] ?? 0)
    }

    /// 直接用词表里的字节查表，省掉调用方先拼字符串。
    func boost(_ raw: UnsafeRawBufferPointer, _ off: Int, _ len: Int) -> Int64 {
        boost(String(decoding: raw[off..<(off + len)], as: UTF8.self))
    }

    /// 任何词能拿到的最大加权，用来在查表前先排除进不了候选的词。
    var maxBoost: Int64 { Int64(maxBoostCount) * boostPerPick }
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
