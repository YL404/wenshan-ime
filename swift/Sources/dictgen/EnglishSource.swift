import Foundation
import WenshanCore

/// rime-ice 英文词库一行是「词形<TAB>编码<TAB>权重」。编码缺省等于词形的小写，
/// 权重缺省为 0。同一个小写编码允许多种词形（hello / Hello / HELLO 由规则层
/// 推导，这里只保留词库里真的写了的形态）。
func loadEnglishRime(_ path: String, into best: inout [String: EnglishEntry]) throws -> Int {
    var n = 0
    for line in try readLines(path) {
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line == "---" || line == "..." || line.hasPrefix("name:") || line.hasPrefix("version:")
            || line.hasPrefix("sort:")
        {
            continue
        }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { continue }
        let display = String(fields[0])
        let rawCode = String(fields[1])
        var weight: UInt32 = 0
        if fields.count > 2,
           let w = UInt32(fields[2].trimmingCharacters(in: .whitespacesAndNewlines))
        {
            weight = w
        }
        // 只收纯 ASCII 字母：带空格、点、连字符的是 Rime 的短语/缩写别名，
        // 双拼输入法里无法用一条连续字母串命中，收进来只会占前缀扫描名额。
        let code = rawCode.isEmpty ? display.lowercased() : rawCode.lowercased()
        guard !code.isEmpty, code.utf8.count <= 40,
              code.utf8.allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }),
              !display.isEmpty, display.utf8.count <= 40,
              display.utf8.allSatisfy({ isASCIILetter($0) })
        else { continue }
        let key = code + "\u{0}" + display
        let e = EnglishEntry(code: code, display: display, weight: weight)
        if let old = best[key] {
            if weight > old.weight { best[key] = e }
        } else {
            best[key] = e
            n += 1
        }
    }
    return n
}

@inline(__always)
func isASCIILetter(_ b: UInt8) -> Bool {
    (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
        || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
}
