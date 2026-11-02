import Foundation

/// 把扩展 Bundle 里的词表部署到 App Group。主 App 只搬文件，不链接 Go 引擎。
enum DictDeployer {
    enum DeployError: LocalizedError {
        case noAppGroup
        case noPlugIns
        case noSource

        var errorDescription: String? {
            switch self {
            case .noAppGroup:
                return "当前签名没有 App Group，检查 entitlements 和开发者账号"
            case .noPlugIns:
                return "宿主 App 里找不到扩展 Bundle"
            case .noSource:
                return "扩展 Bundle 里找不到 dict.bin"
            }
        }
    }

    /// 返回已部署的词表路径。词表大小和修改时间作为版本戳，
    /// 重新安装 App 后 mtime 变化，会触发一次重新部署。
    @discardableResult
    static func deploy() throws -> URL {
        guard let container = AppGroup.containerURL else {
            throw DeployError.noAppGroup
        }
        guard let plugins = Bundle.main.builtInPlugInsURL else {
            throw DeployError.noPlugIns
        }
        let source = plugins.appendingPathComponent("WenshanKeyboard.appex/dict.bin")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw DeployError.noSource
        }

        let destination = container.appendingPathComponent("dict.bin")
        let stampURL = container.appendingPathComponent("dict.version")
        let attributes = try fm.attributesOfItem(atPath: source.path)
        let size = attributes[.size] as? NSNumber ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)-\(Int(modified))"

        if fm.fileExists(atPath: destination.path),
           let current = try? String(contentsOf: stampURL, encoding: .utf8),
           current == stamp {
            return destination
        }

        let staging = container.appendingPathComponent("dict.bin.tmp")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return destination
    }
}
