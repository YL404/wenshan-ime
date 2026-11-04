import Foundation
import WenshanEngine
import os

private let bridgeLog = Logger(subsystem: "im.wenshan.ios.keyboard", category: "bridge")

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
    var isEnglish: Bool
    var fullWidth: Bool
}

/// gomobile 桥的 Swift 门面，也是唯一接触 gomobile 生成类型的地方。
/// 除了在后台打开词表的 open，所有调用都在主线程。
@MainActor
final class WenshanBridge {
    /// 光标前的正文，由键盘 VC 提供。规则层判断要不要补空格时读它。
    var contextBefore: () -> String = { "" }

    /// 打开词表并建立引擎。优先用主 App 部署到 App Group 的词表；
    /// 没部署或打不开时退回扩展 Bundle 里的同一份文件。
    /// 失败时返回错误原因，成功返回 nil。Go 侧加锁，可以在后台线程调用。
    nonisolated static func open(dataDirectory: URL) -> String? {
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

    /// 把词频和自造词里所有未落盘的改动写盘。
    func flush() {
        let error = MobileFlush()
        if !error.isEmpty {
            bridgeLog.error("flush failed: \(error, privacy: .public)")
        }
    }

    /// 当前组合状态和模式，不执行动作。词表还没打开时返回 nil。
    func current() -> BridgeOutcome? {
        MobileCurrent().map(Self.map)
    }

    func type(_ key: String) -> BridgeOutcome { call { MobileType(key) } }
    func shiftLetter(_ key: String) -> BridgeOutcome { call { MobileShiftLetter(key) } }
    func space() -> BridgeOutcome { call { MobileSpace() } }
    func returnKey() -> BridgeOutcome { call { MobileReturn() } }
    func backspace() -> BridgeOutcome { call(syncContext: false) { MobileBackspace() } }
    func select(_ index: Int) -> BridgeOutcome { call { MobileSelect(index) } }
    func selectChar(_ index: Int, last: Bool) -> BridgeOutcome { call { MobileSelectChar(index, last) } }
    func selectGlobal(_ index: Int) -> BridgeOutcome { call { MobileSelectGlobal(index) } }
    func punctuate(_ ch: String) -> BridgeOutcome { call { MobilePunctuate(ch) } }
    func direct(_ text: String) -> BridgeOutcome { call { MobileDirect(text) } }
    func toggleMode() -> BridgeOutcome { call { MobileToggleMode() } }
    func toggleFullWidth() -> BridgeOutcome { call(syncContext: false) { MobileToggleFullWidth() } }

    func reset() {
        MobileReset()
    }

    func allCandidates() -> [String] {
        Self.parseCandidates(MobileAllCandidates())
    }

    /// 执行一次规则动作。可能上屏或补空格的动作先把最新正文推给规则层。
    /// 词表还没打开时 Go 返回 nil，这里当作没消费。
    private func call(syncContext: Bool = true, _ action: () -> MobileOutcome?) -> BridgeOutcome {
        if syncContext {
            MobileSetContextBefore(contextBefore())
        }
        guard let outcome = action() else {
            return BridgeOutcome(
                text: "", preedit: "", candidates: [], consumed: false, isEnglish: false, fullWidth: true)
        }
        return Self.map(outcome)
    }

    private static func map(_ outcome: MobileOutcome) -> BridgeOutcome {
        BridgeOutcome(
            text: outcome.text,
            preedit: outcome.preedit,
            candidates: parseCandidates(outcome.candidates),
            consumed: outcome.consumed,
            isEnglish: outcome.mode == 1,
            fullWidth: outcome.fullWidth)
    }

    /// gomobile 不支持 []string，Go 侧用 U+001F 拼接候选。按 UTF-16 切，
    /// 不按字素簇切，"\r\n" 之类的组合也不会把下标切错位。
    private static func parseCandidates(_ joined: String) -> [String] {
        joined.isEmpty ? [] : joined.components(separatedBy: "\u{1F}")
    }
}
