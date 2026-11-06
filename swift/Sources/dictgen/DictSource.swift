import Foundation
import WenshanCore

/// 读入的全部词条，键是「编码\0词条」：同一编码同一词条只留一份。
typealias EntryMap = [String: Entry]

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
                n += parseRimeLine(line, into: &best)
            }
            continue
        }
        n += parseRimeLine(line, into: &best)
    }
    return n
}

/// 解析一行词条。拼音按空白分成音节，用自然码规则转成两键编码；
/// 权重缺省或不是十进制非负整数时记 0。
func parseRimeLine(_ line: String, into best: inout EntryMap) -> Int {
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
