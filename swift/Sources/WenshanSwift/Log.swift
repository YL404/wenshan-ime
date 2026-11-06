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
        // O_APPEND 让每次写都落在文件末尾：安装或调试时可能有两个进程同时写，
        // 各自记偏移会互相覆盖。不带 O_TRUNC，重启不清空上次崩溃前的记录。
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
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
