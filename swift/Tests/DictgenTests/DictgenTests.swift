import Foundation
import WenshanCore
import XCTest

@testable import dictgen

final class DictgenTests: XCTestCase {
    /// 辅码表给单字补 2+1 和 2+2 两档，多音字每个读音都补。
    func testAddAux() throws {
        var best: EntryMap = [
            entryKey("ni", "你"): Entry(code: "ni", text: "你", weight: 500),
            entryKey("hk", "好"): Entry(code: "hk", text: "好", weight: 400),
            entryKey("de", "的"): Entry(code: "de", text: "的", weight: 300),
            entryKey("di", "的"): Entry(code: "di", text: "的", weight: 200),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aux-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("# 注释\r\n\r\n你=rx\r\n好=nz\r\n的=bu\r\n缺=zz\r\n".utf8).write(to: url)

        let n = try addAux(url.path, into: &best)
        let want = [
            Entry(code: "nir", text: "你", weight: 500),
            Entry(code: "nirx", text: "你", weight: 500),
            Entry(code: "hkn", text: "好", weight: 400),
            Entry(code: "hknz", text: "好", weight: 400),
            Entry(code: "deb", text: "的", weight: 300),
            Entry(code: "debu", text: "的", weight: 300),
            Entry(code: "dib", text: "的", weight: 300),
            Entry(code: "dibu", text: "的", weight: 300),
        ]
        XCTAssertEqual(n, want.count)
        for w in want {
            XCTAssertEqual(best[entryKey(w.code, w.text)], w, "\(w.code) \(w.text)")
        }
        XCTAssertNil(best[entryKey("zz", "缺")], "词库里没有「缺」，不该加辅码")
    }

    /// Rime 表头到 ... 为止；正文按「词条<TAB>拼音<TAB>权重」转成自然码，
    /// 同一编码同一词条取较高权重，Windows 换行也能切开。
    func testLoadRime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rime-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "# 注释\r\n---\r\nname: test\r\n...\r\n你好\tni hao\t100\r\n你好\tni hao\t300\r\n"
            + "居\tju\t50\r\n坏行\r\n"
        try Data(text.utf8).write(to: url)

        var best: EntryMap = [:]
        XCTAssertEqual(try loadRime(url.path, into: &best), 3)
        XCTAssertEqual(best[entryKey("nihk", "你好")]?.weight, 300)
        // j 后的 u 是 ü：规范写法 jv，另收照拼音写的 ju。
        XCTAssertEqual(best[entryKey("jv", "居")]?.weight, 50)
        XCTAssertEqual(best[entryKey("ju", "居")]?.weight, 50)
    }
}
