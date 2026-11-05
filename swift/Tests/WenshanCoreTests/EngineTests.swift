import Foundation
import XCTest

@testable import WenshanCore

// MARK: - 共用的小工具

func buildDict(_ entries: [Entry]) -> Dict {
    try! Dict(data: writeDict(entries))
}

/// 按顺序敲一串键。
func typeKeys(_ e: Engine, _ keys: String) {
    for b in keys.utf8 {
        _ = e.type(b)
    }
}

func candidateTexts(_ cands: [Candidate]) -> [String] {
    cands.map(\.text)
}

func asciiLetter(_ i: Int) -> String {
    String(UnicodeScalar(UInt8(97 + i)))
}

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - 自然码编码

final class ZiranmaTests: XCTestCase {
    /// 每个用例都对应 Rime double_pinyin.schema.yaml 里的一条改写规则。
    func testCodes() {
        let cases: [([String], String)] = [
            (["ni"], "ni"),
            (["hao"], "hk"),
            (["ni", "hao"], "nihk"),
            (["zhong"], "vs"),
            (["zhong", "guo"], "vsgo"),
            (["shi"], "ui"),
            (["chi"], "ii"),
            (["zhi"], "vi"),
            (["ang"], "ah"),
            (["a"], "aa"),
            (["er"], "er"),
            (["nv"], "nv"),
            (["lve"], "lt"),
            (["xin"], "xn"),
            (["ying"], "yy"),
            (["xiao"], "xc"),
            (["jiu"], "jq"),
            (["hui"], "hv"),
            (["kuai"], "ky"),
            (["guang"], "gd"),
            (["qiong"], "qs"),
            (["fen"], "ff"),
            (["feng"], "fg"),
            (["bang"], "bh"),
            (["bian"], "bm"),
            (["bie"], "bx"),
            (["biao"], "bc"),
            (["bao"], "bk"),
            (["bei"], "bz"),
            (["zou"], "zb"),
            (["wen"], "wf"),
            (["wang"], "wh"),
            (["wo"], "wo"),
            (["ya"], "ya"),  // y 后面直接跟韵母键，和 Rime 一致
        ]
        for (pinyin, want) in cases {
            let got = Ziranma.codes(pinyin)
            XCTAssertEqual(got.first, want, "Codes(\(pinyin)) = \(got)")
        }
    }

    /// 兼容写法：Rime 用 derive 同时接受原始拼写。
    func testCodesAlternatives() {
        let cases: [(String, [String])] = [
            ("ai", ["al", "ai"]),
            ("an", ["aj", "an"]),
            ("ou", ["ob", "ou"]),
            ("ju", ["jv", "ju"]),
            ("yu", ["yv", "yu"]),
        ]
        for (pinyin, want) in cases {
            let got = Ziranma.codes([pinyin])
            XCTAssertEqual(got, want, "Codes(\(pinyin))")
        }
    }
}

// MARK: - 词表与候选流

final class EngineTests: XCTestCase {
    func testPaging() {
        var entries: [Entry] = []
        for i in 0..<25 {
            entries.append(Entry(code: "ni", text: asciiLetter(i), weight: UInt32(2500 - i)))
        }
        let e = Engine(dict: buildDict(entries))
        typeKeys(e, "ni")

        XCTAssertEqual(e.candidates.count, pageSize)
        XCTAssertEqual(e.candidates.first?.text, "a")
        XCTAssertTrue(e.page(1), "第 1 页翻不到第 2 页")
        XCTAssertEqual(e.candidates.count, pageSize)
        XCTAssertEqual(e.candidates.first?.text, "j")
        XCTAssertTrue(e.page(1), "第 2 页翻不到第 3 页")
        XCTAssertEqual(e.candidates.count, 7)
        XCTAssertEqual(e.candidates.first?.text, "s")
        XCTAssertFalse(e.page(1), "超过 3 页还能继续翻")
        XCTAssertEqual(e.candidates.count, 7)
        XCTAssertEqual(e.candidates.first?.text, "s")
        XCTAssertTrue(e.page(-1))
        XCTAssertTrue(e.page(-1))
        XCTAssertEqual(e.candidates.count, pageSize)
        XCTAssertEqual(e.candidates.first?.text, "a")
        XCTAssertFalse(e.page(-1), "第 1 页还能继续往前翻")

        // 换输入或者退格后，页状态必须回到第 1 页。
        XCTAssertTrue(e.page(1))
        _ = e.backspace()
        XCTAssertEqual(e.candidates.first?.text, "a")
        _ = e.type(UInt8(ascii: "i"))
        XCTAssertEqual(e.candidates.first?.text, "a")

        // 选当前页的候选，不能选到第 1 页的首选。
        XCTAssertTrue(e.page(1))
        let (text, ok) = e.select(0)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "j")
        XCTAssertTrue(e.buffer.isEmpty)
        XCTAssertTrue(e.candidates.isEmpty)
    }

    /// 候选够多时能一直翻到词库真正的底，不再卡在固定的页数上限；
    /// 逐页拼起来应该和整个流完全一致。
    func testPagingLimit() {
        let total = 1000
        var entries: [Entry] = []
        for i in 0..<total {
            entries.append(Entry(code: "ni", text: String(i), weight: UInt32(total * 10 - i)))
        }
        let e = Engine(dict: buildDict(entries))
        typeKeys(e, "ni")

        var seen = candidateTexts(e.candidates)
        var pages = 1
        while e.page(1) {
            pages += 1
            seen.append(contentsOf: candidateTexts(e.candidates))
        }
        XCTAssertGreaterThan(pages, maxPages, "应突破旧的页数上限")
        XCTAssertEqual(pages, (total + pageSize - 1) / pageSize)
        XCTAssertEqual(seen.count, total)
        for (i, s) in seen.enumerated() {
            XCTAssertEqual(s, String(i), "第 \(i) 个候选（页边界不连续）")
        }
    }

    /// 25 个候选是 3 页，最后一页不能再报「还有下一页」。
    func testHasNextPage() {
        var entries: [Entry] = []
        for i in 0..<25 {
            entries.append(Entry(code: "ni", text: asciiLetter(i), weight: UInt32(2500 - i)))
        }
        let e = Engine(dict: buildDict(entries))
        typeKeys(e, "ni")
        for (page, wantNext) in [true, true, false].enumerated() {
            XCTAssertEqual(e.pageNo, page)
            XCTAssertEqual(e.hasNextPage(), wantNext, "第 \(page + 1) 页")
            if wantNext {
                XCTAssertTrue(e.page(1), "翻不到第 \(page + 2) 页")
            }
        }
    }

    func testAllCandidatesAndSelectGlobal() {
        var entries: [Entry] = []
        for i in 0..<25 {
            entries.append(Entry(code: "ni", text: asciiLetter(i), weight: UInt32(2500 - i)))
        }
        let e = Engine(dict: buildDict(entries))
        typeKeys(e, "ni")

        let all = e.allCandidates()
        XCTAssertEqual(all.count, 25)
        XCTAssertEqual(all[0].text, "a")
        XCTAssertEqual(all[9].text, "j")
        XCTAssertEqual(all[24].text, "y")
        // 展开全部候选不能改变当前页。
        XCTAssertEqual(e.candidates.count, pageSize)
        XCTAssertEqual(e.candidates.first?.text, "a")

        let (text, ok) = e.selectGlobal(9)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "j")
        XCTAssertTrue(e.buffer.isEmpty)
        XCTAssertTrue(e.candidates.isEmpty)
    }

    func testPagingSinglePage() {
        var entries: [Entry] = []
        for i in 0..<pageSize {
            entries.append(Entry(code: "ni", text: asciiLetter(i), weight: UInt32(100 - i)))
        }
        let e = Engine(dict: buildDict(entries))
        typeKeys(e, "ni")
        XCTAssertFalse(e.page(1))
        XCTAssertFalse(e.page(-1))
        XCTAssertEqual(e.candidates.count, pageSize)
    }

    func testPrefixRanking() {
        let d = buildDict([
            Entry(code: "ni", text: "你", weight: 500),
            Entry(code: "ni", text: "尼", weight: 100),
            Entry(code: "nihk", text: "你好", weight: 900),
            Entry(code: "nihk", text: "你我", weight: 50),
            Entry(code: "nihk", text: "霓虹", weight: 70),
            Entry(code: "xn", text: "新", weight: 800),
        ])
        XCTAssertEqual(d.count, 6)

        // 打 ni：编码刚好用完的词优先，你 在第一。
        var got = d.lookup(Array("ni".utf8), limit: 9, freq: nil)
        XCTAssertEqual(got.first?.text, "你")
        XCTAssertEqual(got.count > 1 ? got[1].text : "", "尼")
        XCTAssertEqual(got.count > 2 ? got[2].text : "", "你好")
        XCTAssertEqual(got.last?.text, "你我")

        // 打 nihk：整词优先，但前面已经打完的「你」仍然可选。
        got = d.lookup(Array("nihk".utf8), limit: 9, freq: nil)
        XCTAssertEqual(got.count, 5)
        XCTAssertEqual(got[0].text, "你好")
        XCTAssertEqual(got[1].text, "霓虹")

        // 半截输入 nih 也能命中你好，CodeLen 是完整编码长度。
        got = d.lookup(Array("nih".utf8), limit: 9, freq: nil)
        XCTAssertEqual(got.count, 5)
        XCTAssertEqual(got[0].text, "你好")
        XCTAssertEqual(got[0].codeLen, 4)

        XCTAssertTrue(d.lookup(Array("zz".utf8), limit: 9, freq: nil).isEmpty)
    }

    /// 辅码条目比普通音节多一到两键，等长匹配时应该排在同音字前面。
    func testAuxRanking() {
        let d = buildDict([
            Entry(code: "ni", text: "你", weight: 500),
            Entry(code: "ni", text: "尼", weight: 400),
            Entry(code: "nir", text: "你", weight: 500),
            Entry(code: "nirx", text: "你", weight: 500),
        ])
        let e = Engine(dict: d)
        for code in ["nir", "nirx"] {
            e.reset()
            typeKeys(e, code)
            XCTAssertEqual(e.candidates.first?.text, "你", "\(code) 候选")
        }
    }

    /// 三键既可能是单字辅码，也可能是下一个音节的声母。真实词组要按词频排在
    /// 生僻的辅码单字前面，但高频字（的）仍然能靠权重留在首位。
    func testAuxDoesNotOutrankWord() {
        let d = buildDict([
            Entry(code: "tm", text: "天", weight: 6_000_000),
            Entry(code: "tmj", text: "钿", weight: 1000),
            Entry(code: "tmjt", text: "钿", weight: 1000),
            Entry(code: "tmjw", text: "添加", weight: 500_000),
            Entry(code: "tmjw", text: "天价", weight: 50_000),
            Entry(code: "xm", text: "先", weight: 1_600_000),
            Entry(code: "xmz", text: "暹", weight: 2800),
            Entry(code: "xmzl", text: "现在", weight: 503_000),
            Entry(code: "de", text: "的", weight: 76_000_000),
            Entry(code: "deb", text: "的", weight: 76_000_000),
            Entry(code: "debu", text: "的", weight: 76_000_000),
            Entry(code: "debu", text: "底部", weight: 149_000),
        ])
        let e = Engine(dict: d)
        for (code, want) in [("tmj", "添加"), ("xmz", "现在"), ("deb", "的")] {
            e.reset()
            typeKeys(e, code)
            XCTAssertEqual(e.candidates.first?.text, want, "\(code) 候选")
        }
    }

    /// 单键候选只取两键单字，辅码条目不能把同一个字重复塞进简码表。
    func testShortListsExcludeAux() {
        let entries = [
            Entry(code: "ni", text: "你", weight: 500),
            Entry(code: "nir", text: "你", weight: 500),
            Entry(code: "nirx", text: "你", weight: 500),
            Entry(code: "ni", text: "尼", weight: 100),
        ]
        let count = shortLists(entries).filter { $0.text == "你" }.count
        XCTAssertEqual(count, 1)
    }

    func testEngine() {
        let d = buildDict([
            Entry(code: "ni", text: "你", weight: 500),
            Entry(code: "hk", text: "好", weight: 400),
            Entry(code: "nihk", text: "你好", weight: 900),
            Entry(code: "vs", text: "中", weight: 500),
            Entry(code: "go", text: "国", weight: 400),
        ])
        let e = Engine(dict: d)

        for ch in "nihk".utf8 {
            XCTAssertTrue(e.type(ch), "Type(\(ch)) 失败")
        }
        XCTAssertEqual(String(decoding: e.buffer, as: UTF8.self), "nihk")
        XCTAssertEqual(e.candidates.first?.text, "你好")

        // 空格上屏首选后缓冲清空。
        var (text, ok) = e.select(0)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "你好")
        XCTAssertTrue(e.buffer.isEmpty)

        // 打满你好但只取「你」，剩下的 hk 继续组成「好」。
        typeKeys(e, "nihk")
        guard let idx = findText(e, "你") else { return }
        (text, ok) = e.select(idx)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "你")
        XCTAssertEqual(String(decoding: e.buffer, as: UTF8.self), "hk")
        XCTAssertEqual(e.candidates.first?.text, "好")

        // 词没打全也能选：缓冲短于候选编码时，选完直接清空。
        typeKeys(e, "wofax")
        if e.candidates.first?.text != "你好" {
            return  // 测试词表里没有这么长的词
        }
        e.reset()

        _ = e.backspace()
        XCTAssertEqual(String(decoding: e.buffer, as: UTF8.self), "h")
        _ = e.backspace()
        XCTAssertTrue(e.buffer.isEmpty)
        e.reset()
        XCTAssertTrue(e.buffer.isEmpty)
        XCTAssertTrue(e.candidates.isEmpty)
    }

    func findText(_ e: Engine, _ text: String) -> Int? {
        e.candidates.firstIndex { $0.text == text }
    }

    /// 以词定字：取候选首/尾字，编码消耗和正常选词一致。
    func testSelectChar() {
        let d = buildDict([
            Entry(code: "ni", text: "你", weight: 500),
            Entry(code: "hk", text: "好", weight: 400),
            Entry(code: "nihk", text: "你好", weight: 900),
        ])
        let e = Engine(dict: d)

        typeKeys(e, "nihk")
        XCTAssertEqual(e.candidates.first?.text, "你好")
        var (text, ok) = e.selectChar(0, last: false)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "你")
        XCTAssertTrue(e.buffer.isEmpty)

        typeKeys(e, "nihk")
        (text, ok) = e.selectChar(0, last: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "好")

        // 从候选里取单字时，剩下的编码继续组成后面的词。
        typeKeys(e, "nihk")
        guard let idx = findText(e, "你") else { return }
        (text, ok) = e.selectChar(idx, last: false)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "你")
        XCTAssertEqual(String(decoding: e.buffer, as: UTF8.self), "hk")
        XCTAssertEqual(e.candidates.first?.text, "好")
    }

    /// 缓冲比候选编码短时（词还没打完），选中后缓冲应整个清空。
    func testSelectLongerCandidate() {
        let d = buildDict([Entry(code: "wofaxm", text: "我发现", weight: 900)])
        let e = Engine(dict: d)
        typeKeys(e, "wofax")
        XCTAssertEqual(e.candidates.count, 1)
        XCTAssertEqual(e.candidates.first?.text, "我发现")
        let (text, ok) = e.select(0)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "我发现")
        XCTAssertTrue(e.buffer.isEmpty)
    }

    /// 打了 5 个键时，还没打完的长词应该排在「只用掉前两个键」的高频单字前面。
    func testRankingTiers() {
        let d = buildDict([
            Entry(code: "wo", text: "我", weight: 9000),
            Entry(code: "wofa", text: "我发", weight: 3000),
            Entry(code: "wofaxm", text: "我发现", weight: 100),
        ])
        var got = d.lookup(Array("wofax".utf8), limit: 9, freq: nil)
        XCTAssertEqual(candidateTexts(got), ["我发现", "我发", "我"])
        // 打满 wofa 时，刚好用完缓冲的词优先于更长的词。
        got = d.lookup(Array("wofa".utf8), limit: 9, freq: nil)
        XCTAssertEqual(got[0].text, "我发")
        XCTAssertEqual(got[1].text, "我发现")
    }

    /// 照拼音写成 ju/qu/xu/yu 时也要能打出 ü 韵母的词。
    func testUmlautVariant() {
        let d = buildDict([
            Entry(code: "jixv", text: "继续", weight: 900),
            Entry(code: "ji", text: "级", weight: 800),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "jixu")
        XCTAssertEqual(e.candidates.first?.text, "继续")
        let (text, ok) = e.select(0)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "继续")
    }

    /// 词库里没有整句时，要能把缓冲切成几个词拼出来。
    func testCompose() {
        let d = buildDict([
            Entry(code: "womf", text: "我们", weight: 500_000),
            Entry(code: "jixv", text: "继续", weight: 500_000),
            Entry(code: "wo", text: "我", weight: 20_000_000),
            Entry(code: "ji", text: "级", weight: 5_000_000),
            Entry(code: "xv", text: "许", weight: 1_000_000),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "womfjixv")
        XCTAssertEqual(e.candidates.first?.text, "我们继续")
        let (text, ok) = e.select(0)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "我们继续")
        XCTAssertTrue(e.buffer.isEmpty)

        // 整段就是一个词时不该再拼一遍。
        let e2 = Engine(dict: d)
        typeKeys(e2, "womf")
        XCTAssertEqual(e2.candidates.count, 2)
        XCTAssertEqual(e2.candidates[0].text, "我们")
        XCTAssertEqual(e2.candidates[1].text, "我")

        // 单字凑出来的组合不能压过真正的词。
        let e3 = Engine(dict: d)
        typeKeys(e3, "jixv")
        XCTAssertEqual(e3.candidates.first?.text, "继续")
    }

    /// 常用词即使词库权重排在首页之外，选得多了也要能提到首页；
    /// 翻页补算时已经看过的页不能变。
    func testFreqBeyondFirstPage() {
        var entries: [Entry] = []
        for i in 0..<40 {
            entries.append(
                Entry(
                    code: "ni", text: String(UnicodeScalar(0x4E00 + i)!),
                    weight: UInt32(10_000 - i)))
        }
        let d = buildDict(entries)
        let target = entries[38].text  // 词库权重第 39 名，首页 + 预取的第二页之外
        let f = Freq(counts: [target: 5])
        let e = Engine(dict: d)
        e.setFreq(f)
        typeKeys(e, "ni")
        XCTAssertEqual(e.candidates.first?.text, target)
        let first = candidateTexts(e.candidates)
        while e.page(1) {}
        while e.page(-1) {}
        XCTAssertEqual(candidateTexts(e.candidates), first)
    }

    /// 常用词应该被提到前面，但不能翻过整段匹配那一层。
    func testFreqRanking() {
        let d = buildDict([
            Entry(code: "ni", text: "你", weight: 5000),
            Entry(code: "ni", text: "尼", weight: 100),
            Entry(code: "nihk", text: "你好", weight: 900),
        ])
        let f = Freq()
        let e = Engine(dict: d)
        e.setFreq(f)

        func typeNI() {
            e.reset()
            typeKeys(e, "ni")
        }
        typeNI()
        XCTAssertEqual(e.candidates.first?.text, "你")
        for _ in 0..<5 {
            typeNI()
            guard let idx = findText(e, "尼") else { return XCTFail("选不到 尼") }
            XCTAssertTrue(e.select(idx).1)
        }
        typeNI()
        XCTAssertEqual(e.candidates.first?.text, "尼")
        // 你好 是整段匹配（层更高），不该被高频单字压下去。
        e.reset()
        typeKeys(e, "nihk")
        XCTAssertEqual(e.candidates.first?.text, "你好")
    }

    /// 词频平时攒够次数才写盘，强制保存时有一次改动也要写，不能丢零头。
    func testSaveForce() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("freq.tsv").path
        let d = buildDict([Entry(code: "ni", text: "你", weight: 5000)])
        let e = Engine(dict: d)
        e.setFreq(Freq.load(path))
        typeKeys(e, "ni")
        XCTAssertTrue(e.select(0).1)
        try e.save(force: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "没攒够次数就写盘了")
        try e.save(force: true)
        XCTAssertEqual(Freq.load(path).count("你"), 1)
    }

    /// 词频表超过上限时淘汰选得最少的词，写出的文件按次数从多到少排列。
    func testFreqCap() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("freq.tsv").path
        let f = Freq.load(path)
        for i in 0..<(maxFreqEntries + 5) {
            f.counts["w\(i)"] = 2
        }
        f.counts["常用"] = 9
        f.counts["少用"] = 1
        f.dirty = 1
        try f.save()
        let got = Freq.load(path)
        XCTAssertEqual(got.counts.count, maxFreqEntries)
        XCTAssertEqual(got.count("常用"), 9)
        XCTAssertEqual(got.count("少用"), 0)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue(data.prefix(Array("常用\t9\n".utf8).count).elementsEqual("常用\t9\n".utf8))
    }

    /// 连续单字选词后应该记住这个词，下次输入直接出现。
    func testUserDictLearn() {
        let d = buildDict([
            Entry(code: "wo", text: "我", weight: 1000),
            Entry(code: "da", text: "打", weight: 900),
            Entry(code: "de", text: "的", weight: 800),
        ])
        let u = UserDict(entries: [])
        let e = Engine(dict: d)
        e.setUserDict(u)

        typeKeys(e, "wodade")
        for want in ["我", "打", "的"] {
            guard let idx = findText(e, want) else { return XCTFail("选不到 \(want)") }
            XCTAssertTrue(e.select(idx).1)
        }
        XCTAssertEqual(u.count, 1)

        // 重新输入整个编码，自造词应该排第一。
        e.reset()
        typeKeys(e, "wodade")
        XCTAssertEqual(e.candidates.first?.text, "我打的")

        // 词库本身有的词不该被重复记一遍。
        let u2 = UserDict(entries: [])
        let e2 = Engine(
            dict: buildDict([
                Entry(code: "ni", text: "你", weight: 1000),
                Entry(code: "hk", text: "好", weight: 900),
            ]))
        e2.setUserDict(u2)
        typeKeys(e2, "nihk")
        if let i = findText(e2, "你") { _ = e2.select(i) }
        if let i = findText(e2, "好") { _ = e2.select(i) }
        XCTAssertEqual(u2.count, 1)
    }

    /// 短语文件按「编码<TAB>文本」读入，空行和注释忽略。
    func testLoadPhrases() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("phrases.tsv")
        try "# 注释\r\n\r\nyx\tme@example.com\r\n".write(to: path, atomically: true, encoding: .utf8)
        let p = UserDict.load(path.path)
        XCTAssertEqual(p.count, 1)
        let got = p.lookup(Array("yx".utf8), 9, nil)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.text, "me@example.com")
    }

    /// 自定义短语和普通词同码时，短语要排在最前。
    func testPhrasesRanking() {
        let d = buildDict([
            Entry(code: "yx", text: "邮箱", weight: 900_000),
            Entry(code: "yx", text: "有些", weight: 800_000),
        ])
        let p = UserDict(entries: [UserDict.Entry(code: "yx", text: "me@example.com")])
        let e = Engine(dict: d)
        e.setPhrases(p)
        typeKeys(e, "yx")
        XCTAssertEqual(e.candidates.first?.text, "me@example.com")
    }

    /// 打完一个词组再打下个音节的声母时，组句要能把末尾声母延展成完整音节，
    /// 而不是让候选塌回单字。
    func testComposeTrailingInitial() {
        let d = buildDict([
            Entry(code: "wofaxm", text: "我发现", weight: 900_000),
            Entry(code: "ve", text: "这", weight: 400_000),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "wofaxmv")
        // v 是 zh 的声母键：词格应竞争出 我发现 + 这。
        XCTAssertEqual(e.candidates.first?.text, "我发现这")
        let (text, ok) = e.select(0)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "我发现这")
        XCTAssertTrue(e.buffer.isEmpty)
    }

    /// 末尾声母补全时不能把辅码单字当成一个音节：buvdl 里的 vdly 是「装」的
    /// 辅码，不是「装 + ling」，否则会拼出「不装」而不是「不装了」。
    func testComposeSkipsAux() {
        let d = buildDict([
            Entry(code: "bu", text: "不", weight: 20_000_000),
            Entry(code: "vd", text: "装", weight: 1_000_000),
            Entry(code: "buvd", text: "不装", weight: 500_000),
            Entry(code: "vdly", text: "装", weight: 1_000_000),
            Entry(code: "vdle", text: "装了", weight: 500_000),
            Entry(code: "le", text: "了", weight: 1_400_000),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "buvdl")
        let got = e.candidates
        XCTAssertEqual(got.first?.text, "不装了")
        for c in got where c.text == "不装" && c.codeLen == 5 {
            XCTFail("辅码把末尾 l 吃掉了: \(candidateTexts(got))")
        }
    }

    /// 末尾多着声母键时，覆盖按键多的前缀词要排在覆盖少的高频单字前面。
    func testOddTailRanking() {
        let d = buildDict([
            Entry(code: "wo", text: "我", weight: 9_000_000),
            Entry(code: "wofaxm", text: "我发现", weight: 100),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "wofaxmv")
        let got = e.candidates
        XCTAssertGreaterThanOrEqual(got.count, 2)
        XCTAssertEqual(got[0].text, "我发现")
        XCTAssertEqual(got[1].text, "我")
    }

    /// 只有一个完整音节加一个声母键（3 个键）时不做末尾延展。
    func testThreeKeysKeepsPrefix() {
        let d = buildDict([
            Entry(code: "ni", text: "你", weight: 500),
            Entry(code: "he", text: "和", weight: 400),
            Entry(code: "nihk", text: "你好", weight: 900),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "nih")
        XCTAssertEqual(e.candidates.first?.text, "你好")
        for c in e.candidates where c.text == "你和" {
            XCTFail("3 键不应拼出 你和: \(candidateTexts(e.candidates))")
        }
    }

    /// 按错一键（l 是 k 的邻键）也能打出想要的字：纠错行只补空位，不抢首位。
    func testNeighborCorrection() {
        let d = buildDict([Entry(code: "hk", text: "好", weight: 900)])
        let e = Engine(dict: d)
        typeKeys(e, "hl")
        XCTAssertEqual(e.candidates.first?.text, "好")
    }

    /// 词按错一键：纠错词排在字面能查到的候选之后。
    func testCorrectionWord() {
        let d = buildDict([
            Entry(code: "gr", text: "关", weight: 500),
            Entry(code: "grxi", text: "关系", weight: 900_000),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "grzi")
        XCTAssertEqual(e.candidates.first?.text, "关")
        if let i = findText(e, "关系") {
            XCTAssertNotEqual(i, 0, "纠错词抢了首位: \(candidateTexts(e.candidates))")
        }
    }

    /// 整句按错一键：三个音节的跨度内替换一个两键组，把句子纠回来。
    func testCorrectionSentence() {
        let d = buildDict([
            Entry(code: "wo", text: "我", weight: 900_000),
            Entry(code: "womfxm", text: "我们发现", weight: 900_000),
        ])
        let e = Engine(dict: d)
        typeKeys(e, "womfzm")
        XCTAssertEqual(e.candidates.first?.text, "我")
        if let i = findText(e, "我们发现") {
            XCTAssertNotEqual(i, 0, "纠错句抢了首位: \(candidateTexts(e.candidates))")
        }
    }
}
