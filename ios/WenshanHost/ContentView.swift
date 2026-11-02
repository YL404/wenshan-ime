import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var deployStatus = "准备中…"
    @State private var deployFailed = false
    @State private var dataStatus = "准备中…"
    @State private var freqCount = 0
    @State private var userCount = 0
    @State private var phraseCount = 0
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("启用键盘") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 第三方键盘 → 文山")
                    Text("在输入框里长按地球键切换到文山。")
                        .foregroundStyle(.secondary)
                }

                Section("词表") {
                    Text(deployStatus)
                        .foregroundStyle(deployFailed ? .red : .secondary)
                    Button("重新部署") { deploy() }
                }

                Section {
                    Text(dataStatus)
                        .foregroundStyle(.secondary)
                    Text("词频 \(freqCount) 条 · 自造词 \(userCount) 条 · 短语 \(phraseCount) 条")
                    Button("清空学习记录", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .disabled(freqCount == 0 && userCount == 0)
                } header: {
                    Text("用户数据")
                } footer: {
                    Text("词频和自造词只保存在本机；清空后重新打开键盘生效，短语文件 phrases.tsv 不会被清空。")
                }

                Section("完全访问（可选）") {
                    Text("开启后，键盘才能把学习记录写进共享目录，主 App 这里也能看到统计数据。不联网、不上传。")
                        .foregroundStyle(.secondary)
                }

                Section("测试") {
                    TextField("在这里输入", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                }
            }
            .navigationTitle("文山")
            .task {
                deploy()
                refreshData()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshData() }
            }
            .confirmationDialog("清空本机学习记录？", isPresented: $showClearConfirmation) {
                Button("清空", role: .destructive) { clearLearning() }
            } message: {
                Text("会删除词频和自造词，不影响词表与短语。")
            }
        }
    }

    /// 主 App 只把扩展里的词表复制到 App Group，不加载 Go 引擎。
    private func deploy() {
        do {
            let url = try DictDeployer.deploy()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            deployStatus = "已部署 \(size / 1_048_576) MB"
            deployFailed = false
        } catch {
            deployStatus = "部署失败：\(error.localizedDescription)"
            deployFailed = true
        }
    }

    private func refreshData() {
        guard let directory = AppGroup.dataDirectoryURL else {
            dataStatus = "未使用 App Group，学习记录只保存在键盘里"
            freqCount = 0
            userCount = 0
            phraseCount = 0
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        dataStatus = "已连接 App Group"
        freqCount = lineCount(directory.appendingPathComponent("freq.tsv"))
        userCount = lineCount(directory.appendingPathComponent("userdict.tsv"))
        phraseCount = lineCount(directory.appendingPathComponent("phrases.tsv"))
    }

    private func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }.count
    }

    private func clearLearning() {
        guard let directory = AppGroup.dataDirectoryURL else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: directory.appendingPathComponent("freq.tsv"))
        try? fm.removeItem(at: directory.appendingPathComponent("userdict.tsv"))
        refreshData()
    }
}
