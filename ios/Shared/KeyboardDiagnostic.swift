import Foundation
import UIKit
import Darwin.Mach
import OSLog

/// 键盘诊断日志：只记事件名和内存读数，不记按键、正文、候选或路径。
/// 键盘「突然消失」多半是 jetsam，phys_footprint 和可用余量是最有用的两行。
/// 需要完全访问才能写 App Group；写不进去时静默跳过，不影响输入。
final class KeyboardDiagnostic {
    var isEnabled = false
    private let fm = FileManager.default
    private let maxBytes = 1024 * 1024

    func log(_ event: String, memory: Bool = false) {
        guard isEnabled,
              let group = AppGroup.containerURL?.appendingPathComponent("Data", isDirectory: true)
        else { return }
        let url = group.appendingPathComponent("diagnostic.log")
        var line = "\(timestamp()) \(event)"
        if memory { line += " \(memoryFields())" }
        line += "\n"
        do {
            try fm.createDirectory(at: group, withIntermediateDirectories: true)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber, size.intValue > maxBytes {
                let backup = group.appendingPathComponent("diagnostic.log.1")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: url, to: backup)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        } catch {
            // 诊断失败不影响输入。
        }
    }

    private func timestamp() -> String {
        Date().ISO8601Format()
    }

    /// phys_footprint 是系统判断扩展是否超限用的数；avail 取 os_proc_available_memory。
    private func memoryFields() -> String {
        var usage: Int64 = 0
        var task = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &task) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        if result == KERN_SUCCESS { usage = Int64(task.phys_footprint) / (1024 * 1024) }
        let available = os_proc_available_memory()
        let avail = available == 0 ? "-" : "\(available / (1024 * 1024))MiB"
        return "mem=\(usage)MiB avail=\(avail)"
    }

    static func read() -> String {
        guard let group = AppGroup.containerURL?.appendingPathComponent("Data", isDirectory: true),
              let data = try? Data(contentsOf: group.appendingPathComponent("diagnostic.log"))
        else { return "还没有诊断记录" }
        let tailBytes = 16 * 1024
        if data.count <= tailBytes {
            return String(decoding: data, as: UTF8.self)
        }
        var slice = data.suffix(tailBytes)
        if let newline = slice.firstIndex(of: UInt8(ascii: "\n")) {
            slice = slice[slice.index(after: newline)...]
        }
        return "…（仅显示末尾记录）\n" + String(decoding: slice, as: UTF8.self)
    }

    static func clear() {
        guard let group = AppGroup.containerURL?.appendingPathComponent("Data", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: group.appendingPathComponent("diagnostic.log"))
        try? FileManager.default.removeItem(at: group.appendingPathComponent("diagnostic.log.1"))
    }
}
