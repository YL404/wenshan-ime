import Foundation

/// 按错一键的邻键纠错：把缓冲按两键组切分，其中恰好一个组被 QWERTY 邻键
/// 或对调变体替换，替换后的词必须真的在词库里。候选挂在 tierTypo 层，只补
/// 正常候选剩下的空位，永远不抢首位。
///
/// 纠错跨度最多 3 个音节：更长的词组让词格拆成小段补，每条纠错边最多替换
/// 一个两键组——漏键和多键不做，那要换一套打错的模型。

/// 一条纠错替换边的额外罚分。只影响多条纠错路径之间选哪条，因为 tierTypo
/// 已经把纠错候选压到正常候选之后。
let typoPenalty = 10.0

/// QWERTY 键盘的邻键，含斜角：打错一键多半落在这些键上。
/// 按字母顺序索引（a...z），不是键盘顺序。
let neighbors: [[UInt8]] = [
    Array("qwsz".utf8),  // a
    Array("gvhn".utf8),  // b
    Array("dfxv".utf8),  // c
    Array("esrfxc".utf8),  // d
    Array("wrsd".utf8),  // e
    Array("rdtgcv".utf8),  // f
    Array("tyfhvb".utf8),  // g
    Array("yugjbn".utf8),  // h
    Array("uojk".utf8),  // i
    Array("uihknm".utf8),  // j
    Array("iojlm".utf8),  // k
    Array("opk".utf8),  // l
    Array("njkl".utf8),  // m
    Array("hjbm".utf8),  // n
    Array("ipkl".utf8),  // o
    Array("ol".utf8),  // p
    Array("wa".utf8),  // q
    Array("etdf".utf8),  // r
    Array("awedzx".utf8),  // s
    Array("ryfg".utf8),  // t
    Array("yihj".utf8),  // u
    Array("fgcb".utf8),  // v
    Array("qeas".utf8),  // w
    Array("sdzc".utf8),  // x
    Array("tugh".utf8),  // y
    Array("asx".utf8),  // z
]

/// 返回一个两键组的全部纠错写法：两键各自换成邻键，加上两键对调。
/// 不含原组，也不含重复。
func groupVariants(_ group: [UInt8]) -> [[UInt8]] {
    guard group.count == 2,
          group[0] >= UInt8(ascii: "a"), group[0] <= UInt8(ascii: "z"),
          group[1] >= UInt8(ascii: "a"), group[1] <= UInt8(ascii: "z")
    else { return [] }
    var out: [[UInt8]] = []
    func add(_ a: UInt8, _ b: UInt8) {
        if a == group[0] && b == group[1] { return }
        if out.contains(where: { $0[0] == a && $0[1] == b }) { return }
        out.append([a, b])
    }
    for i in 0..<2 {
        for n in neighbors[Int(group[i] - UInt8(ascii: "a"))] {
            if i == 0 {
                add(n, group[1])
            } else {
                add(group[0], n)
            }
        }
    }
    if group[0] != group[1] {
        add(group[1], group[0])
    }
    return out
}

extension Dict {
    /// 返回按错一键的纠错候选：整段缓冲切成两键组，其中恰好一个组被变体替换。
    /// touchBonus 由调用方按真实落点给「按到的键 → 想打的键」打分，
    /// 只影响纠错路径之间的先后，不越过正常候选。
    func corrections(
        _ buf: [UInt8], _ limit: Int,
        touchBonus: ((UInt8, UInt8) -> Double)? = nil
    ) -> [Candidate] {
        guard buf.count >= 2, buf.count % 2 == 0, n > 0, limit > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            correctionsRaw(raw, buf, limit, touchBonus)
        }
    }

    func correctionsRaw(
        _ raw: UnsafeRawBufferPointer, _ buf: [UInt8], _ limit: Int,
        _ touchBonus: ((UInt8, UInt8) -> Double)?
    ) -> [Candidate] {
        let syls = buf.count / 2

        // best[t][i]：前 i 个音节、是否用过纠错替换（t=1）的最优分。
        // 纠错边只从 t=0 跨到 t=1，所以每条路径最多替换一个两键组。
        var best = [[Double]](
            repeating: [Double](repeating: -Double.infinity, count: syls + 1), count: 2)
        var prev = [[Int]](repeating: [Int](repeating: -1, count: syls + 1), count: 2)
        var prevCode = [[[UInt8]?]](
            repeating: [[UInt8]?](repeating: nil, count: syls + 1), count: 2)
        var touchScores = [[Double]](
            repeating: [Double](repeating: 0, count: syls + 1), count: 2)
        best[0][0] = 0

        for i in 0..<syls {
            // exact 边：和组句一样，任何长度的段；不改变「是否用过纠错」。
            var j = i + 1
            while j <= syls && j - i <= maxWordSyllables {
                let (w, found) = exactWeight(raw, Array(buf[(i * 2)..<(j * 2)]))
                if found {
                    let edge = log(Double(w) + 1) - segmentPenalty
                    for t in 0...1 where best[t][i] != -Double.infinity {
                        let s = best[t][i] + edge
                        if s > best[t][j] {
                            best[t][j] = s
                            prev[t][j] = i
                            prevCode[t][j] = nil
                        }
                    }
                }
                j += 1
            }
            // 纠错边：跨度最多 3 个音节，每条边恰好替换一个两键组，罚分更高。
            if best[0][i] == -Double.infinity { continue }
            var j2 = i + 1
            while j2 <= syls && j2 - i <= 3 {
                for p in i..<j2 {
                    for v in groupVariants(Array(buf[(p * 2)..<(p * 2 + 2)])) {
                        var code: [UInt8] = []
                        code.append(contentsOf: buf[(i * 2)..<(p * 2)])
                        code.append(contentsOf: v)
                        code.append(contentsOf: buf[((p + 1) * 2)..<(j2 * 2)])
                        let (w, found) = exactWeight(raw, code)
                        if !found { continue }
                        var bonus = 0.0
                        if let touchBonus {
                            let original = buf[(p * 2)..<(p * 2 + 2)]
                            if original[original.startIndex] != v[0] {
                                bonus += touchBonus(original[original.startIndex], v[0])
                            }
                            if original[original.startIndex + 1] != v[1] {
                                bonus += touchBonus(original[original.startIndex + 1], v[1])
                            }
                        }
                        let s = best[0][i] + log(Double(w) + 1) - segmentPenalty - typoPenalty + bonus
                        if s > best[1][j2] {
                            best[1][j2] = s
                            prev[1][j2] = i
                            prevCode[1][j2] = code
                            touchScores[1][j2] = bonus
                        }
                    }
                }
                j2 += 1
            }
        }

        guard best[1][syls] != -Double.infinity else { return [] }

        // 回溯：从终点往回走。遇到纠错边（编码非 nil）就切回 noTypo 状态，
        // 之前的路径全部没用过纠错，所以恰好有一条纠错边。
        struct Span {
            var start: Int
            var end: Int
            var code: [UInt8]?
        }
        var path: [Span] = []
        var i = syls
        var t = 1
        while i > 0 {
            let code = prevCode[t][i]
            let start = prev[t][i]
            path.append(Span(start: start, end: i, code: code))
            i = start
            if code != nil { t = 0 }
        }
        path.reverse()

        // 每段的同音备选：普通段直接取 buf 切片；纠错段用替换后的编码。
        var alts: [[AltText]] = []
        alts.reserveCapacity(path.count)
        for span in path {
            let code = span.code ?? Array(buf[(span.start * 2)..<(span.end * 2)])
            let a = exactAlts(raw, code, altPerSegment)
            if a.isEmpty { return [] }
            alts.append(a)
        }

        var out: [Candidate] = []
        func emit(_ override: Int, _ alt: AltText) {
            var bytes: [UInt8] = []
            var sum = 0.0
            for k in path.indices {
                let a = k == override ? alt : alts[k][0]
                bytes.append(contentsOf: a.text.utf8)
                sum += log(Double(a.weight) + 1)
            }
            // 折算回「单个词」的权重量级，再扣一条纠错罚分；tierTypo 把
            // 纠错候选压到正常候选之后，权重只决定纠错行之间的顺序。
            let w = exp(
                sum - segmentPenalty * Double(path.count) - typoPenalty
                    + segmentPenalty + touchScores[1][syls]) - 1
            let text = String(decoding: bytes, as: UTF8.self)
            out = insertCandidate(
                out,
                Candidate(text, buf.count, Int64(tierTypo) << 40 | Int64(clampWeight(w))),
                limit)
        }
        emit(-1, AltText(text: "", weight: 0))
        for k in path.indices {
            for alt in alts[k].dropFirst() {
                emit(k, alt)
            }
        }
        return out
    }
}
