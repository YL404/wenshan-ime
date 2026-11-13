# 文山 Swift

规则层、macOS 输入法和构建工具。bundle id、安装路径、输入源和用户数据目录固定不变，
覆盖安装后系统里仍然是「文山」：不需要重新添加输入源，词频和短语也直接沿用。

## 结构

- `Sources/WenshanCore/`：中文词表、英文词表、自然码、组句、纠错、词频、输入规则；iOS 键盘也直接链接它。
  组句按「前段末字 → 本段」接续选词，英文候选由独立词表按小写编码查询，大小写按输入推导。
  `Session.swift` 还管成对标点补全与跨过、两秒内重按标点转中文、中文标点后按空格改回半角、
  长按按音节退格；`KeyGeometry.swift` 记录字母键矩形与落点，纠错按「离目标键心更近」加权。
  候选页大小（1–9）与候选置顶/删除（连词频、自造词一起清）也在规则层，iOS 壳只是转发偏好和手势
- `Sources/WenshanSwift/`
  - `main.swift`：NSApplication + IMKServer，以及 `--register` / `--swap` /
    `--select` / `--enable` / `--disable` 安装和修复子命令
  - `InputController.swift`：IMKInputController 子类，把事件转给 AppState
  - `AppState.swift`：按键分类、上屏、预编辑、光标、Shift 和模式提示
  - `CandidateWindow.swift`：NSPanel 候选条和模式 HUD
  - `InputSource.swift`：TIS 注册、选中、启用、移除、原子交换 bundle
- `Sources/dictgen/`：把 Rime 中文词库和单字辅码表编译成 `dict.bin`，把 rime-ice 英文词库
  编译成 `english.bin`；同一份输入每次生成的文件逐字节相同
- `Sources/icon/`：画 App 图标、输入源图标和 iOS AppIcon，扫描线填充，不依赖绘图库
- `Resources/`：Info.plist 和输入源本地化名
- `scripts/`：构建、安装

## 构建与安装

```sh
sh swift/scripts/install.sh
```

已经添加过输入源的机器直接覆盖安装，输入源和快捷键都不用改。

首次安装（或换机器）需要到 **系统设置 → 键盘 → 输入源** 添加「文山」。系统只允许
用户手动把新输入法加进列表；对没加过的 bundle，`TISEnableInputSource` 不生效。

签名默认用 ad-hoc。用本机开发者证书可以让系统把每次构建当成同一个应用，「允许启用」
的授权不会每次重置：

```sh
CODESIGN_IDENTITY="Apple Development: 你的名字 (XXXXXXXXXX)" sh swift/scripts/install.sh
```

单独重新生成词表或图标：

```sh
sh scripts/fetch-dict.sh
swift run -c release --package-path swift dictgen -o dict.bin \
	-aux build/aux/moqi_aux_code.txt \
	build/rime-ice/8105.dict.yaml build/rime-ice/base.dict.yaml build/rime-ice/others.dict.yaml
swift run -c release --package-path swift dictgen -english -o english.bin \
	build/rime-ice/en.dict.yaml build/rime-ice/en_ext.dict.yaml
swift run -c release --package-path swift icon \
	-out build/Wenshan.iconset -menu-out build/WenshanMenu.iconset -preview assets/icon.png
```

## 测试

```sh
cd swift
swift test
swift test -c release --filter RealDictTests
```

真实词表用例需要仓库根目录的 `dict.bin`，没有就跳过。

## 已验证

- 进程是 `~/Library/Input Methods/Wenshan.app/Contents/MacOS/Wenshan`，
  输入源是 `im.wenshan.inputmethod.Wenshan.Hans`，词频/短语在原目录。
- 规则层用例全过；Swift `dictgen` 生成的 `dict.bin` 和原来的 Go 版条目、表头、简码表
  完全一致（同编码同权重的条目改成按词条排序，原来这部分顺序每次生成都不同）；
  `icon` 生成的图标和 Go 版逐像素对比，最大差 1/255（PNG 编码器的取整差异）。
- `TouchAndGestureTests` 覆盖音节退格、候选页大小、重复标点转中文、空格改回半角、
  成对标点跨过、候选置顶/删除和触点纠错加权；这些用例不依赖真实词表。
- 候选窗：`nihk` 的 9 个候选、首位高亮、右端页码提示。
- TextEdit 端到端：`nihk` + 空格 → 你好；`ni` + 逗号 → 你，；`nihk` + PageDown
  + 空格 → 第二页首选；数字选词；回车原样上屏；`[` 取首字；`hello` 候选第 2 位
  出 `hello`；Shift+H 接着打 `ello` 出 `Hello`；`i` + Shift+P + `hone` 出 `iPhone`；
  Esc 取消组合。
- 升级后重新选中自己（客户端重连）正常。
- iOS 键盘扩展直接链接 `WenshanCore`；无头模拟器里点 `nihk` + 空格上屏「你好」。
