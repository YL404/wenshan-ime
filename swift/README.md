# 文山 Swift

`engine/`、`input/` 规则层和 macOS IMK 壳的 Swift 移植。和 Go 版并存：bundle id
不同（`im.wenshan.inputmethod.WenshanSwift`），可以同时安装、在输入源里切换。

## 结构

- `Sources/WenshanCore/`：词表、自然码、组句、纠错、词频、输入规则
- `Sources/WenshanSwift/`
  - `main.swift`：NSApplication + IMKServer，以及 `--register` / `--swap` 安装子命令
  - `InputController.swift`：IMKInputController 子类，把事件转给 AppState
  - `AppState.swift`：按键分类、上屏、预编辑、光标、Shift 和模式提示
  - `CandidateWindow.swift`：NSPanel 候选条和模式 HUD
  - `InputSource.swift`：TIS 注册、重新选中自己、原子交换 bundle
- `Resources/`：Info.plist 和输入源本地化名
- `scripts/`：构建、安装

## 构建与安装

```sh
sh swift/scripts/build.sh     # 生成 build/WenshanSwift.app
sh swift/scripts/install.sh   # 装到 ~/Library/Input Methods
```

首次安装后到 **系统设置 → 键盘 → 输入源** 添加「文山 Swift」。系统只允许用户
手动把新输入法加进列表；对没加过的 bundle，`TISEnableInputSource` 不生效。

## 测试

```sh
cd swift
swift test
swift test -c release --filter RealDictTests
```

真实词表用例需要仓库根目录的 `dict.bin`，没有就跳过。

## 已验证

- 规则层 55 个用例全过；真实 `dict.bin` 的候选输出与 Go 版逐字节一致。
- 候选窗：`nihk` 的 9 个候选、首位高亮、右端页码提示（深色外观截图验证；浅色分支按同一套逻辑选色，未单独截图）。
- TextEdit 端到端：`nihk` + 空格 → 你好；`ni` + 逗号 → 你，；`nihk` + PageDown
  + 空格 → 第二页首选；数字选词；回车原样上屏；`[` 取首字；`ni` + Shift+A +
  空格 → `niA `；Esc 取消组合。
- 输入源本地化名、升级后重新选中自己（客户端重连）都正常。

## 和 Go 版的关系

Go 版仍是默认安装的输入法。Swift 版用独立用户数据目录
`~/Library/Application Support/WenshanSwift`，不会和 Go 版互相覆盖词频。要沿用
Go 版的短语：

```sh
mkdir -p ~/Library/Application\ Support/WenshanSwift
cp ~/Library/Application\ Support/Wenshan/phrases.tsv ~/Library/Application\ Support/WenshanSwift/
```

iOS 还没动，仍是 Go 内核 + gomobile。
