import Foundation
import UIKit

/// 一次按键或手势后交给 VC 的渲染指令。
enum KeyboardOutcome {
    /// 引擎未就绪或组合缓冲为空，无事发生。
    case idle
    /// 常规按键处理完：VC 按当前组合状态刷新 marked text 和候选条。
    case handled
    /// 处理完并需要往正文插入文本。
    case commit(String)
    /// 组合缓冲为空，删除正文一个字符。
    case deleteBackward
}

/// 键盘输入状态机：引擎加载、拼音组合、候选翻页、中英模式和 Shift 都在这里。
/// VC 只做渲染和按键转发，不直接碰引擎桥。
@MainActor
final class KeyboardModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum InputMode: Equatable {
        case chinese
        case english
    }

    enum ShiftState: Equatable {
        case off
        case once
        case locked

        var isActive: Bool { self != .off }
    }

    private(set) var phase: Phase = .loading
    private(set) var buffer = ""
    private(set) var candidates: [String] = []
    private(set) var mode: InputMode = .chinese
    private(set) var shift: ShiftState = .off
    private(set) var returnKeyType: UIReturnKeyType = .default

    private var isLoading = false
    private var lastShiftTap: TimeInterval = 0

    var isComposing: Bool { !buffer.isEmpty }

    /// 回车键标题：组合态显示“确认”，其余跟宿主输入框的 returnKeyType 走。
    var returnKeyTitle: String {
        if isComposing {
            return "确认"
        }
        switch returnKeyType {
        case .go: return "前往"
        case .google: return "搜索"
        case .join: return "加入"
        case .next: return "下一项"
        case .route: return "路线"
        case .search: return "搜索"
        case .send: return "发送"
        case .yahoo: return "搜索"
        case .done: return "完成"
        case .emergencyCall: return "呼叫"
        case .continue: return "继续"
        case .default: return "换行"
        @unknown default: return "换行"
        }
    }

    /// 后台打开词表。失败后再次出现时允许重试。
    func load(dataDirectory: URL) async {
        guard phase != .ready, !isLoading else { return }
        isLoading = true
        phase = .loading
        let error = await Task.detached(priority: .userInitiated) {
            WenshanBridge.open(dataDirectory: dataDirectory)
        }.value
        isLoading = false
        if let error {
            phase = .failed(error)
        } else {
            phase = .ready
        }
    }

    func updateContext(returnKeyType: UIReturnKeyType) {
        self.returnKeyType = returnKeyType
    }

    /// 字母键。中文态 Shift 直出大写英文；英文态按 Shift 大小写输入。
    func type(_ key: String) -> KeyboardOutcome {
        guard phase == .ready else {
            return direct(key)
        }
        if mode == .english {
            return direct(key)
        }
        if shift.isActive {
            let text = buffer + key.uppercased()
            clearBuffer()
            if shift == .once { shift = .off }
            return .commit(text)
        }
        return bind(WenshanBridge.type(key))
    }

    /// 空格：中文态有候选选首选，有缓冲把字母原样上屏，否则插空格。
    func space() -> KeyboardOutcome {
        guard phase == .ready, mode == .chinese else { return .commit(" ") }
        if !candidates.isEmpty {
            return commitSelection(0)
        }
        if !buffer.isEmpty {
            let text = buffer
            clearBuffer()
            return .commit(text)
        }
        return .commit(" ")
    }

    /// 回车：组合态把原始编码上屏（和桌面版一致）；否则按宿主语义换行。
    func returnKey() -> KeyboardOutcome {
        guard phase == .ready, mode == .chinese, !buffer.isEmpty else {
            return .commit("\n")
        }
        let text = buffer
        clearBuffer()
        return .commit(text)
    }

    /// 直接插入文本（符号页按键）：组合非空时把缓冲原样上屏再插。
    func insert(_ text: String) -> KeyboardOutcome {
        guard phase == .ready, mode == .chinese, !buffer.isEmpty else {
            return .commit(text)
        }
        let committed = buffer + text
        clearBuffer()
        return .commit(committed)
    }

    /// Shift 轻点切换一次性大写，双击锁定；再点取消。
    func shiftTapped() {
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastShiftTap < 0.35 {
            shift = .locked
            lastShiftTap = 0
        } else if shift == .locked {
            shift = .off
            lastShiftTap = 0
        } else {
            shift = shift == .off ? .once : .off
            lastShiftTap = now
        }
    }

    /// 中英切换。组合里的编码先原样上屏，避免切换时丢字。
    func toggleMode() -> KeyboardOutcome {
        let text = buffer
        clearBuffer()
        mode = mode == .chinese ? .english : .chinese
        shift = .off
        return text.isEmpty ? .handled : .commit(text)
    }

    /// 删除：组合态退一格缓冲，否则删正文一个字符。
    func backspace() -> KeyboardOutcome {
        guard phase == .ready, mode == .chinese, !buffer.isEmpty else {
            return .deleteBackward
        }
        return bind(WenshanBridge.backspace())
    }

    /// 翻页，delta 为 +1/-1。
    func page(_ delta: Int) -> KeyboardOutcome {
        guard phase == .ready, !candidates.isEmpty else { return .idle }
        return bind(WenshanBridge.page(delta))
    }

    /// 选中第 i 个候选并上屏。
    func select(_ index: Int) -> KeyboardOutcome {
        guard phase == .ready else { return .idle }
        return commitSelection(index)
    }

    /// 清空当前组合，不删除已经上屏的文本。
    func reset() {
        clearBuffer()
        shift = .off
    }

    /// 把攒够次数的用户数据写盘。
    func flush() {
        guard phase == .ready else { return }
        WenshanBridge.flush()
    }

    private func direct(_ key: String) -> KeyboardOutcome {
        let text = shift.isActive ? key.uppercased() : key
        if shift == .once { shift = .off }
        return .commit(text)
    }

    private func commitSelection(_ index: Int) -> KeyboardOutcome {
        let result = WenshanBridge.select(index)
        buffer = result.state.buffer
        candidates = result.state.candidates
        WenshanBridge.flush()
        return .commit(result.text)
    }

    private func bind(_ state: ComposingState) -> KeyboardOutcome {
        buffer = state.buffer
        candidates = state.candidates
        if buffer.isEmpty {
            return .commit("")
        }
        return .handled
    }

    private func clearBuffer() {
        WenshanBridge.reset()
        buffer = ""
        candidates = []
    }
}
