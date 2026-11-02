import Foundation

/// 主 App 和键盘扩展共享的容器。扩展只读词表；用户数据后面也放这里。
/// 没有 App Group 时返回 nil，调用方按自己的 Bundle/Documents 回退。
enum AppGroup {
    static let identifier = "group.im.wenshan.ios"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var dictURL: URL? {
        containerURL?.appendingPathComponent("dict.bin", isDirectory: false)
    }

    static var dataDirectoryURL: URL? {
        containerURL?.appendingPathComponent("Data", isDirectory: true)
    }
}
