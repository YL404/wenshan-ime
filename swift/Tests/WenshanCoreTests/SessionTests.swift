import Foundation
import XCTest

@testable import WenshanCore

/// 模拟宿主正文：规则层通过 lookbehind 读它最后一格，测试里自己维护。
final class Doc {
    var chars: [Unicode.Scalar] = []

    func insert(_ text: String) {
        chars.append(contentsOf: text.unicodeScalars)
    }

    func delete(_ n: Int) {
        chars.removeLast(n)
    }

    func before() -> Unicode.Scalar? {
        chars.last
    }
}

func sessionDict() -> Dict {
    buildDict([
        Entry(code: "ni", text: "你", weight: 2500),
        Entry(code: "nihk", text: "你好", weight: 2400),
    ])
}

/// 建一个「光标停在 text 末尾」的会话，返回的 doc 由测试自己维护。
func withDoc(_ text: String) -> (Session, Doc) {
    let d = Doc()
    d.insert(text)
    let s = Session(eng: Engine(dict: sessionDict()))
    s.setLookbehind { d.before() }
    return (s, d)
}

func typeKeys(_ s: Session, _ keys: String) {
    for b in keys.utf8 {
        _ = s.type(b)
    }
}

private let comma = UInt8(ascii: ",")
private let period = UInt8(ascii: ".")
private let quote = UInt8(ascii: "\"")
private let minus = UInt8(ascii: "-")
private let slash = UInt8(ascii: "/")
private let backslash = UInt8(ascii: "\\")

final class SessionTests: XCTestCase {
    func testPunctuate() {
        let s = Session(eng: nil)
        let r = s.punctuate(comma)
        XCTAssertTrue(r.consumed)
        XCTAssertEqual(r.text, "，")
        XCTAssertEqual(s.punctuate(quote).text, "“")
        XCTAssertEqual(s.punctuate(quote).text, "”")
        XCTAssertFalse(s.punctuate(minus).consumed, "减号不该被替换")
        // 顿号在社区配置里通常同时接受 / 和 \，只留 \ 不容易发现。
        for ch in [slash, backslash] {
            let s2 = Session(eng: nil)
            let r2 = s2.punctuate(ch)
            XCTAssertTrue(r2.consumed)
            XCTAssertEqual(r2.text, "、")
        }
    }

    func testNumberPunct() {
        var (s, _) = withDoc("1")
        XCTAssertEqual(s.punctuate(period).text, ".")
        (s, _) = withDoc("我")
        XCTAssertEqual(s.punctuate(period).text, "。")
        (s, _) = withDoc("1")
        XCTAssertEqual(s.punctuate(comma).text, "，")
    }

    func testFullWidthOff() {
        let s = Session(eng: nil)
        _ = s.toggleFullWidth()
        XCTAssertFalse(s.punctuate(comma).consumed, "半角时标点不该被输入法消费")
    }

    func testSpacing() {
        var (s, _) = withDoc("我")
        XCTAssertEqual(s.passthrough(UInt8(ascii: "a")).text, " ")
        (s, _) = withDoc("我")
        XCTAssertEqual(s.passthrough(period).text, "")
        XCTAssertEqual(classOf("我"), .cjk)
        XCTAssertEqual(classOf("abc"), .ascii)
        XCTAssertEqual(classOf("API"), .ascii)
        XCTAssertEqual(classOf("，"), .none)
        XCTAssertEqual(classOf(""), .none)
        // 问不到正文时不补空格，也不该崩。
        XCTAssertEqual(Session(eng: nil).passthrough(UInt8(ascii: "a")).text, "")
    }

    func testSelectAndSpace() {
        let (s, d) = withDoc("")
        typeKeys(s, "ni")
        let r = s.space()
        XCTAssertEqual(r.text, "你")
        XCTAssertTrue(r.consumed)
        XCTAssertEqual(s.buffer, "")
        d.insert(r.text)
        XCTAssertEqual(s.passthrough(UInt8(ascii: "a")).text, " ")
    }

    func testPunctuateCommitsPending() {
        let s = Session(eng: Engine(dict: sessionDict()))
        typeKeys(s, "ni")
        XCTAssertEqual(s.punctuate(comma).text, "你，")
    }

    func testDirectCommitsPending() {
        let s = Session(eng: Engine(dict: sessionDict()))
        typeKeys(s, "ni")
        XCTAssertEqual(s.direct("。").text, "你。")
    }

    func testTempEnglish() {
        let s = Session(eng: Engine(dict: nil))
        typeKeys(s, "ni")
        let r = s.shiftLetter(UInt8(ascii: "A"))
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(s.preedit, "niA")
        _ = s.type(UInt8(ascii: "B"))
        XCTAssertEqual(s.preedit, "niAB")
        XCTAssertEqual(s.space().text, "niAB ")
        XCTAssertEqual(s.preedit, "")
    }

    func testReturnInline() {
        let s = Session(eng: Engine(dict: nil))
        typeKeys(s, "ni")
        _ = s.shiftLetter(UInt8(ascii: "A"))
        let r = s.returnKey()
        XCTAssertEqual(r.text, "niA")
        XCTAssertTrue(r.consumed)
    }

    func testPageCommitsInline() {
        let s = Session(eng: Engine(dict: nil))
        typeKeys(s, "ni")
        _ = s.shiftLetter(UInt8(ascii: "A"))
        let r = s.page(1)
        XCTAssertEqual(r.text, "niA")
        XCTAssertFalse(r.consumed)
    }

    func testPassthroughCommitsPending() {
        let s = Session(eng: Engine(dict: sessionDict()))
        typeKeys(s, "ni")
        let r = s.passthrough(UInt8(ascii: "+"))
        XCTAssertEqual(r.text, "你")
        XCTAssertFalse(r.consumed)
        XCTAssertEqual(s.buffer, "")
    }

    func testShiftLetterNoBuffer() {
        let (s, _) = withDoc("我")
        XCTAssertEqual(s.shiftLetter(UInt8(ascii: "A")).text, " A")
    }

    func testBackspaceInline() {
        let s = Session(eng: Engine(dict: nil))
        typeKeys(s, "ni")
        _ = s.shiftLetter(UInt8(ascii: "A"))
        var r = s.backspace()
        XCTAssertTrue(r.consumed)
        XCTAssertEqual(s.preedit, "ni")
        _ = s.backspace()
        _ = s.backspace()
        XCTAssertEqual(s.preedit, "")
        r = s.backspace()
        XCTAssertFalse(r.consumed, "没有组合时退格应交给平台")
    }

    func testReturnAndToggleMode() {
        var s = Session(eng: Engine(dict: nil))
        typeKeys(s, "ab")
        XCTAssertEqual(s.returnKey().text, "ab")

        s = Session(eng: Engine(dict: nil))
        typeKeys(s, "ab")
        let r = s.toggleMode()
        XCTAssertEqual(r.text, "ab")
        XCTAssertEqual(s.currentMode, .english)
        XCTAssertFalse(s.space().consumed, "英文模式空格应交给平台")
    }

    func testFinish() {
        let s = Session(eng: Engine(dict: sessionDict()))
        typeKeys(s, "ni")
        XCTAssertEqual(s.finish().text, "你")
        XCTAssertEqual(s.preedit, "")
        XCTAssertTrue(s.candidates.isEmpty)
    }

    /// 删掉刚上屏的英文（连前面的空格）后重打，正文前一个字符回到中文，仍要补空格。
    func testSpacingAfterDelete() {
        let (s, d) = withDoc("你")
        d.insert(" abc")
        d.delete(4)
        XCTAssertEqual(s.passthrough(UInt8(ascii: "a")).text, " ")
        // 只删字母时前面的空格还在，不能再补一个。
        d.insert(" abc")
        d.delete(3)
        XCTAssertEqual(s.passthrough(UInt8(ascii: "a")).text, "")
    }

    /// 删掉平台插入的空格后，前面是中文，打英文要补空格。
    func testSpaceThenEnglish() {
        let (s, d) = withDoc("")
        typeKeys(s, "ni")
        d.insert(s.space().text)
        _ = s.space()
        d.insert(" ")
        d.delete(1)
        XCTAssertEqual(s.passthrough(UInt8(ascii: "a")).text, " ")
    }

    /// 英文后接中文，中文前面要补空格。
    func testChineseAfterEnglish() {
        let (s, _) = withDoc("abc")
        typeKeys(s, "ni")
        XCTAssertEqual(s.space().text, " 你")
    }

    /// 英文直通模式同样按正文补空格。
    func testEnglishModeSpacing() {
        let (s, _) = withDoc("你")
        _ = s.toggleMode()
        XCTAssertEqual(s.passthrough(UInt8(ascii: "a")).text, " ")
    }

    /// 光标前是数字时句号保持半角，退格之后也一样。
    func testDigitAfterDelete() {
        var (s, d) = withDoc("12")
        d.delete(1)
        XCTAssertEqual(s.punctuate(period).text, ".")
        (s, d) = withDoc("a1")
        d.delete(1)
        XCTAssertEqual(s.punctuate(period).text, "。")
    }

    /// 查不到正文时按「前面没有字符」处理，不补空格。
    func testLookbehindFails() {
        let s = Session(eng: Engine(dict: sessionDict()))
        s.setLookbehind { nil }
        XCTAssertEqual(s.passthrough(UInt8(ascii: "a")).text, "")
    }

    /// 同一次按键里先上屏的候选也算「光标前的字符」。
    func testPendingTextIsLookbehind() {
        var (s, _) = withDoc("3")
        typeKeys(s, "nihk")
        XCTAssertEqual(s.punctuate(period).text, " 你好。")
        (s, _) = withDoc("abc")
        typeKeys(s, "nihk")
        XCTAssertEqual(s.passthrough(UInt8(ascii: "0")).text, " 你好 ")
    }

    /// 缓冲查不到候选时，标点和停用输入法都把编码原样上屏，不留在引擎里。
    func testPendingRawWithoutCandidates() {
        let s = Session(eng: Engine(dict: sessionDict()))
        typeKeys(s, "qqq")
        let r = s.punctuate(comma)
        XCTAssertEqual(r.text, "qqq，")
        XCTAssertEqual(s.buffer, "")
        typeKeys(s, "qqq")
        XCTAssertEqual(s.finish().text, "qqq")
    }

    /// iOS 用 Direct 插入英文字母和数字，补空格要和 macOS 的 Passthrough 一致。
    func testDirectSpacingMatchesPassthrough() {
        for text in ["a", "A", "7", "@", "，"] {
            let first = text.utf8.first!
            var (s, _) = withDoc("你")
            _ = s.toggleMode()
            var want = s.passthrough(first).text + text
            if text == "，" { want = text }
            (s, _) = withDoc("你")
            _ = s.toggleMode()
            XCTAssertEqual(s.direct(text).text, want, "Direct(\(text))")
        }
        // 中文模式下组合中的候选先上屏，再按候选末字补空格。
        let s = Session(eng: Engine(dict: sessionDict()))
        typeKeys(s, "ni")
        XCTAssertEqual(s.direct("5").text, "你 5")
    }
}
