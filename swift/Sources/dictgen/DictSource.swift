import Foundation
import WenshanCore

/// 读入的全部词条，键是「编码\0词条」：同一编码同一词条只留一份。
typealias EntryMap = [String: Entry]

struct BigramCorpus {
    var wordWeights: [String: UInt32] = [:]
    var phrases: [(text: String, weight: UInt32)] = []
}

func entryKey(_ code: String, _ text: String) -> String {
    code + "\u{0}" + text
}

/// 按行读文件，去掉行尾的 \r。按字节切：Swift 把 "\r\n" 当成一个字符，
/// 直接按 "\n" 切 String 会切不开 Windows 换行。
func readLines(_ path: String) throws -> [String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var out: [String] = []
    for var line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
        if line.last == 0x0D { line = line.dropLast() }
        out.append(String(decoding: line, as: UTF8.self))
    }
    if out.last == "" { out.removeLast() }
    return out
}

/// 读一个 Rime 词库文件，把条目合进 best（同一编码同一词条取较高权重），
/// 返回新增的条数。表头以 --- 开始、... 结束，之后每行「词条<TAB>拼音<TAB>权重」；
/// 没有表头的文件从第一行有效内容开始算正文。
func loadRime(_ path: String, into best: inout EntryMap) throws -> Int {
    var corpus = BigramCorpus()
    return try loadRime(path, into: &best, corpus: &corpus)
}

func loadRime(
    _ path: String, into best: inout EntryMap, corpus: inout BigramCorpus,
    minLongWeight: UInt32 = 0, collectBigrams: Bool = false
) throws -> Int {
    var inBody = false
    var seenHeader = false
    var n = 0
    for line in try readLines(path) {
        if !inBody {
            if line == "---" {
                seenHeader = true
            } else if line == "..." {
                inBody = true
            } else if !seenHeader && !line.isEmpty && !line.hasPrefix("#") {
                inBody = true
                n += parseRimeLine(
                    line, into: &best, corpus: &corpus,
                    minLongWeight: minLongWeight, collectBigrams: collectBigrams)
            }
            continue
        }
        n += parseRimeLine(
            line, into: &best, corpus: &corpus,
            minLongWeight: minLongWeight, collectBigrams: collectBigrams)
    }
    return n
}

/// 解析一行词条。拼音按空白分成音节，用自然码规则转成两键编码；
/// 权重缺省或不是十进制非负整数时记 0。
func parseRimeLine(_ line: String, into best: inout EntryMap) -> Int {
    var corpus = BigramCorpus()
    return parseRimeLine(line, into: &best, corpus: &corpus)
}

func parseRimeLine(
    _ line: String, into best: inout EntryMap, corpus: inout BigramCorpus,
    minLongWeight: UInt32 = 0, collectBigrams: Bool = false
) -> Int {
    if line.isEmpty || line.hasPrefix("#") { return 0 }
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count >= 2 else { return 0 }
    let text = String(fields[0])
    let pinyin = fields[1].split(whereSeparator: \.isWhitespace).map(String.init)
    guard !text.isEmpty, !pinyin.isEmpty else { return 0 }
    var weight: UInt32 = 0
    if fields.count > 2 {
        let raw = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let w = UInt32(raw) {
            weight = w
        }
    }
    if minLongWeight > 0 && pinyin.count >= 3 && weight < minLongWeight {
        return 0
    }
    if collectBigrams && weight >= 50 {
        let scalars = text.unicodeScalars.count
        if scalars >= 1 && scalars <= 3 {
            if weight > (corpus.wordWeights[text] ?? 0) {
                corpus.wordWeights[text] = weight
            }
        }
        if scalars >= 3 && scalars <= 6 {
            corpus.phrases.append((text, weight))
        }
    }
    var n = 0
    for code in Ziranma.codes(pinyin) {
        let key = entryKey(code, text)
        if let old = best[key] {
            if weight > old.weight {
                best[key] = Entry(code: code, text: text, weight: weight)
            }
            continue
        }
        best[key] = Entry(code: code, text: text, weight: weight)
        n += 1
    }
    return n
}

/// 从多字短语语料中按最优二元切分提炼高频词对搭配表（左词+右词），
/// 供运行时组句 DP 做零分配共现打分。
func extractBigrams(
    _ corpus: BigramCorpus, limit: Int = 250_000, minWeight: UInt32 = 80
) -> [BigramEntry] {
    guard !corpus.phrases.isEmpty, limit > 0 else { return [] }
    let singleCharPenalty = 3.5
    var sums: [UInt64: UInt64] = [:]
    sums.reserveCapacity(min(corpus.phrases.count, limit * 2))

    for (text, weight) in corpus.phrases {
        let chars = Array(text)
        let count = chars.count
        guard count >= 3 else { continue }
        var bestSplit = -1
        var bestScore = -Double.infinity
        for split in 1..<count {
            let leftCount = split
            let rightCount = count - split
            guard leftCount >= 2 || rightCount >= 2 else { continue }
            let left = String(chars[0..<split])
            let right = String(chars[split..<count])
            guard let wl = corpus.wordWeights[left], let wr = corpus.wordWeights[right] else {
                continue
            }
            let pen = (leftCount == 1 ? singleCharPenalty : 0.0)
                + (rightCount == 1 ? singleCharPenalty : 0.0)
            let score = log(Double(wl) + 1) + log(Double(wr) + 1) - pen
            if score > bestScore {
                bestScore = score
                bestSplit = split
            }
        }
        if bestSplit > 0 {
            let left = String(chars[0..<bestSplit])
            let right = String(chars[bestSplit..<count])
            let h = bigramHash(left, right)
            sums[h, default: 0] += UInt64(weight)
        }
    }

    var entries: [BigramEntry] = []
    entries.reserveCapacity(min(sums.count, limit))
    for (h, total) in sums where total >= UInt64(minWeight) {
        let capped = total > UInt64(UInt32.max) ? UInt32.max : UInt32(total)
        entries.append(BigramEntry(hash: h, weight: capped))
    }
    entries.sort { a, b in
        if a.weight != b.weight { return a.weight > b.weight }
        return a.hash < b.hash
    }
    if entries.count > limit {
        entries.removeLast(entries.count - limit)
    }
    return entries
}

/// 给单字补 2+1 / 2+2 的辅码条目，返回新增的条数。码表每行「字=辅码」或
/// 「字<TAB>辅码」。只给词库里已有两键编码的单字加，权重取该字在词库里的最高权重。
func addAux(_ path: String, into best: inout EntryMap) throws -> Int {
    var bases: [String: [String]] = [:]
    var weights: [String: UInt32] = [:]
    for e in best.values {
        guard e.code.utf8.count == 2, e.text.unicodeScalars.count == 1 else { continue }
        bases[e.text, default: []].append(e.code)
        // 和原实现一致：权重全是 0 的字不进 weights，也就不补辅码。
        if e.weight > weights[e.text, default: 0] {
            weights[e.text] = e.weight
        }
    }

    var seen: Set<String> = []
    var n = 0
    for raw in try readLines(path) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let sep = line.firstIndex(of: "=") ?? line.firstIndex(of: "\t") else { continue }
        let ch = line[..<sep].trimmingCharacters(in: .whitespacesAndNewlines)
        let aux = Array(line[line.index(after: sep)...]
            .trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard ch.unicodeScalars.count == 1, !aux.isEmpty,
              aux.allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }),
              let w = weights[ch]
        else { continue }
        for base in bases[ch] ?? [] {
            for k in 1...min(aux.count, 2) {
                let code = base + String(decoding: aux[0..<k], as: UTF8.self)
                let key = entryKey(code, ch)
                if !seen.insert(key).inserted { continue }
                if let old = best[key], old.weight >= w { continue }
                best[key] = Entry(code: code, text: ch, weight: w)
                n += 1
            }
        }
    }
    return n
}
