import Foundation
import WenshanCore
import os

private let bridgeLog = Logger(subsystem: "im.wenshan.ios.keyboard", category: "bridge")

/// 规则层一次动作的结果。Swift 侧只认这个结构，不直接碰引擎类型。
struct BridgeOutcome: Equatable {
    /// 要插入正文的文本，已经包含自动补的空格。
    var text: String
    /// 预编辑串：当前组合缓冲（拼音或英文段）。
    var preedit: String
    /// 当前页候选。
    var candidates: [String]
    /// false 表示规则层没消费这个键，Swift 侧按原键处理。
    var consumed: Bool
    var isEnglish: Bool
    var fullWidth: Bool
    /// 插入 text 前先删掉光标前多少字符，插入后把光标移多少字符。
    var deleteBefore: Int
    var caretOffset: Int
}

/// WenshanCore 的门面，也是唯一持有引擎状态的地方。打开词表只是 mmap 加校验文件头，
/// 连同读用户数据都在主线程做，所以整类只在主线程访问，不加锁。
@MainActor
final class WenshanBridge {
    /// 光标前的正文，由键盘 VC 提供。规则层判断要不要补空格时读它。
    var contextBefore: () -> String = { "" }
    /// 光标后的正文，成对标点跨过时读第一个字符。
    var contextAfter: () -> String = { "" }

    private var session: Session?
    private var engine: Engine?
    private var lastRune: Unicode.Scalar?
    private var lastResult: Result?

    private static let empty = BridgeOutcome(
        text: "", preedit: "", candidates: [], consumed: false, isEnglish: false,
        fullWidth: true, deleteBefore: 0, caretOffset: 0)

    /// 打开扩展 Bundle 里的词表并建立引擎。词表跟着扩展一起安装和更新，
    /// 不再复制到 App Group：副本只有打开主 App 才会刷新，更新后键盘会一直用旧词表。
    /// 失败时返回错误原因，成功返回 nil。
    func open(dataDirectory: URL) -> String? {
        session = nil
        engine = nil
        lastRune = nil

        guard let url = Bundle.main.url(forResource: "dict", withExtension: "bin") else {
            return "扩展里找不到 dict.bin"
        }
        do {
            // mappedIfSafe 让 17 MB 词表走 mmap，不整块复制进扩展内存。
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let dict = try Dict(data: data)
            let eng = Engine(dict: dict)
            if let englishURL = Bundle.main.url(forResource: "english", withExtension: "bin"),
               let englishData = try? Data(contentsOf: englishURL, options: .mappedIfSafe),
               let english = try? EnglishDict(data: englishData)
            {
                eng.setEnglishDict(english)
            }
            let sess = Session(eng: eng)
            sess.setLookbehind { [weak self] in self?.lastRune }
            sess.setLookahead { [weak self] in self?.contextAfter().unicodeScalars.first }
            if !dataDirectory.path.isEmpty {
                eng.setFreq(
                    Freq.load(dataDirectory.appendingPathComponent("freq.tsv").path))
                eng.setUserDict(
                    UserDict.load(dataDirectory.appendingPathComponent("userdict.tsv").path))
                eng.setPhrases(
                    UserDict.load(dataDirectory.appendingPathComponent("phrases.tsv").path))
            }
            session = sess
            engine = eng
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// 把词频和自造词里所有未落盘的改动写盘。
    func flush() {
        do {
            try session?.save(force: true)
        } catch {
            bridgeLog.error("flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 键盘再次出现时调用：主 App 清空了学习记录、或另一个键盘进程写过文件，
    /// 就重新读盘。收起时已经 flush 过，不会丢掉本进程的改动。
    func reloadUserDataIfChanged() {
        session?.reloadIfChangedOnDisk()
    }

    /// 当前组合状态和模式，不执行动作。词表还没打开时返回 nil。
    func current() -> BridgeOutcome? {
        guard session != nil else { return nil }
        return snapshot()
    }

    func type(_ key: String) -> BridgeOutcome {
        call { $0.type(key.utf8.first ?? 0) }
    }

    func shiftLetter(_ key: String) -> BridgeOutcome {
        call { $0.shiftLetter(key.utf8.first ?? 0) }
    }

    func space() -> BridgeOutcome {
        call { $0.space() }
    }

    func returnKey() -> BridgeOutcome {
        call { $0.returnKey() }
    }

    func backspace() -> BridgeOutcome {
        call(syncContext: false) { $0.backspace() }
    }

    func backspaceSyllable() -> BridgeOutcome {
        call(syncContext: false) { $0.backspaceSyllable() }
    }

    /// 键盘出现时应用本机偏好。这些开关不重建引擎会话。
    func setMode(_ mode: Mode) { session?.setMode(mode) }
    func setCandidatePageSize(_ size: Int) { engine?.pageSize = size }
    func setSpaceRevertsPunctuation(_ enabled: Bool) {
        session?.spaceRevertsPunctuation = enabled
    }
    func configure(smart: Bool, pair: Bool) {
        session?.smartPunctuation = smart
        session?.pairPunctuation = pair
    }
    func setKeyFrames(_ frames: [KeyFrame?]) { engine?.setKeyFrames(frames) }
    func setTouchPoint(_ letter: UInt8, _ point: KeyPoint) {
        engine?.setTouchPoint(letter, point)
    }
    func editorDidChange() { session?.editorDidChange() }
    func manage(_ text: String, pin: Bool) { _ = engine?.manage(text, pin: pin) }

    func select(_ index: Int) -> BridgeOutcome {
        call { $0.select(index) }
    }

    func selectChar(_ index: Int, last: Bool) -> BridgeOutcome {
        call { $0.selectChar(index, last: last) }
    }

    func selectGlobal(_ index: Int) -> BridgeOutcome {
        call { $0.selectGlobal(index) }
    }

    func punctuate(_ ch: String) -> BridgeOutcome {
        call { $0.punctuate(ch.utf8.first ?? 0) }
    }

    func direct(_ text: String) -> BridgeOutcome {
        call { $0.direct(text) }
    }

    func toggleMode() -> BridgeOutcome {
        call { $0.toggleMode() }
    }

    func toggleFullWidth() -> BridgeOutcome {
        call(syncContext: false) { $0.toggleFullWidth() }
    }

    func reset() {
        session?.reset()
    }

    func allCandidates() -> [String] {
        return session?.allCandidates.map(\.text) ?? []
    }

    /// 执行一次规则动作。可能上屏或补空格的动作先把最新正文推给规则层。
    /// 词表还没打开时当作没消费。
    private func call(syncContext: Bool = true, _ action: (Session) -> Result) -> BridgeOutcome {
        if syncContext {
            setContextBefore(contextBefore())
        }
        guard let session else { return Self.empty }
        let result = action(session)
        lastResult = result
        // 和原来一样，词频攒够 50 次才写盘；失败不影响这次按键。
        _ = try? session.save(force: false)
        return snapshot(result)
    }

    /// 更新光标前的正文。组合中正文末尾挂着预编辑串本身，要先去掉：
    /// 动作里选词会消耗缓冲，到规则层读光标前字符时预编辑已经变了。
    private func setContextBefore(_ text: String) {
        guard let session else { return }
        var trimmed = text
        let preedit = session.preedit
        if !preedit.isEmpty, trimmed.hasSuffix(preedit) {
            trimmed = String(trimmed.dropLast(preedit.count))
        }
        lastRune = trimmed.unicodeScalars.last
    }

    private func snapshot(_ result: Result? = nil) -> BridgeOutcome {
        guard let session else { return Self.empty }
        let info = result ?? lastResult
        return BridgeOutcome(
            text: info?.text ?? "",
            preedit: session.preedit,
            candidates: session.candidates.map(\.text),
            consumed: info?.consumed ?? false,
            isEnglish: session.currentMode == .english,
            fullWidth: session.isFullWidth,
            deleteBefore: result?.deleteBefore ?? 0,
            caretOffset: result?.caretOffset ?? 0)
    }
}
