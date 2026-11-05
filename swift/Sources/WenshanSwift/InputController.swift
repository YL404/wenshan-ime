import AppKit
import InputMethodKit

/// IMK 的回调都在主线程，但头文件没有标 @MainActor，Swift 6 会把参数当成
/// 跨隔离域传递。这个盒子只用来告诉编译器「确实在主线程同步调用」。
private struct UnsafeBox<T>: @unchecked Sendable {
    let value: T
}

/// Info.plist 里的 InputMethodServerControllerClass 指向这个 ObjC 类名。
/// IMK 在每次输入会话时创建一个实例，状态统一放在 AppState。
@objc(WenshanInputController)
final class InputController: IMKInputController {
    override func handle(_ event: NSEvent, client sender: Any!) -> Bool {
        guard let client = sender as? any IMKTextInput else { return false }
        let box = UnsafeBox(value: (event, client))
        return MainActor.assumeIsolated {
            AppState.shared.handle(box.value.0, client: box.value.1)
        }
    }

    override func activateServer(_ sender: Any!) {
        let box = UnsafeBox(value: sender)
        MainActor.assumeIsolated {
            AppState.shared.activate(box.value)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        let box = UnsafeBox(value: sender)
        MainActor.assumeIsolated {
            AppState.shared.deactivate(box.value)
        }
    }

    override func commitComposition(_ sender: Any!) {
        let box = UnsafeBox(value: sender)
        MainActor.assumeIsolated {
            AppState.shared.commitComposition(box.value)
        }
    }

    /// 订阅按下和修饰键变化：后者用来识别 Shift 轻点。
    override func recognizedEvents(_ sender: Any!) -> Int {
        (1 << NSEvent.EventType.keyDown.rawValue)
            | (1 << NSEvent.EventType.flagsChanged.rawValue)
    }
}
