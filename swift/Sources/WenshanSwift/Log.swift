import Foundation

/// 输入法由系统启动，没有终端，日志写到文件里。
/// 和 Go 版分开，方便并存测试时对照。
@MainActor
final class Log {
    static let shared = Log()

    private let handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WenshanSwift.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
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
