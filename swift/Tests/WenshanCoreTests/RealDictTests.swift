import Foundation
import XCTest

@testable import WenshanCore

/// 真实词表上的冒烟测试。dict.bin 是生成物，没有就跳过。
final class RealDictTests: XCTestCase {
    func loadDict() throws -> Dict {
        let candidates = ["../dict.bin", "dict.bin"]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return try Dict(data: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        throw XCTSkip("没有 dict.bin，先跑 sh scripts/build.sh")
    }

    func loadEnglishDict() -> EnglishDict? {
        let candidates = ["../english.bin", "english.bin"]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return try? EnglishDict(data: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        return nil
    }

    func testRealDict() throws {
        let d = try loadDict()
        XCTAssertGreaterThan(d.count, 100_000)

        let e = Engine(dict: d)
        typeKeys(e, "nihk")
        XCTAssertEqual(e.candidates.first?.text, "你好")

        let e2 = Engine(dict: d)
        typeKeys(e2, "womfjixv")
        XCTAssertEqual(e2.candidates.first?.text, "我们继续")

        let e3 = Engine(dict: d)
        typeKeys(e3, "wofaxmv")
        XCTAssertEqual(e3.candidates.first?.text, "我发现这")

        let eYyg = Engine(dict: d)
        typeKeys(eYyg, "yyg")
        XCTAssertEqual(eYyg.candidates.first?.text, "应该")

        let eDgx = Engine(dict: d)
        typeKeys(eDgx, "dgx")
        XCTAssertTrue(
            eDgx.candidates.prefix(3).contains { $0.text == "等下" },
            "dgx 前三名应包含「等下」，实际: \(candidateTexts(eDgx.candidates))")

        let eWof = Engine(dict: d)
        typeKeys(eWof, "wof")
        XCTAssertEqual(eWof.candidates.first?.text, "我方")

        let eDierpy = Engine(dict: d)
        let uDierpy = UserDict(entries: [])
        eDierpy.setUserDict(uDierpy)
        eDierpy.setFreq(Freq())
        typeKeys(eDierpy, "dierpy")
        let dierpyTexts = candidateTexts(eDierpy.candidates)
        XCTAssertTrue(
            dierpyTexts.first == "第二瓶" || dierpyTexts.first == "第二平",
            "dierpy 首位应为「第二瓶」或「第二平」，实际: \(dierpyTexts)")
        let dierIdx = dierpyTexts.firstIndex(of: "第二") ?? Int.max
        let diIdx = dierpyTexts.firstIndex(of: "地") ?? Int.max
        XCTAssertLessThan(dierIdx, diIdx, "「第二」应排在单字「地」之前: \(dierpyTexts)")

        // 先选「第二」再选「评」，下次打 dierpy 应学成自造词并排到首位。
        XCTAssertTrue(eDierpy.select(dierIdx).1)
        guard let pingIdx = eDierpy.candidates.firstIndex(where: { $0.text == "评" }) else {
            return XCTFail("剩余缓冲 py 未给出「评」: \(candidateTexts(eDierpy.candidates))")
        }
        XCTAssertTrue(eDierpy.select(pingIdx).1)
        eDierpy.reset()
        typeKeys(eDierpy, "dierpy")
        XCTAssertEqual(eDierpy.candidates.first?.text, "第二评")

        // 万象词库与静态搭配质量校验。
        for (code, want) in [
            ("lgjyde", "冷静地"),
            ("dlkbvk", "戴口罩"),
            ("fjyyqykd", "反映情况"),
            ("iulejqdm", "出了酒店"),
            ("zodeui", "做的事"),
            ("lgjydeffxi", "冷静地分析"),
        ] {
            let ew = Engine(dict: d)
            typeKeys(ew, code)
            XCTAssertEqual(
                ew.candidates.first?.text, want,
                "\(code) 期望首选「\(want)」，实际: \(candidateTexts(ew.candidates))")
        }

        // 数字后量词提权（1 + ge -> 个）。
        let eDigit = Engine(dict: d)
        let sDigit = Session(eng: eDigit)
        sDigit.setLookbehind { "1" }
        typeKeys(sDigit, "ge")
        XCTAssertEqual(sDigit.candidates.first?.text, "个")

        let e4 = Engine(dict: d)
        if let eng = loadEnglishDict() { e4.setEnglishDict(eng) }
        let s4 = Session(eng: e4)
        _ = s4.shiftLetter(UInt8(ascii: "B"))
        typeKeys(s4, "vj")
        XCTAssertTrue(
            candidateTexts(s4.candidates).contains("B 站"),
            "B + vj 首页应包含「B 站」，实际: \(candidateTexts(s4.candidates))")

        if let eng = loadEnglishDict() {
            for word in ["what", "hello", "world", "string"] {
                let e = Engine(dict: d)
                e.setEnglishDict(eng)
                let s = Session(eng: e)
                typeKeys(s, word)
                XCTAssertEqual(s.candidates.first?.text, word, "期望 \(word) 排在首位")
            }
            for (code, expected) in [("haha", "哈哈"), ("name", "那么"), ("ai", "哎")] {
                let e = Engine(dict: d)
                e.setEnglishDict(eng)
                let s = Session(eng: e)
                typeKeys(s, code)
                XCTAssertEqual(s.candidates.first?.text, expected, "期望中文真词 \(expected) 保持首位")
            }
        }
    }

    /// 只打印耗时，不做断言；release 下跑更接近实际。
    func testPerformance() throws {
        #if DEBUG
        throw XCTSkip("性能用例在 release 下跑：swift test -c release --filter RealDictTests")
        #endif
        let d = try loadDict()
        let freq = Freq(counts: ["一": 3, "我们": 3])
        for keys in ["yi", "nihk", "wofaxmv", "womfjixvuiyi"] {
            let n = 500
            let start = Date()
            for _ in 0..<n {
                let e = Engine(dict: d)
                e.setFreq(freq)
                for b in keys.utf8 {
                    _ = e.type(b)
                    _ = e.hasNextPage()
                }
            }
            let us = Date().timeIntervalSince(start) * 1e6 / Double(n * keys.utf8.count)
            print(String(format: "%@: %.1f µs/key", keys, us))
        }
    }
}
