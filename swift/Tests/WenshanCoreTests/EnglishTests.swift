import Foundation
import XCTest

@testable import WenshanCore

func englishDict(_ entries: [EnglishEntry]) -> EnglishDict {
    try! EnglishDict(data: writeEnglishDict(entries))
}

final class EnglishDictTests: XCTestCase {
    func testLookupExactAndPrefix() {
        let d = englishDict([
            EnglishEntry(code: "hello", display: "hello", weight: 300),
            EnglishEntry(code: "hell", display: "hell", weight: 2),
            EnglishEntry(code: "help", display: "Help", weight: 100),
            EnglishEntry(code: "github", display: "GitHub", weight: 0),
        ])
        XCTAssertEqual(d.count, 4)
        XCTAssertEqual(
            d.lookup(Array("hello".utf8), exactOnly: true, limit: 5).map(\.display), ["hello"])
        XCTAssertEqual(
            d.lookup(Array("hell".utf8), exactOnly: false, limit: 5).map(\.display),
            ["hell", "hello"])
        XCTAssertEqual(
            d.lookup(Array("github".utf8), exactOnly: true, limit: 5).map(\.display), ["GitHub"])
    }

    /// 编码字典序靠后但权重更高的前缀补全词不能被 limit 早退漏掉。
    func testPrefixLookupPicksHighestWeightBeyondLexOrder() {
        let d = englishDict([
            EnglishEntry(code: "intera", display: "intera", weight: 10),
            EnglishEntry(code: "interb", display: "interb", weight: 20),
            EnglishEntry(code: "interc", display: "interc", weight: 30),
            EnglishEntry(code: "interd", display: "interd", weight: 40),
            EnglishEntry(code: "intere", display: "intere", weight: 50),
            EnglishEntry(code: "internet", display: "internet", weight: 9000),
        ])
        let hits = d.lookup(Array("inter".utf8), exactOnly: false, limit: 5).map(\.display)
        XCTAssertEqual(hits.first, "internet")
    }
}

final class EnglishCandidateTests: XCTestCase {
    func engine(_ entries: [Entry], _ english: [EnglishEntry]) -> Engine {
        let e = Engine(dict: buildDict(entries))
        e.setEnglishDict(englishDict(english))
        return e
    }

    /// 模拟 Session.type：中文态字母输入会打开英文查询。
    func typeEnglish(_ e: Engine, _ keys: String) {
        for b in keys.utf8 {
            XCTAssertTrue(e.type(b))
            e.englishQuery = true
        }
    }

    /// 精确命中的英文词插在第 2 位，不抢中文首选；空格仍上屏中文。
    func testExactEnglishAfterChineseFirst() {
        let e = engine(
            [Entry(code: "hello", text: "何来哦", weight: 500)],
            [EnglishEntry(code: "hello", display: "hello", weight: 300)])
        typeEnglish(e, "hello")
        XCTAssertEqual(e.candidates.first?.text, "何来哦")
        XCTAssertEqual(e.candidates.count > 1 ? e.candidates[1].text : "", "hello")
        XCTAssertEqual(e.select(1).0, "hello")
        XCTAssertTrue(e.buffer.isEmpty)
    }

    /// 只匹配前缀的补全词追加到末尾，不挤占中文候选。
    func testPrefixEnglishAppended() {
        let e = engine(
            [Entry(code: "hello", text: "何来哦", weight: 500)],
            [
                EnglishEntry(code: "hello", display: "hello", weight: 300),
                EnglishEntry(code: "hellos", display: "hellos", weight: 200),
            ])
        // hello 精确命中插第 2 位，hellos 只是前缀补全，追加到末尾。
        typeEnglish(e, "hello")
        XCTAssertEqual(e.candidates.first?.text, "何来哦")
        XCTAssertEqual(e.candidates[1].text, "hello")
        XCTAssertEqual(e.candidates.last?.text, "hellos")
    }

    /// 词表查不到时给一条原文兜底候选，中文态直接打英文仍能上屏。
    func testRawFallback() {
        let e = engine([], [])
        typeEnglish(e, "zzzzz")
        XCTAssertEqual(e.candidates.first?.text, "zzzzz")
        XCTAssertEqual(e.select(0).0, "zzzzz")
    }

    /// 首字母大写推导 Title，前两个大写推导全大写；专名保留混排形态。
    func testCaseDerivation() {
        let e = engine([], [
            EnglishEntry(code: "hello", display: "hello", weight: 300),
            EnglishEntry(code: "github", display: "GitHub", weight: 200),
        ])
        e.reset()
        typeEnglish(e, "Hello")
        XCTAssertEqual(e.candidates.first?.text, "Hello")

        e.reset()
        typeEnglish(e, "HEllo")
        XCTAssertEqual(e.candidates.first?.text, "HELLO")

        e.reset()
        typeEnglish(e, "Github")
        XCTAssertEqual(e.candidates.first?.text, "GitHub")
    }

    /// 两键精确命中仍给英文候选，但插在中文首选之后；一键不触发。
    func testShortExactEnglishKeepsChineseFirst() {
        let e = engine(
            [Entry(code: "ni", text: "你", weight: 500)],
            [EnglishEntry(code: "ni", display: "Ni", weight: 300)])
        typeEnglish(e, "ni")
        XCTAssertEqual(e.candidates.map(\.text), ["你", "Ni"])

        e.reset()
        typeEnglish(e, "n")
        XCTAssertFalse(e.candidates.contains { $0.text == "Ni" })
    }

    /// 词中间大写：小写前缀后接 Shift+字母，已打的字母不能被吞掉。
    /// 回归 iPhone = i + Shift+P + hone。
    func testShiftLetterKeepsLowercasePrefix() {
        let e = engine([], [
            EnglishEntry(code: "iphone", display: "iPhone", weight: 999),
        ])
        let s = Session(eng: e)
        _ = s.type(UInt8(ascii: "i"))
        _ = s.shiftLetter(UInt8(ascii: "P"))
        for b in "hone".utf8 { _ = s.type(b) }
        XCTAssertEqual(s.preedit, "iPhone")
        XCTAssertEqual(s.candidates.first?.text, "iPhone")
        XCTAssertEqual(s.select(0).text, "iPhone")
    }

    /// 拼音缓冲里按 Shift 也不清空前缀：统一作为英文串继续，词表不认识时
    /// 给原文兜底，回车仍能原样上屏。
    func testShiftLetterAppendsToPinyinBuffer() {
        let e = engine([], [])
        let s = Session(eng: e)
        typeKeys(s, "ni")
        _ = s.shiftLetter(UInt8(ascii: "A"))
        XCTAssertEqual(s.preedit, "niA")
        XCTAssertTrue(s.candidates.contains { $0.text == "niA" })
    }

    /// 驼峰混排（macOS）下中文只有前缀单字（吗）时，英文精确词应排第一。
    func testCamelCaseBeatsChineseShortPrefix() {
        let e = engine(
            [Entry(code: "ma", text: "吗", weight: 5000)],
            [EnglishEntry(code: "macos", display: "macOS", weight: 500)])
        let s = Session(eng: e)
        for b in "mac".utf8 { _ = s.type(b) }
        _ = s.shiftLetter(UInt8(ascii: "O"))
        _ = s.shiftLetter(UInt8(ascii: "S"))
        XCTAssertEqual(s.candidates.first?.text, "macOS")
    }

    /// 中文只命中前缀、辅码单字、组句拼接或纠错时，全小写精确英文词直接排首位。
    func testExactLowercaseEnglishBeatsNonExactChinese() {
        // 1. 仅前缀命中（world -> wo「我」为短匹配）
        let ePrefix = engine(
            [Entry(code: "wo", text: "我", weight: 5000)],
            [EnglishEntry(code: "world", display: "world", weight: 100)])
        typeEnglish(ePrefix, "world")
        XCTAssertEqual(ePrefix.candidates.map(\.text), ["world", "我"])

        // 2. 仅单字辅码命中（what -> wh「王」辅码降为 tierLong）
        let eAux = engine(
            [
                Entry(code: "what", text: "王", weight: 5000),
                Entry(code: "wh", text: "望", weight: 3000),
            ],
            [EnglishEntry(code: "what", display: "what", weight: 100)])
        typeEnglish(eAux, "what")
        XCTAssertEqual(eAux.candidates.first?.text, "what")
        XCTAssertTrue(eAux.candidates.contains { $0.text == "王" })

        // 3. 仅组句拼接命中（hello -> 和 + 来 + 哦，不是词库整词）
        let eCompose = engine(
            [
                Entry(code: "he", text: "和", weight: 5000),
                Entry(code: "la", text: "来", weight: 5000),
                Entry(code: "ll", text: "来", weight: 5000),
                Entry(code: "oo", text: "哦", weight: 5000),
            ],
            [EnglishEntry(code: "hello", display: "hello", weight: 100)])
        typeEnglish(eCompose, "hello")
        XCTAssertEqual(eCompose.candidates.first?.text, "hello")
        XCTAssertTrue(eCompose.candidates.contains { $0.text == "和来哦" })

        // 4. 仅纠错命中（ok -> neighbor 纠错出「老」）
        let eTypo = engine(
            [Entry(code: "ol", text: "老", weight: 5000)],
            [EnglishEntry(code: "ok", display: "OK", weight: 100)])
        typeEnglish(eTypo, "ok")
        XCTAssertEqual(eTypo.candidates.map(\.text), ["OK", "老"])
    }

    /// 用户主动按 Shift 打出大写字母时，即使同拼写存在中文真词，英文仍排首位。
    func testShiftUppercaseEnglishBeatsChineseExact() {
        let e = engine(
            [Entry(code: "name", text: "那么", weight: 9000)],
            [EnglishEntry(code: "name", display: "name", weight: 100)])
        let s = Session(eng: e)
        _ = s.shiftLetter(UInt8(ascii: "N"))
        typeKeys(s, "ame")
        XCTAssertEqual(s.candidates.first?.text, "Name")

        // 同编码全小写仍保持中文整词在首位。
        _ = s.escape()
        typeKeys(s, "name")
        XCTAssertEqual(s.candidates.first?.text, "那么")
        XCTAssertEqual(s.candidates.dropFirst().first?.text, "name")
    }

    /// 退格删空或选词上屏后，englishRun 必须复位，后续大写键按普通拼音处理。
    func testEnglishRunResetsAfterBackspaceAndSelect() {
        let e = engine(
            [Entry(code: "aa", text: "啊", weight: 500)],
            [EnglishEntry(code: "ip", display: "IP", weight: 500)])
        let s = Session(eng: e)
        _ = s.shiftLetter(UInt8(ascii: "I"))
        _ = s.backspace()
        XCTAssertTrue(s.preedit.isEmpty)
        _ = s.type(UInt8(ascii: "A"))
        XCTAssertEqual(s.preedit, "a")
        _ = s.escape()

        _ = s.shiftLetter(UInt8(ascii: "I"))
        _ = s.shiftLetter(UInt8(ascii: "P"))
        XCTAssertEqual(s.select(0).text, "IP")
        _ = s.type(UInt8(ascii: "A"))
        XCTAssertEqual(s.preedit, "a")
    }

    /// 中文后点选英文候选也应补空格，和回车上屏原文一致。
    func testChineseBeforeEnglishCandidateAddsSpace() {
        let e = engine(
            [Entry(code: "ni", text: "你", weight: 500)],
            [EnglishEntry(code: "hello", display: "hello", weight: 500)])
        var doc = ""
        let s = Session(eng: e)
        s.setLookbehind { doc.unicodeScalars.last }
        typeKeys(s, "ni")
        let first = s.select(0)
        doc += first.text
        typeKeys(s, "hello")
        let eng = s.select(0)
        XCTAssertEqual(eng.text, " hello")
    }

    /// 页大小较小时，英文前缀补全只在中文正常候选耗尽后追加，不打乱翻页顺序。
    func testPagingDoesNotReorderEnglishPrefix() {
        let e = engine(
            [
                Entry(code: "abcde", text: "词一", weight: 400),
                Entry(code: "abcde", text: "词二", weight: 300),
                Entry(code: "abcde", text: "词三", weight: 200),
                Entry(code: "abcde", text: "词四", weight: 100),
            ],
            [EnglishEntry(code: "abcdef", display: "abcdef", weight: 900)])
        e.pageSize = 2
        typeEnglish(e, "abcde")
        XCTAssertEqual(e.candidates.map(\.text), ["词一", "词二"])
        XCTAssertTrue(e.page(1))
        XCTAssertEqual(e.candidates.map(\.text), ["词三", "词四"])
        XCTAssertTrue(e.page(1))
        XCTAssertEqual(e.candidates.map(\.text), ["abcdef"])
    }

    /// Shift+B 接 vj 生成「B 站」，前面是中文时上屏仍自动补空格。
    func testMixedSingleUpperLetterAndPinyin() {
        let e = engine(
            [
                Entry(code: "vj", text: "站", weight: 5000),
                Entry(code: "vj", text: "占", weight: 1000),
            ],
            [])
        let doc = "看"
        let s = Session(eng: e)
        s.setLookbehind { doc.unicodeScalars.last }
        _ = s.shiftLetter(UInt8(ascii: "B"))
        typeKeys(s, "vj")
        XCTAssertEqual(s.preedit, "Bvj")
        XCTAssertEqual(s.candidates.first?.text, "B 站")
        XCTAssertEqual(s.candidates.last?.text, "Bvj")
        let res = s.select(0)
        XCTAssertEqual(res.text, " B 站")
        XCTAssertTrue(s.preedit.isEmpty)
    }

    /// 混输长句组句和分段选词：Bvjdm 先组出「B 站点」，先选「B 站」后剩余 dm 继续出「点」。
    func testMixedComposeAndPartialSelect() {
        let e = engine(
            [
                Entry(code: "vj", text: "站", weight: 5000),
                Entry(code: "dm", text: "点", weight: 4000),
            ],
            [])
        let s = Session(eng: e)
        _ = s.shiftLetter(UInt8(ascii: "B"))
        typeKeys(s, "vjdm")
        XCTAssertEqual(s.candidates.first?.text, "B 站点")
        guard let partialIdx = s.candidates.firstIndex(where: { $0.text == "B 站" }) else {
            return XCTFail("缺少可继续组词的混输短候选 B 站")
        }
        XCTAssertEqual(s.select(partialIdx).text, "B 站")
        XCTAssertEqual(s.preedit, "dm")
        XCTAssertEqual(s.candidates.first?.text, "点")
    }

    /// 全大写缩写和英文词典词也能接双拼后缀，并且支持 ü 变体。
    func testMixedAcronymAndEnglishWordPrefix() {
        let e = engine(
            [
                Entry(code: "vuuu", text: "助手", weight: 5000),
                Entry(code: "uddm", text: "商店", weight: 5000),
                Entry(code: "bm", text: "版", weight: 5000),
                Entry(code: "jixv", text: "继续", weight: 5000),
            ],
            [
                EnglishEntry(code: "app", display: "app", weight: 900),
                EnglishEntry(code: "iphone", display: "iPhone", weight: 900),
            ])
        let s = Session(eng: e)
        _ = s.shiftLetter(UInt8(ascii: "A"))
        _ = s.shiftLetter(UInt8(ascii: "I"))
        typeKeys(s, "vuuu")
        XCTAssertEqual(s.candidates.first?.text, "AI 助手")

        _ = s.escape()
        _ = s.shiftLetter(UInt8(ascii: "A"))
        typeKeys(s, "ppuddm")
        XCTAssertEqual(s.candidates.first?.text, "App 商店")

        _ = s.escape()
        _ = s.type(UInt8(ascii: "i"))
        _ = s.shiftLetter(UInt8(ascii: "P"))
        typeKeys(s, "honebm")
        XCTAssertEqual(s.candidates.first?.text, "iPhone 版")

        _ = s.escape()
        _ = s.shiftLetter(UInt8(ascii: "A"))
        typeKeys(s, "jixu")
        XCTAssertEqual(s.candidates.first?.text, "A 继续")
    }

    /// 精确英文单词优先级高于拆字混排；全小写和单字母后缀不误触发混输。
    func testMixedDoesNotStealExactEnglishOrLowercase() {
        let e = engine(
            [
                Entry(code: "aj", text: "安", weight: 9000),
                Entry(code: "vj", text: "站", weight: 9000),
                Entry(code: "bu", text: "不", weight: 9000),
            ],
            [
                EnglishEntry(code: "fan", display: "fan", weight: 100),
            ])
        let s = Session(eng: e)
        _ = s.shiftLetter(UInt8(ascii: "F"))
        typeKeys(s, "aj")
        // F + aj 在无精确英文词时出「F 安」
        XCTAssertEqual(s.candidates.first?.text, "F 安")

        // 精确命中英文单词 fan 时，Fan 必须排在「F 安」前面。
        let e2 = engine(
            [Entry(code: "an", text: "安", weight: 9000)],
            [EnglishEntry(code: "fan", display: "fan", weight: 100)])
        let s2 = Session(eng: e2)
        _ = s2.shiftLetter(UInt8(ascii: "F"))
        typeKeys(s2, "an")
        XCTAssertEqual(s2.candidates.first?.text, "Fan")
        XCTAssertTrue(s2.candidates.contains { $0.text == "F 安" })

        // 全小写 bvj 不拆成「b 站」。
        _ = s.escape()
        typeKeys(s, "bvj")
        XCTAssertFalse(s.candidates.contains { $0.text == "b 站" })

        // 单键后缀（Bv）不误拆，保持原文兜底。
        _ = s.escape()
        _ = s.shiftLetter(UInt8(ascii: "B"))
        _ = s.type(UInt8(ascii: "v"))
        XCTAssertEqual(s.candidates.first?.text, "Bv")
    }

    /// 选过「B 站」后词频会把「B 站」学到权重更高的同音字前面。
    func testMixedCandidateFreqLearning() {
        let e = engine(
            [
                Entry(code: "vj", text: "战", weight: 9000),
                Entry(code: "vj", text: "站", weight: 5000),
            ],
            [])
        e.setFreq(Freq())
        let s = Session(eng: e)
        _ = s.shiftLetter(UInt8(ascii: "B"))
        typeKeys(s, "vj")
        XCTAssertEqual(s.candidates.first?.text, "B 战")
        for _ in 0..<5 {
            guard let idx = s.candidates.firstIndex(where: { $0.text == "B 站" }) else {
                return XCTFail("找不到 B 站")
            }
            XCTAssertEqual(s.select(idx).text, "B 站")
            _ = s.shiftLetter(UInt8(ascii: "B"))
            typeKeys(s, "vj")
        }
        XCTAssertEqual(s.candidates.first?.text, "B 站")
    }
}
