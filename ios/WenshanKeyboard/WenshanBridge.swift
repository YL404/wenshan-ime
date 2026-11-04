import Foundation
import WenshanEngine

/// 规则层一次动作的结果。Swift 侧只认这个结构，不直接碰 gomobile 生成的类。
struct BridgeOutcome: Equatable {
    /// 要插入正文的文本，已经包含自动补的空格。
    var text: String
    /// 预编辑串：临时英文或拼音缓冲。
    var preedit: String
    /// 当前页候选。
    var candidates: [String]
    /// false 表示规则层没消费这个键，Swift 侧按原键处理。
    var consumed: Bool
    /// 0 中文，1 英文。
    var mode: Int
    var fullWidth: Bool

    static let empty = BridgeOutcome(
        text: "", preedit: "", candidates: [], consumed: false, mode: 0, fullWidth: true)
}

/// gomobile 桥的 Swift 门面。所有引擎和规则调用都从主线程进来；
/// 词表 mmap 由 Go 侧加锁，后台线程读词表也安全。
enum WenshanBridge {
    /// 光标前正文的来源，由键盘 VC 挂上。规则层判断要不要补空格时读它。
    /// 除了后台的 open，桥调用都在主线程，这里不受 actor 隔离约束。
    nonisolated(unsafe) static var contextBefore: (() -> String)?

    /// 把最新正文推给规则层。只有可能上屏或补空格的按键需要。
    private static func syncContext() {
        MobileSetContextBefore(contextBefore?() ?? "")
    }

    /// 打开词表并建立引擎。优先用主 App 部署到 App Group 的词表；
    /// 没部署或打不开时退回扩展 Bundle 里的同一份文件。
    /// 失败时返回错误原因，成功返回 nil。
    static func open(dataDirectory: URL) -> String? {
        var paths: [String] = []
        if let shared = AppGroup.dictURL {
            paths.append(shared.path)
        }
        if let bundled = Bundle.main.path(forResource: "dict", ofType: "bin") {
            paths.append(bundled)
        }
        guard !paths.isEmpty else {
            return "扩展里找不到 dict.bin"
        }
        var lastError = ""
        for path in paths {
            if MobileOpen(path, dataDirectory.path) {
                return nil
            }
            lastError = MobileLastError()
        }
        return lastError
    }

    /// 把词频和自造词写盘。
    static func flush() {
        MobileFlush()
    }

    static func type(_ keys: String) -> BridgeOutcome {
        syncContext()
        return map(MobileType(keys))
    }

    static func shiftLetter(_ key: String) -> BridgeOutcome {
        syncContext()
        return map(MobileShiftLetter(key))
    }

    static func space() -> BridgeOutcome {
        syncContext()
        return map(MobileSpace())
    }

    static func returnKey() -> BridgeOutcome {
        syncContext()
        return map(MobileReturn())
    }

    static func backspace() -> BridgeOutcome {
        map(MobileBackspace())
    }

    static func select(_ index: Int) -> BridgeOutcome {
        syncContext()
        return map(MobileSelect(index))
    }

    static func selectChar(_ index: Int, last: Bool) -> BridgeOutcome {
        syncContext()
        return map(MobileSelectChar(index, last))
    }

    static func selectGlobal(_ index: Int) -> BridgeOutcome {
        syncContext()
        return map(MobileSelectGlobal(index))
    }

    static func allCandidates() -> [String] {
        parseCandidates(MobileAllCandidates())
    }

    static func punctuate(_ ch: String) -> BridgeOutcome {
        syncContext()
        return map(MobilePunctuate(ch))
    }

    static func direct(_ text: String) -> BridgeOutcome {
        syncContext()
        return map(MobileDirect(text))
    }

    static func toggleMode() -> BridgeOutcome {
        syncContext()
        return map(MobileToggleMode())
    }

    static func toggleFullWidth() -> BridgeOutcome {
        map(MobileToggleFullWidth())
    }

    static func reset() {
        MobileReset()
    }

    static func mode() -> Int {
        Int(MobileMode())
    }

    static func fullWidth() -> Bool {
        MobileFullWidth()
    }

    private static func map(_ outcome: MobileOutcome?) -> BridgeOutcome {
        guard let outcome else { return .empty }
        return BridgeOutcome(
            text: outcome.text,
            preedit: outcome.preedit,
            candidates: parseCandidates(outcome.candidates),
            consumed: outcome.consumed,
            mode: Int(outcome.mode),
            fullWidth: outcome.fullWidth)
    }

    /// gomobile 不支持 []string，桥接用换行分隔的字符串传候选。
    private static func parseCandidates(_ joined: String) -> [String] {
        joined.isEmpty ? [] : joined.split(separator: "\n").map(String.init)
    }
}
