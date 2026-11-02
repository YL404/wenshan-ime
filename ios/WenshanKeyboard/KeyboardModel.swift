import Foundation

/// 一次按键或手势后交给 VC 的渲染指令。
enum KeyboardOutcome {
    /// 引擎未就绪或组合缓冲为空，无事发生。
    case idle
    /// 常规按键处理完：VC 按当前组合状态刷新 marked text 和候选条。
    case handled
    /// 处理完并需要往正文插入文本（Shift 直出、兜底空格）。
    case commit(String)
    /// 组合缓冲为空，删除正文一个字符。
    case deleteBackward
}

/// 键盘输入状态机：引擎加载、拼音组合、候选翻页、Shift 都在这里。
/// VC 只做渲染和按键转发，不直接碰引擎桥。
@MainActor
final class KeyboardModel {
    /// 引擎生命周期。
    enum Phase: Equatable {
        /// 词表正在后台加载。
        case loading
        /// 词表就绪，可以输入。
        case ready
        /// 词表打开失败，键盘降级为英文直通，附带原因。
        case failed(String)
    }

    /// Shift 一次性大写：打一个字母后自动回落。
    private(set) var shiftOn = false

    /// 当前拼音缓冲。
    private(set) var buffer = ""
    /// 当前页候选。
    private(set) var candidates: [String] = []

    private(set) var phase: Phase = .loading

    /// 后台打开词表，加载结果回主线程再切状态。
    /// 失败后回到可加载状态，键盘再次出现时允许重试。
    func load() async {
        guard phase != .ready else { return }
        phase = .loading
        let opened = Task.detached(priority: .userInitiated) {
            WenshanBridge.open()
        }
        if let error = await opened.value {
            phase = .failed(error)
        } else {
            phase = .ready
        }
    }

    /// 字母键。shift 为 true 时大写直出（和桌面版一致），组合非空时把已打的拼音一并上屏。
    func type(_ key: String, shift: Bool) -> KeyboardOutcome {
        guard phase == .ready else { return .idle }
        if shift {
            defer { shiftOn = false }
            let text = buffer + key.uppercased()
            clearBuffer()
            return .commit(text)
        }
        return bind(WenshanBridge.type(key))
    }

    /// 空格：有候选上屏首选；没候选时把缓冲字母原样上屏（和桌面版一致，
    /// 空格本身不上屏）；缓冲也空时才插一个空格。
    func space() -> KeyboardOutcome {
        guard phase == .ready else { return .commit(" ") }
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

    /// 回车：有缓冲时把字母原样上屏（和桌面版一致，不插换行）；缓冲空时才插换行。
    func returnKey() -> KeyboardOutcome {
        guard phase == .ready else { return .commit("\n") }
        if !buffer.isEmpty {
            let text = buffer
            clearBuffer()
            return .commit(text)
        }
        return .commit("\n")
    }

    /// 直接插入文本（符号页按键）：组合非空时把缓冲原样上屏再插。
    func insert(_ text: String) -> KeyboardOutcome {
        guard phase == .ready, !buffer.isEmpty else { return .commit(text) }
        let committed = buffer + text
        clearBuffer()
        return .commit(committed)
    }

    /// 轻点 Shift：和桌面版轻点一致，切英文直通；字母仍走引擎（拼音缓冲小写）。
    func toggleShift() {
        shiftOn.toggle()
    }

    /// 删除：组合态退一格缓冲，否则删正文一个字符。
    func backspace() -> KeyboardOutcome {
        guard phase == .ready else { return .deleteBackward }
        if buffer.isEmpty { return .deleteBackward }
        return bind(WenshanBridge.backspace())
    }

    /// 翻页，delta 为 +1/-1，返回翻页后的组合状态。
    func page(_ delta: Int) -> KeyboardOutcome {
        guard phase == .ready, !candidates.isEmpty else { return .idle }
        return bind(WenshanBridge.page(delta))
    }

    /// 选中第 i 个候选并上屏。上屏文本随 .commit 交给 VC，
    /// 连续选词剩下的组合留在缓冲里继续。
    func select(_ index: Int) -> KeyboardOutcome {
        guard phase == .ready else { return .idle }
        return commitSelection(index)
    }

    /// 选词共用路径：同步组合状态，上屏文本随 .commit 交给 VC。
    private func commitSelection(_ index: Int) -> KeyboardOutcome {
        let result = WenshanBridge.select(index)
        buffer = result.state.buffer
        candidates = result.state.candidates
        return .commit(result.text)
    }

    /// 清空当前组合，不删除已经上屏的文本。
    func reset() {
        clearBuffer()
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
