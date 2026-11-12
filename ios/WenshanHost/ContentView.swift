import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var dataStatus = "准备中…"
    @State private var freqCount = 0
    @State private var userCount = 0
    @State private var phraseCount = 0
    @State private var showClearConfirmation = false
    @State private var defaultMode = KeyboardSettings.defaultMode
    @State private var rememberMode = KeyboardSettings.rememberMode
    @State private var pageSize = KeyboardSettings.candidatePageSize
    @State private var accentName = KeyboardSettings.accentName
    @State private var dynamicFont = KeyboardSettings.dynamicCandidateFont
    @State private var spaceReverts = KeyboardSettings.spaceRevertsPunctuation
    @State private var hapticStrength = KeyboardSettings.hapticStrength
    @State private var diagnosticLog = KeyboardSettings.diagnosticLog
    @State private var diagnosticText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("启用键盘") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 第三方键盘 → 文山")
                    Text("在输入框里长按地球键切换到文山。")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(dataStatus)
                        .foregroundStyle(.secondary)
                    Text("词频 \(freqCount) 条 · 自造词 \(userCount) 条 · 短语 \(phraseCount) 条")
                    Button("刷新统计") { refreshData() }
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

                Section {
                    Picker("默认中英文", selection: $defaultMode) {
                        Text("中文").tag("chinese")
                        Text("English").tag("english")
                    }
                    .onChange(of: defaultMode) { _, value in
                        KeyboardSettings.defaultMode = value
                    }
                    Toggle("沿用上次的中英文", isOn: $rememberMode)
                        .onChange(of: rememberMode) { _, value in
                            KeyboardSettings.rememberMode = value
                            if !value { KeyboardSettings.lastMode = nil }
                        }
                    Stepper("每页候选数 \(pageSize)", value: $pageSize, in: 1...9)
                        .onChange(of: pageSize) { _, value in
                            KeyboardSettings.candidatePageSize = value
                        }
                    Picker("强调色", selection: $accentName) {
                        ForEach(["blue", "orange", "pink", "purple", "green", "teal", "red"], id: \.self) { name in
                            Text(Self.accentTitle(name)).tag(name)
                        }
                    }
                    .onChange(of: accentName) { _, value in
                        KeyboardSettings.accentName = value
                    }
                    Toggle("候选字号跟随系统文字大小", isOn: $dynamicFont)
                        .onChange(of: dynamicFont) { _, value in
                            KeyboardSettings.dynamicCandidateFont = value
                        }
                    Toggle("中文标点后按空格改回半角", isOn: $spaceReverts)
                        .onChange(of: spaceReverts) { _, value in
                            KeyboardSettings.spaceRevertsPunctuation = value
                        }
                    Picker("按键触感", selection: $hapticStrength) {
                        Text("跟随系统").tag("system")
                        Text("轻").tag("light")
                        Text("中").tag("medium")
                        Text("强").tag("heavy")
                    }
                    .onChange(of: hapticStrength) { _, value in
                        KeyboardSettings.hapticStrength = value
                    }
                } header: {
                    Text("键盘")
                } footer: {
                    Text("改动在键盘下次出现时生效；候选字号按系统文字大小缩放，键帽大小不变。")
                }

                Section {
                    Toggle("记录键盘诊断日志", isOn: $diagnosticLog)
                        .onChange(of: diagnosticLog) { _, value in
                            KeyboardSettings.diagnosticLog = value
                        }
                    Button("查看日志") { diagnosticText = KeyboardDiagnostic.read() }
                    Button("清空日志", role: .destructive) {
                        KeyboardDiagnostic.clear()
                        diagnosticText = ""
                    }
                    if !diagnosticText.isEmpty {
                        Text(diagnosticText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("只记事件名和内存读数，不含按键、正文或候选；需要完全访问才能写入共享目录。")
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

    private static func accentTitle(_ name: String) -> String {
        switch name {
        case "blue": return "蓝"
        case "orange": return "橙"
        case "pink": return "粉"
        case "purple": return "紫"
        case "green": return "绿"
        case "teal": return "青"
        case "red": return "红"
        default: return "蓝"
        }
    }
}
