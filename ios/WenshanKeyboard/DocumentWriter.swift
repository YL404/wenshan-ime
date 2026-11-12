import UIKit

/// 往宿主正文写东西的唯一入口：预编辑（marked text）、上屏、删除、移光标。
/// 记住当前有没有 marked text，以及是不是正在写，外部改动回调据此判断
/// 是不是自己引起的。
@MainActor
final class DocumentWriter {
    private let proxy: () -> UITextDocumentProxy
    private(set) var hasMarkedText = false
    /// 同步写正文期间为 true。宿主同步回调 textDidChange 时用来忽略自己的改动。
    private(set) var isWriting = false

    init(proxy: @escaping () -> UITextDocumentProxy) {
        self.proxy = proxy
    }

    /// 光标前的正文，可能包含末尾的 marked text。
    var contextBefore: String {
        proxy().documentContextBeforeInput ?? ""
    }

    /// 光标后的正文。成对标点跨过时要读它，宿主不报告时返回空串。
    var contextAfter: String {
        proxy().documentContextAfterInput ?? ""
    }

    /// 把预编辑串写成 marked text，光标停在末尾；空串时清掉。
    func setMarkedText(_ text: String) {
        guard !text.isEmpty else {
            clearMarkedText()
            return
        }
        write { $0.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0)) }
        hasMarkedText = true
    }

    func clearMarkedText() {
        guard hasMarkedText else { return }
        write { $0.setMarkedText("", selectedRange: NSRange(location: 0, length: 0)) }
        hasMarkedText = false
    }

    /// 上屏：先清掉 marked text，再插入文本。
    func insert(_ text: String) {
        write { proxy in
            if hasMarkedText {
                proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                hasMarkedText = false
            }
            if !text.isEmpty {
                proxy.insertText(text)
            }
        }
    }

    func deleteBackward() {
        write { $0.deleteBackward() }
    }

    /// 智能标点改写：一次删掉刚上屏的 n 个字符。
    func deleteBackward(times: Int) {
        guard times > 0 else { return }
        write { proxy in
            for _ in 0..<times { proxy.deleteBackward() }
        }
    }

    func moveCursor(by steps: Int) {
        proxy().adjustTextPosition(byCharacterOffset: steps)
    }

    /// 部分宿主会在 setMarkedText 之后异步回调 textDidChange，这时 isWriting
    /// 早已复位。光标前仍以当前预编辑串结尾，说明改动来自自己的组合。
    func endsWithMarkedText(_ preedit: String) -> Bool {
        hasMarkedText && !preedit.isEmpty && contextBefore.hasSuffix(preedit)
    }

    private func write(_ body: (UITextDocumentProxy) -> Void) {
        isWriting = true
        defer { isWriting = false }
        body(proxy())
    }
}
