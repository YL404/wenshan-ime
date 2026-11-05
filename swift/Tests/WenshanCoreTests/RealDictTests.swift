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
