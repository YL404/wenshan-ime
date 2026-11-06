import Foundation

/// 输入法由系统启动，没有终端，日志追加写到文件里，重启后还能看到上次崩溃前的记录。
@MainActor
final class Log {
    static let shared = Log()

    private let handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Wenshan.log")
        // createFile 遇到已有文件会清空它，只在文件不存在时才建。
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func write(_ message: String) {
        guard let handle else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
