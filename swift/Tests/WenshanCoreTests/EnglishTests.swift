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
}
