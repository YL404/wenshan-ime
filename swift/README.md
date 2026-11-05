# 文山 Swift

macOS 版的实现。和 Go 版使用同一个 bundle id、安装路径、输入源和用户数据，装上去
系统里仍然是「文山」：不需要重新添加输入源，词频和短语也直接沿用。

## 结构

- `Sources/WenshanCore/`：词表、自然码、组句、纠错、词频、输入规则
- `Sources/WenshanSwift/`
  - `main.swift`：NSApplication + IMKServer，以及 `--register` / `--swap` /
    `--select` / `--disable` 安装子命令
  - `InputController.swift`：IMKInputController 子类，把事件转给 AppState
  - `AppState.swift`：按键分类、上屏、预编辑、光标、Shift 和模式提示
  - `CandidateWindow.swift`：NSPanel 候选条和模式 HUD
  - `InputSource.swift`：TIS 注册、选中、移除、原子交换 bundle
- `Resources/`：Info.plist 和输入源本地化名
- `scripts/`：构建、安装

## 构建与安装

```sh
sh swift/scripts/install.sh
```

脚本把 Swift 版装成默认的「文山」。目标位置还是 Go 版时，会先备份到
`~/Library/Application Support/Wenshan/backup/Wenshan-go.app`；已经添加过输入源的
机器直接覆盖安装，输入源和快捷键都不用改。

首次安装（或换机器）需要到 **系统设置 → 键盘 → 输入源** 添加「文山」。系统只允许
用户手动把新输入法加进列表；对没加过的 bundle，`TISEnableInputSource` 不生效。

签名默认用 ad-hoc。用本机开发者证书可以让系统把每次构建当成同一个应用，「允许启用」
的授权不会每次重置：

```sh
CODESIGN_IDENTITY="Apple Development: 你的名字 (XXXXXXXXXX)" sh swift/scripts/install.sh
```

## 测试

```sh
cd swift
swift test
swift test -c release --filter RealDictTests
```

真实词表用例需要仓库根目录的 `dict.bin`，没有就跳过。

## 已验证

- 已替换本机 Go 版：进程是 `~/Library/Input Methods/Wenshan.app/Contents/MacOS/Wenshan`，
  输入源仍是 `im.wenshan.inputmethod.Wenshan.Hans`，词频/短语沿用原目录。
- 规则层 55 个用例全过；真实 `dict.bin` 的候选输出与 Go 版逐字节一致。
- 候选窗：`nihk` 的 9 个候选、首位高亮、右端页码提示（深色外观截图验证；浅色分支
  按同一套逻辑选色，未单独截图）。
- TextEdit 端到端：`nihk` + 空格 → 你好；`ni` + 逗号 → 你，；`nihk` + PageDown
  + 空格 → 第二页首选；数字选词；回车原样上屏；`[` 取首字；`ni` + Shift+A +
  空格 → `niA `；Esc 取消组合。
- 升级后重新选中自己（客户端重连）正常。

## 回退到 Go 版

Go 版源码仍在根目录：

```sh
sh scripts/install.sh
```

也可以直接用备份恢复：

```sh
pkill -f "Input Methods/Wenshan.app"
rm -rf ~/Library/Input\ Methods/Wenshan.app
cp -R ~/Library/Application\ Support/Wenshan/backup/Wenshan-go.app \
	~/Library/Input\ Methods/Wenshan.app
sh scripts/repair.sh
```

## 和 Go 版的关系

macOS 默认已经是 Swift 版。Go 版源码保留在根目录，用于回退；iOS 键盘仍是 Go 内核
+ gomobile，规则层暂时没有共用。
