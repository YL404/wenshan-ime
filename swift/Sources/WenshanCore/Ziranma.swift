/// 双拼自然码的编码。
///
/// 键位表直接来自 Rime 的 double_pinyin.schema.yaml（speller/algebra 的改写
/// 规则），逐条还原成「声母键 + 韵母键」两张表。因为双拼每个音节固定两个键，
/// 编码全等长且可拼接，查词只需要一次前缀匹配，不需要切分歧义。
public enum Ziranma {
    /// 自然码里占一个键的双字母声母。
    static let twoLetterInitials: [String: UInt8] = [
        "zh": UInt8(ascii: "v"),
        "ch": UInt8(ascii: "i"),
        "sh": UInt8(ascii: "u"),
    ]

    /// 声母到键位的映射，键位与字母本身相同。
    static let oneLetterInitials: Set<UInt8> = [
        UInt8(ascii: "b"), UInt8(ascii: "p"), UInt8(ascii: "m"), UInt8(ascii: "f"),
        UInt8(ascii: "d"), UInt8(ascii: "t"), UInt8(ascii: "n"), UInt8(ascii: "l"),
        UInt8(ascii: "g"), UInt8(ascii: "k"), UInt8(ascii: "h"),
        UInt8(ascii: "j"), UInt8(ascii: "q"), UInt8(ascii: "x"),
        UInt8(ascii: "r"), UInt8(ascii: "z"), UInt8(ascii: "c"), UInt8(ascii: "s"),
        UInt8(ascii: "y"), UInt8(ascii: "w"),
    ]

    /// 韵母到键位的映射。零声母音节的 a/o/e 也在这张表里（键位就是它本身）。
    static let finals: [String: UInt8] = [
        "a": UInt8(ascii: "a"), "o": UInt8(ascii: "o"), "e": UInt8(ascii: "e"),
        "i": UInt8(ascii: "i"), "u": UInt8(ascii: "u"), "v": UInt8(ascii: "v"),
        "ai": UInt8(ascii: "l"), "ei": UInt8(ascii: "z"),
        "ao": UInt8(ascii: "k"), "ou": UInt8(ascii: "b"),
        "an": UInt8(ascii: "j"), "en": UInt8(ascii: "f"),
        "ang": UInt8(ascii: "h"), "eng": UInt8(ascii: "g"),
        "er": UInt8(ascii: "r"),
        "ia": UInt8(ascii: "w"), "ie": UInt8(ascii: "x"),
        "iao": UInt8(ascii: "c"), "iu": UInt8(ascii: "q"),
        "ian": UInt8(ascii: "m"), "in": UInt8(ascii: "n"),
        "iang": UInt8(ascii: "d"), "ing": UInt8(ascii: "y"),
        "iong": UInt8(ascii: "s"),
        "ua": UInt8(ascii: "w"), "uo": UInt8(ascii: "o"),
        "uai": UInt8(ascii: "y"), "ui": UInt8(ascii: "v"),
        "uan": UInt8(ascii: "r"), "un": UInt8(ascii: "p"),
        "uang": UInt8(ascii: "d"), "ong": UInt8(ascii: "s"),
        "ue": UInt8(ascii: "t"), "ve": UInt8(ascii: "t"),
        "van": UInt8(ascii: "r"), "vn": UInt8(ascii: "p"),
    ]

    /// j/q/x/y 后的 u 是不是 ü（Rime 用 derive 把它改写成 v）。
    static func isUmlautInitial(_ b: UInt8) -> Bool {
        b == UInt8(ascii: "j") || b == UInt8(ascii: "q")
            || b == UInt8(ascii: "x") || b == UInt8(ascii: "y")
    }

    /// 把一个拼音音节拆成声母键和韵母。零声母返回 init 0。
    static func splitSyllable(_ syl: String) -> (init: UInt8, fin: String) {
        let bytes = Array(syl.utf8)
        guard let first = bytes.first else { return (0, "") }
        if bytes.count >= 2, let k = twoLetterInitials[String(decoding: bytes[0..<2], as: UTF8.self)]
        {
            return (k, String(decoding: bytes[2...], as: UTF8.self))
        }
        if oneLetterInitials.contains(first) {
            return (first, String(decoding: bytes[1...], as: UTF8.self))
        }
        return (0, "")
    }

    /// 返回一个音节的两键写法。Rime 用 derive 保留了部分原始拼写
    /// （ju/qu/xu/yu、零声母的 ai/ao/an/en/ou），这些也一并返回。
    static func syllableCodes(_ syl: String) -> [String] {
        guard !syl.isEmpty else { return [] }
        let bytes = Array(syl.utf8)
        let (initial, fin) = splitSyllable(syl)
        if initial == 0 {
            // 零声母：首字母当占位，韵母照表取键（a→aa、ang→ah、er→er）。
            guard let k = finals[syl] else { return [] }
            var out = [String(decoding: [bytes[0], k], as: UTF8.self)]
            // 两字母的零声母韵母（ai/ao/an/en/ou）也接受原样输入。
            if bytes.count == 2 && bytes[0] != bytes[1] {
                out.append(syl)
            }
            return dedupCodes(out)
        }
        guard !fin.isEmpty else { return [] }
        var final = fin
        if isUmlautInitial(initial) && final == "u" {
            final = "v"
        }
        guard let k = finals[final] else { return [] }
        var out = [String(decoding: [initial, k], as: UTF8.self)]
        if final == "v" && isUmlautInitial(initial) {
            out.append(String(decoding: [initial, UInt8(ascii: "u")], as: UTF8.self))
        }
        return dedupCodes(out)
    }

    static func dedupCodes(_ input: [String]) -> [String] {
        guard let first = input.first else { return [] }
        var out = [first]
        for c in input.dropFirst() where c != first {
            out.append(c)
        }
        return out
    }

    /// 返回整个词组的编码。单音节词会同时给出备选写法；多音节词只用规范写法，
    /// 避免组合爆炸。
    public static func codes(_ syllables: [String]) -> [String] {
        guard let first = syllables.first else { return [] }
        if syllables.count == 1 {
            return syllableCodes(first)
        }
        var code: [UInt8] = []
        code.reserveCapacity(syllables.count * 2)
        for syl in syllables {
            let cs = syllableCodes(syl)
            guard let canonical = cs.first else { return [] }
            code.append(contentsOf: canonical.utf8)
        }
        return [String(decoding: code, as: UTF8.self)]
    }
}
