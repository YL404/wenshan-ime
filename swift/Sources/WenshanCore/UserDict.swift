import Foundation

/// 自造词的排序权重。用户明确教过的词，层内直接排最前，但要低于「整段
/// 匹配」那一层，所以只放在权重区。
let userWeight: UInt32 = 1_000_000_000
/// 候选菜单置顶的词权重更高，排在普通自造词之前。
let pinnedWeight: UInt32 = 1_500_000_000

/// 用户自造词表：编码 + 词。数量少，线性查就够。
public final class UserDict {
    struct Entry: Equatable {
        var code: String
        var text: String
        var weight: UInt32

        init(code: String, text: String, weight: UInt32 = userWeight) {
            self.code = code
            self.text = text
            self.weight = weight
        }
    }

    var entries: [Entry]
    var dirty: Int
    let path: String
    /// 上次读入或写出时文件的修改时间，用来发现别的进程改过它。
    var diskStamp: Date?

    public init(path: String) {
        self.entries = []
        self.dirty = 0
        self.path = path
    }

    init(entries: [Entry] = [], path: String = "") {
        self.entries = entries
        self.dirty = 0
        self.path = path
    }

    /// 读取自造词或短语文件。文件不存在时返回空表。
    /// 每行是「编码<TAB>文本<TAB>权重」，权重可省略（老格式按普通自造词读）。
    /// 空行和 # 开头的行忽略。
    public static func load(_ path: String) -> UserDict {
        let u = UserDict(path: path)
        u.diskStamp = fileStamp(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return u }
        for line in textLines(String(decoding: data, as: UTF8.self)) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let weight = parts.count > 2 ? UInt32(parts[2]) ?? userWeight : userWeight
            u.entries.append(Entry(code: String(parts[0]), text: String(parts[1]), weight: weight))
        }
        return u
    }

    /// 记一个自造词。同一编码同一词条只留一份。
    @discardableResult
    public func add(code: String, text: String) -> Bool {
        guard code.utf8.count >= 4, !text.isEmpty else { return false }
        for e in entries where e.code == code && e.text == text {
            return false
        }
        entries.append(Entry(code: code, text: text, weight: userWeight))
        dirty += 1
        return true
    }

    /// 自造词条数。
    public var count: Int { entries.count }

    /// 把词条按当前编码置顶；同编码已有这个词时不重复添加。
    @discardableResult
    public func pin(_ text: String, code: String) -> Bool {
        guard !text.isEmpty, code.utf8.count >= 2 else { return false }
        for entry in entries where entry.code == code && entry.text == text {
            return false
        }
        entries.append(Entry(code: code, text: text, weight: pinnedWeight))
        dirty += 1
        return true
    }

    /// 从候选菜单删词：所有编码下同名条目一起清掉。
    @discardableResult
    public func remove(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let before = entries.count
        entries.removeAll { $0.text == text }
        guard entries.count != before else { return false }
        dirty += 1
        return true
    }

    /// 返回编码以 prefix 开头的自造词，用户词频 f 计入分数，可以为 nil。
    func lookup(_ prefix: [UInt8], _ limit: Int, _ f: Freq?) -> [Candidate] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let p = String(decoding: prefix, as: UTF8.self)
        var out: [Candidate] = []
        for e in entries where e.code.hasPrefix(p) {
            let codeLen = e.code.utf8.count
            out = insertCandidate(
                out,
                Candidate(
                    e.text, codeLen,
                    candidateScore(e.weight, codeLen, prefix.count) + (f?.boost(e.text) ?? 0)),
                limit)
        }
        return out
    }

    /// 把自造词写回磁盘，先写临时文件再改名。
    public func save() throws {
        guard dirty > 0 else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var out = ""
        for e in entries {
            out += "\(e.code)\t\(e.text)"
            if e.weight != userWeight { out += "\t\(e.weight)" }
            out += "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
        dirty = 0
        diskStamp = fileStamp(path)
    }

    /// 文件在上次读写之后被别的进程改过或删掉。
    var changedOnDisk: Bool {
        !path.isEmpty && fileStamp(path) != diskStamp
    }
}
