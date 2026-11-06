import AppKit
import Darwin
import InputMethodKit

// 输入源 ID、连接名和 bundle id 一旦被用户添加就不能再改：改了系统会当成另一个
// 输入法，用户得重新添加输入源、重新设快捷键。
let bundleID = "im.wenshan.inputmethod.Wenshan"
let connectionName = bundleID + ".Connection"
let modeID = bundleID + ".Hans"

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--register" {
    exit(registerInputSource(args[2]))
}
if args.count >= 4, args[1] == "--swap" {
    exit(swapContents(args[2], args[3]))
}
if args.count >= 3, args[1] == "--select" {
    exit(selectInputSource(args[2]))
}
if args.count >= 3, args[1] == "--enable" {
    exit(enableInputSource(args[2]))
}
if args.count >= 3, args[1] == "--disable" {
    exit(disableInputSource(args[2]))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 开发用：把候选条摆到屏幕中间，方便截图检查外观。
if args.contains("--demo") {
    AppState.shared.start()
    AppState.shared.demo()
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
    app.run()
}

Log.shared.write("启动")
AppState.shared.start()

let server = IMKServer(name: connectionName, bundleIdentifier: bundleID)
guard server != nil else {
    Log.shared.write("IMKServer 创建失败")
    exit(1)
}
Log.shared.write("就绪: \(connectionName), 词表 \(AppState.shared.dictCount) 条")

// 稍等 IMK 把服务挂好，再重新选中自己：升级或崩溃重启之后，前台 App 还
// 连着旧实例，不重新选一次它不会把按键交过来。
Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(600))
    let rc = selectInputSource(modeID)
    Log.shared.write("重新选中输入源 \(modeID) -> \(rc)")
}

app.run()
