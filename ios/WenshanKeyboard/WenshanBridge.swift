import Foundation
import WenshanEngine

/// gomobile 桥的 Swift 门面：跨语言调用收在这一处。
///
/// 一次「按键/选词/翻页」只跨一次语言边界，直接返回组合状态
/// （缓冲 + 当前页候选），不再像旧版那样每个动作跨两三次边界拼状态。
struct ComposingState: Equatable {
    /// 当前拼音缓冲，用于 marked text。
    var buffer: String
    /// 当前页候选。
    var candidates: [String]

    static let empty = ComposingState(buffer: "", candidates: [])
}

/// gomobile 桥的 Swift 门面。所有引擎调用都从主线程进来；
/// 词表 mmap 由 Go 侧加锁，后台线程读词表也安全。
enum WenshanBridge {
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

    /// 释放引擎和词表映射。
    static func close() {
        MobileClose()
    }

    /// 追加一个或多个 ASCII 按键，返回按键后的组合状态。
    static func type(_ keys: String) -> ComposingState {
        state(MobileType(keys))
    }

    /// 删除一个按键，返回删除后的组合状态。
    static func backspace() -> ComposingState {
        state(MobileBackspace())
    }

    /// 选中第 i 个候选并上屏：返回要插入的文本和上屏后的组合状态。
    /// 连续选词时引擎会把剩余缓冲重新查词，状态里的缓冲可能非空。
    static func select(_ index: Int) -> (text: String, state: ComposingState) {
        let text = MobileSelect(index)
        return (text, composingState())
    }

    /// 翻页，delta 为 +1/-1，返回翻页后的组合状态。
    static func page(_ delta: Int) -> ComposingState {
        state(MobilePage(delta))
    }

    /// 清空当前组合，不删除已经上屏的文本。
    static func reset() {
        MobileReset()
    }

    /// 当前组合状态（不打扰引擎，只读快照）。
    static func composingState() -> ComposingState {
        ComposingState(buffer: MobileBuffer(), candidates: parseCandidates(MobileCandidates()))
    }

    private static func state(_ joined: String) -> ComposingState {
        ComposingState(buffer: MobileBuffer(), candidates: parseCandidates(joined))
    }

    /// gomobile 不支持 []string，桥接用换行分隔的字符串传候选。
    private static func parseCandidates(_ joined: String) -> [String] {
        joined.isEmpty ? [] : joined.split(separator: "\n").map(String.init)
    }
}
