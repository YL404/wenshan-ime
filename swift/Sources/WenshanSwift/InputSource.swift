import Carbon
import Darwin
import Foundation

/// 把 bundle 注册到 TIS，让系统认到这个输入源。
@MainActor
func registerInputSource(_ path: String) -> Int32 {
    let url = URL(fileURLWithPath: path) as CFURL
    return TISRegisterInputSource(url)
}

/// 按输入源 ID 选中。找不到返回 -1。
@MainActor
func selectInputSource(_ wanted: String) -> Int32 {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
    else { return -1 }
    for source in list {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            continue
        }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        if id == wanted {
            return TISSelectInputSource(source)
        }
    }
    return -1
}

/// 从输入源列表里移除。迁移时用来清掉旧的独立 Swift 版。
@MainActor
func disableInputSource(_ wanted: String) -> Int32 {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
    else { return -1 }
    for source in list {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            continue
        }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        if id == wanted {
            return TISDisableInputSource(source)
        }
    }
    return 0
}

/// 原子交换两个目录，安装时只换 Contents，避免 bundle 出现不完整的窗口。
@MainActor
func swapContents(_ a: String, _ b: String) -> Int32 {
    let rc = renamex_np(a, b, UInt32(RENAME_SWAP))
    if rc != 0 {
        Log.shared.write("renamex_np 失败: \(String(cString: strerror(errno)))")
    }
    return rc
}
