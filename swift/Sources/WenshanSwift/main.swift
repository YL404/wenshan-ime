import AppKit
import Darwin
import InputMethodKit

// 和 Go 版使用同一个 bundle id / 连接名 / 输入源：替换后系统认的还是「文山」，
// 用户不需要重新添加输入源，也不需要改快捷键。
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
