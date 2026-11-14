import Foundation
import UIKit
import WenshanCore

/// 一次按键或手势后交给 VC 的渲染指令。
enum KeyboardOutcome {
    /// 引擎未就绪或组合缓冲为空，无事发生。
    case idle
    /// 常规按键处理完：VC 按当前组合状态刷新 marked text 和候选条。
    case handled
    /// 处理完并需要往正文插入文本：先删 deleteBefore 个字符，插入后移光标。
    case commit(String, deleteBefore: Int = 0, caretOffset: Int = 0)
    /// 组合缓冲为空，删除正文一个字符。
    case deleteBackward
}

/// 键盘输入状态机：只负责 Swift 侧的 Shift 和宿主上下文。
/// 拼音组合、标点、中英模式、英文候选和自动补空格都在共享规则层，
/// VC 只做渲染和按键转发。
@MainActor
final class KeyboardModel {
    enum Phase: Equatable {
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

    private(set) var phase: Phase = .failed("词表还没打开")
    private(set) var preedit = ""
    private(set) var candidates: [String] = []
    private(set) var hasNextPage = false
    private(set) var mode: InputMode = .chinese
    private(set) var shift: ShiftState = .off
    private(set) var fullWidth = true
    private(set) var returnKeyType: UIReturnKeyType = .default

    private let bridge = WenshanBridge()
    private var lastShiftTap: TimeInterval = 0
    private var pageSize = 9

    /// 光标前的正文，由 VC 挂上。规则层判断中英文之间要不要补空格时读它。
    var contextBefore: () -> String {
        get { bridge.contextBefore }
        set { bridge.contextBefore = newValue }
    }

    /// 光标后的正文，成对标点跨过时读它。
    var contextAfter: () -> String {
        get { bridge.contextAfter }
        set { bridge.contextAfter = newValue }
    }

    var isComposing: Bool { !preedit.isEmpty }

    /// 非默认回车键（发送/搜索/完成等）用蓝色强调。
    var isReturnKeyProminent: Bool {
        !isComposing && returnKeyType != .default
    }

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

    /// 打开词表。失败后键盘再次出现时允许重试。
    func load(dataDirectory: URL) {
        guard phase != .ready else { return }
        if let error = bridge.open(dataDirectory: dataDirectory) {
            phase = .failed(error)
        } else {
            phase = .ready
            // 打开失败期间按过「中/英」只改了 Swift 侧，先把规则层切到同一模式再同步。
            if var current = bridge.current() {
                if current.isEnglish != (mode == .english) {
                    current = bridge.toggleMode()
                }
                _ = apply(current)
            }
        }
    }

    func updateContext(returnKeyType: UIReturnKeyType) {
        self.returnKeyType = returnKeyType
    }

    /// 键盘出现时把本机偏好应用到规则层，不重建会话。
    func setMode(_ name: String) {
        let target: InputMode = name == "english" ? .english : .chinese
        mode = target
        bridge.setMode(target == .english ? .english : .chinese)
    }
    func setCandidatePageSize(_ size: Int) {
        pageSize = min(max(1, size), 9)
        bridge.setCandidatePageSize(pageSize)
    }
    func setSpaceRevertsPunctuation(_ enabled: Bool) { bridge.setSpaceRevertsPunctuation(enabled) }
    func setSmartPunctuation(_ enabled: Bool) {
        bridge.configure(smart: enabled, pair: enabled)
    }
    func setKeyFrames(_ frames: [KeyFrame?]) { bridge.setKeyFrames(frames) }
    func setTouchPoint(_ letter: UInt8, _ point: KeyPoint) { bridge.setTouchPoint(letter, point) }
    func editorDidChange() { bridge.editorDidChange() }

    @discardableResult
    func manage(_ text: String, pin: Bool) -> Bool {
        guard phase == .ready else { return false }
        let (changed, outcome) = bridge.manage(text, pin: pin)
        if let outcome { _ = apply(outcome) }
        return changed
    }

    /// 字母键。中文态 Shift 追加到组合缓冲、按大小写出英文候选；英文态直接插入。
    func type(_ key: String) -> KeyboardOutcome {
        guard phase == .ready else {
            return direct(key)
        }
        if mode == .english {
            let text = shift.isActive ? key.uppercased() : key
            if shift == .once { shift = .off }
            return apply(bridge.direct(text))
        }
        if shift.isActive {
            let outcome = bridge.shiftLetter(key.uppercased())
            if shift == .once { shift = .off }
            return apply(outcome)
        }
        return apply(bridge.type(key))
    }

    /// 空格：共享规则层有组合时消费，否则由键盘插入空格。
    func space() -> KeyboardOutcome {
        guard phase == .ready else { return .commit(" ") }
        let outcome = bridge.space()
        return outcome.consumed ? apply(outcome) : .commit(" ")
    }

    /// 回车：组合态把原始编码上屏；否则按宿主语义换行。
    func returnKey() -> KeyboardOutcome {
        guard phase == .ready else { return .commit("\n") }
        let outcome = bridge.returnKey()
        return outcome.consumed ? apply(outcome) : .commit("\n")
    }

    /// 直接插入文本（符号页按键）：组合非空时共享规则层会先上屏候选。
    func insert(_ text: String) -> KeyboardOutcome {
        guard phase == .ready else { return .commit(text) }
        return apply(bridge.direct(text))
    }

    /// 中文标点键。全半角关闭时规则层不消费，按原字符上屏。
    func punctuate(_ ch: String) -> KeyboardOutcome {
        guard phase == .ready else { return .commit(ch) }
        if mode == .english {
            return apply(bridge.direct(ch))
        }
        let outcome = bridge.punctuate(ch)
        return outcome.consumed ? apply(outcome) : apply(bridge.direct(ch))
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

    /// 中英切换。共享规则层会把组合里的编码先原样上屏。
    func toggleMode() -> KeyboardOutcome {
        guard phase == .ready else {
            mode = mode == .chinese ? .english : .chinese
            shift = .off
            return .handled
        }
        let outcome = bridge.toggleMode()
        shift = .off
        return apply(outcome)
    }

    /// 删除：组合态退一格缓冲，否则删正文一个字符。
    func backspace() -> KeyboardOutcome {
        guard phase == .ready else { return .deleteBackward }
        let outcome = bridge.backspace()
        return outcome.consumed ? apply(outcome) : .deleteBackward
    }

    /// 长按删除：一次退一个完整音节，缓冲空了交给平台删正文。
    func backspaceSyllable() -> KeyboardOutcome {
        guard phase == .ready else { return .deleteBackward }
        let outcome = bridge.backspaceSyllable()
        return outcome.consumed ? apply(outcome) : .deleteBackward
    }

    /// 选中当前页第 i 个候选并上屏。
    func select(_ index: Int) -> KeyboardOutcome {
        guard phase == .ready else { return .idle }
        let outcome = bridge.select(index)
        return outcome.consumed ? apply(outcome) : .idle
    }

    /// 只取第 i 个候选的首字或尾字，编码消耗和选整词一样。
    func selectChar(_ index: Int, last: Bool) -> KeyboardOutcome {
        guard phase == .ready else { return .idle }
        let outcome = bridge.selectChar(index, last: last)
        return outcome.consumed ? apply(outcome) : .idle
    }

    /// 选中全部候选里的第 i 个，索引可以落在后续页。
    func selectGlobal(_ index: Int) -> KeyboardOutcome {
        guard phase == .ready else { return .idle }
        let outcome = bridge.selectGlobal(index)
        return outcome.consumed ? apply(outcome) : .idle
    }

    /// 取全部候选里第 i 个候选的首字或尾字，索引可以落在后续页。
    func selectCharGlobal(_ index: Int, last: Bool) -> KeyboardOutcome {
        guard phase == .ready else { return .idle }
        let outcome = bridge.selectCharGlobal(index, last: last)
        return outcome.consumed ? apply(outcome) : .idle
    }

    /// 展开候选时取当前组合的全部候选，不改当前页。
    func allCandidates() -> [String] {
        guard phase == .ready else { return [] }
        return bridge.allCandidates()
    }

    /// 候选条横向滚动时按需取后续候选，不改当前页。
    func moreCandidates(after currentCount: Int) -> (items: [String], hasMore: Bool) {
        guard phase == .ready, isComposing else { return ([], false) }
        return bridge.candidates(upTo: currentCount + max(pageSize, 12))
    }

    /// 切换标点全角/半角。切换结果写在规则层，键盘只负责显示。
    func toggleFullWidth() -> KeyboardOutcome {
        guard phase == .ready else { return .handled }
        return apply(bridge.toggleFullWidth())
    }

    /// 清空当前组合，不删除已经上屏的文本。
    func reset() {
        bridge.reset()
        preedit = ""
        candidates = []
        hasNextPage = false
        shift = .off
    }

    /// 把所有未落盘的用户数据写盘。
    func flush() {
        guard phase == .ready else { return }
        bridge.flush()
    }

    /// 用户数据文件被外部改过时重新读盘。
    func reloadUserDataIfChanged() {
        guard phase == .ready else { return }
        bridge.reloadUserDataIfChanged()
    }

    private func direct(_ key: String) -> KeyboardOutcome {
        let text = shift.isActive ? key.uppercased() : key
        if shift == .once { shift = .off }
        return .commit(text)
    }

    private func apply(_ outcome: BridgeOutcome) -> KeyboardOutcome {
        preedit = outcome.preedit
        candidates = outcome.candidates
        hasNextPage = outcome.hasNextPage
        mode = outcome.isEnglish ? .english : .chinese
        fullWidth = outcome.fullWidth
        return outcome.text.isEmpty && outcome.deleteBefore == 0 && outcome.caretOffset == 0
            ? .handled
            : .commit(
                outcome.text,
                deleteBefore: outcome.deleteBefore,
                caretOffset: outcome.caretOffset)
    }
}
