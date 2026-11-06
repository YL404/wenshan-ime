import Foundation

/// 主 App 和键盘扩展共享的容器，放用户数据。词表留在扩展 Bundle 里。
/// 没有 App Group 时返回 nil，调用方按自己的 Documents 回退。
enum AppGroup {
    static let identifier = "group.im.wenshan.ios"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var dataDirectoryURL: URL? {
        containerURL?.appendingPathComponent("Data", isDirectory: true)
    }

    /// 键盘扩展存用户数据的目录：App Group 可写时用共享目录，主 App 能看到统计；
    /// 没有完全访问时 App Group 可能只读，退回扩展自己的 Documents。
    static func keyboardDataDirectory() -> URL {
        let fm = FileManager.default
        if let group = dataDirectoryURL {
            do {
                try fm.createDirectory(at: group, withIntermediateDirectories: true)
                let probe = group.appendingPathComponent(".write-test")
                try Data().write(to: probe, options: .atomic)
                try? fm.removeItem(at: probe)
                return group
            } catch {
                // 只读或不可用，继续走沙箱。
            }
        }
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fallback = documents.appendingPathComponent("Wenshan", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}
