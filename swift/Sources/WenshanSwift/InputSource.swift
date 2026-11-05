import Carbon
import Darwin
import Foundation

/// 把 bundle 注册到 TIS，让系统认到这个输入源。
@MainActor
func registerInputSource(_ path: String) -> Int32 {
    let url = URL(fileURLWithPath: path) as CFURL
    return TISRegisterInputSource(url)
}

/// 输入法进程重启后，前台 App 仍然握着上一个实例的连接，按键会直接透传。
/// 新实例起来后重新选中自己，逼 IMK 把客户端重新接上。
@MainActor
func selectOwnInputSource(_ modeID: String) {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
    else { return }
    for source in list {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            continue
        }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        if id == modeID {
            let rc = TISSelectInputSource(source)
            Log.shared.write("重新选中输入源 \(modeID) -> \(rc)")
            return
        }
    }
    Log.shared.write("没有找到输入源 \(modeID)")
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
