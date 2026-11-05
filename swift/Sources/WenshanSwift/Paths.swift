import Foundation

/// 文件位置。用户数据和 Go 版分开，避免两个进程同时写坏同一份词频。
enum Paths {
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wenshan")

    static let freq = appSupport.appendingPathComponent("freq.tsv")
    static let userDict = appSupport.appendingPathComponent("userdict.tsv")
    static let phrases = appSupport.appendingPathComponent("phrases.tsv")
    static let debugFlag = appSupport.appendingPathComponent("debug")

    /// 词表优先取 app bundle 里的；`swift run` 时退回当前目录。
    static func dictURL() -> URL? {
        if let url = Bundle.main.url(forResource: "dict", withExtension: "bin") {
            return url
        }
        if let path = ProcessInfo.processInfo.environment["WENSHAN_DICT"] {
            return URL(fileURLWithPath: path)
        }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dict.bin")
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return nil
    }
}
