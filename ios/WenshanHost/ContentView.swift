import SwiftUI
import WenshanEngine

struct ContentView: View {
    @State private var text = ""
    @State private var engineStatus = "未加载"
    @State private var engineCandidates = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("启用键盘") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 文山")
                    Text("在输入框里长按地球键切换到文山。")
                        .foregroundStyle(.secondary)
                }
                Section("测试") {
                    TextField("在这里输入", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                }
                Section("引擎自检") {
                    Text(engineStatus)
                    Text(engineCandidates)
                        .foregroundStyle(.secondary)
                    Button("试打 womf") { checkEngine() }
                }
            }
            .navigationTitle("文山 iOS")
            .task {
                checkEngine()
            }
        }
    }

    /// 主 App 和键盘扩展是两个进程，这里读的是扩展 Bundle 里的词表，
    /// 只用来确认 Go 框架在 iOS 上能加载、能出候选。
    private func checkEngine() {
        let path = Bundle.main.bundlePath + "/PlugIns/WenshanKeyboard.appex/dict.bin"
        guard FileManager.default.fileExists(atPath: path) else {
            engineStatus = "找不到扩展里的 dict.bin"
            return
        }
        guard MobileOpen(path) else {
            engineStatus = "打开失败: \(MobileLastError())"
            return
        }
        let joined = MobileType("womf")
        engineCandidates = joined.isEmpty ? "没有候选" : joined.replacingOccurrences(of: "\n", with: " / ")
        engineStatus = "词表已加载"
    }
}
