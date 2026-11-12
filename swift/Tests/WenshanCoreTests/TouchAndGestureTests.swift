import Foundation
import XCTest

@testable import WenshanCore

/// 本轮 iOS 体验改动涉及的规则层行为：音节退格、智能标点、成对标点、
/// 候选页大小、候选置顶/删除、触点纠错加权。
final class TouchAndGestureTests: XCTestCase {
    func testBackspaceSyllable() {
        let e = Engine(dict: nil)
        typeKeys(e, "nihk")
        XCTAssertEqual(e.buffer.count, 4)
        XCTAssertTrue(e.backspaceSyllable())
        XCTAssertEqual(String(decoding: e.buffer, as: UTF8.self), "ni")
        XCTAssertTrue(e.backspaceSyllable())
        XCTAssertTrue(e.buffer.isEmpty)
        XCTAssertFalse(e.backspaceSyllable(), "缓冲空了不再继续删正文")

        let s = Session(eng: e)
        typeKeys(s, "nihk")
        XCTAssertTrue(s.backspaceSyllable().consumed)
        XCTAssertEqual(s.preedit, "ni")
    }

    func testPageSize() {
        var entries: [Entry] = []
        for i in 0..<12 {
            entries.append(Entry(code: "ni", text: asciiLetter(i), weight: UInt32(100 - i)))
        }
        let e = Engine(dict: buildDict(entries))
        e.pageSize = 5
        typeKeys(e, "ni")
        XCTAssertEqual(e.candidates.count, 5)
        XCTAssertTrue(e.page(1))
        XCTAssertEqual(e.candidates.count, 5)
        e.pageSize = 1
        typeKeys(e, "ni")
        XCTAssertEqual(e.candidates.count, 1)
        e.pageSize = 99
        XCTAssertEqual(e.pageSize, maxCandidates, "页大小夹到 1...9")
    }

    func testRepeatPunctuationTurnsChinese() {
        let (s, d) = withDoc("")
        s.smartPunctuation = true
        let first = s.direct(",")
        XCTAssertEqual(first.text, ",")
        d.insert(first.text)
        let second = s.direct(",")
        XCTAssertEqual(second.text, "，")
        XCTAssertEqual(second.deleteBefore, 1, "删掉刚上屏的 ASCII 逗号")
    }

    func testSpaceRevertsPunctuation() {
        let (s, d) = withDoc("")
        s.spaceRevertsPunctuation = true
        let punct = s.punctuate(UInt8(ascii: ","))
        XCTAssertEqual(punct.text, "，")
        d.insert(punct.text)
        let space = s.space()
        XCTAssertEqual(space.text, ",")
        XCTAssertEqual(space.deleteBefore, 1)
        XCTAssertTrue(space.consumed, "这次空格不该再插一个空格")
    }

    func testPairedPunctuationStepsOver() {
        let (s, d) = withDoc("")
        s.pairPunctuation = true
        let opened = s.punctuate(UInt8(ascii: "("))
        XCTAssertEqual(opened.text, "（）")
        XCTAssertEqual(opened.caretOffset, -1, "光标停在成对标点中间")
        d.insert(opened.text)
        // 模拟光标停在中间：光标前是「（」，光标后是「）」。
        let after = "）"
        s.setLookahead { after.unicodeScalars.first }
        let closed = s.punctuate(UInt8(ascii: ")"))
        XCTAssertEqual(closed.text, "", "右半边已存在时不再写第二个")
        XCTAssertEqual(closed.caretOffset, 1, "只把光标跨过去")
    }

    func testCandidatePinAndRemove() throws {
        let dir = try makeTempDir()
        let e = Engine(dict: buildDict([
            Entry(code: "ni", text: "你", weight: 2500),
            Entry(code: "ni", text: "泥", weight: 100),
        ]))
        let user = UserDict(path: dir.appendingPathComponent("userdict.tsv").path)
        e.setUserDict(user)
        typeKeys(e, "ni")
        XCTAssertEqual(e.candidates.first?.text, "你")
        XCTAssertTrue(e.manage("泥", pin: true))
        XCTAssertEqual(e.candidates.first?.text, "泥", "置顶后按当前编码排最前")
        XCTAssertTrue(e.manage("泥", pin: false))
        XCTAssertNotEqual(e.candidates.first?.text, "泥")
        XCTAssertEqual(user.count, 0)
    }

    func testTypoBonusPrefersCloserKey() {
        // 落点在 a 键中心偏右；把 s 排在 a 右边一格，换到 s 应该加分。
        let e = Engine(dict: nil)
        var frames: [KeyFrame?] = Array(repeating: nil, count: 26)
        for i in 0..<26 { frames[i] = KeyFrame(x: 600, y: 0, width: 40, height: 40) }
        frames[0] = KeyFrame(x: 0, y: 0, width: 40, height: 40)   // a
        frames[Int(UInt8(ascii: "s") - UInt8(ascii: "a"))] = KeyFrame(x: 40, y: 0, width: 40, height: 40)
        e.setKeyFrames(frames)
        e.setTouchPoint(UInt8(ascii: "a"), KeyPoint(x: 60, y: 20))
        XCTAssertGreaterThan(e.typoBonus(UInt8(ascii: "a"), UInt8(ascii: "s")), 0)
    }
}
