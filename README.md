<img src="assets/icon.png" width="128" align="right" alt="文山输入法图标">

<h1>文山输入法<br clear="right"></h1>

macOS 上的双拼输入法，另有 iOS 键盘扩展。键位为自然码。macOS 版是 Swift 实现，
规则层移植自同仓库的 Go 版；不依赖 librime 之类的输入法引擎，词表在构建时编译进
app，每次按键只是一次二分查找。

## 特性

- **轻快**：单进程，按键处理不跨进程；词表按编码排序，二分定位。真实词表上每次按键
  （查词 + 组句 + 纠错）Go 版约 5–30 µs，Swift 版 release 约 50–125 µs，都远低于一帧。
- **零外部依赖**：不用 librime，不用 CMake；macOS 版 `swift build` 即可构建，词表打包进 app。
- **双拼自然码**：每音节两键，支持一级简码（`l`→了、`w`→我、`d`→的、`b`→不、`n`→你）。
- **单字辅码**：单字两键后可再打 1-2 位部首辅码，`ni` → `nir` → `nirx`，同音字不用翻。
- **候选翻页**：一页 9 个，`=` / `-` 或 PageDown / PageUp 翻页，最多 20 页；候选窗开着时
  这两个键只翻页，不当作字符上屏。
- **打快了也不怕**：按错一键多半仍是合法编码，纠错候选补在正常候选后面；打完词组
  接着打下个声母，组句把它延展成完整音节接着预测。
- **中英混输**：中文态按 Shift+大写直接打英文，不切模式；有拼音时把已打编码接进临时英文，
  再从大写字母继续，空格/回车结束，可退格修改；中英文紧挨时自动补空格。
- **越用越顺手**：选词自动记词频，一次组合里连续单字选词自动记成自造词。
- **常用短语**：`phrases.tsv` 里按「编码<TAB>文本」放邮箱、地址，输入编码直接置顶。
- **中文标点**：默认全角、引号成对交替，`/` 或 `\` 打顿号，数字后的句号保持半角，
  Shift+空格 切换全半角。

## 安装

```sh
sh swift/scripts/install.sh
```

首次会下载 rime-ice 词库并编译成 `dict.bin`（约 17 MB，已 gitignore）。脚本把 Swift
版装成默认的「文山」，沿用原来的 bundle id、输入源和
`~/Library/Application Support/Wenshan` 下的词频/短语。目标位置还是 Go 版时，会先
备份到 `~/Library/Application Support/Wenshan/backup/Wenshan-go.app`。

签名默认用 ad-hoc。用本机开发者证书可以让系统把每次构建当成同一个应用，「允许启用」
的授权不会每次重置：

```sh
CODESIGN_IDENTITY="Apple Development: 你的名字 (XXXXXXXXXX)" sh swift/scripts/install.sh
```

首次安装需要在 **系统设置 → 键盘 → 输入源 → + → 中文（简体）→ 文山** 添加并点
「允许」。已经添加过的机器直接覆盖安装，输入源不变，Control-空格 切换。

卸载：

```sh
pkill -f "Input Methods/Wenshan.app"; rm -rf ~/Library/Input\ Methods/Wenshan.app
```

### Go 版（回退用）

Go 版源码仍在根目录，`sh scripts/install.sh` 可以重新装回 Go 版；它会覆盖同一个
`Wenshan.app`，输入源 ID 不变。

## iOS

`ios/` 下是 Go 内核 + Swift 6 键盘扩展，复用同一个 `engine/` 和 `input/`
规则层。已接通 App Group 词表部署、候选条编码区、中英切换、Shift、符号页、按键预览、
删除连发、空格拖光标和 iPad 分档布局，以及用户词频/自造词/短语加载；仍在模拟器验证
阶段，真机内存和发布化未完成。构建、无头模拟器验证和已知限制见
[ios/README.md](ios/README.md)。

## 按键

| 按键 | 行为 |
|---|---|
| 字母 | 双拼自然码，每音节两键 |
| 字母 + 辅码 | 单字先用两键，再追加 1-2 位部首辅码 |
| 1-9 | 选当前页候选 |
| = / PageDown | 下一页候选 |
| - / PageUp | 上一页候选 |
| [ / ] | 取当前候选首字 / 尾字 |
| 空格 | 上屏首选 |
| 回车 | 上屏原始编码（中文状态直接打英文：打 `abc` 回车得 abc） |
| 退格 / Esc | 删一键 / 放弃本次输入 |
| Shift + 字母 | 中文态直接上屏大写英文；有未上屏编码时接进临时英文 |
| Shift 轻点 | 中英切换 |
| Shift+空格 | 全角 / 半角标点切换 |
| 标点 | 转中文全角，引号成对交替；数字后的句号保持半角 |
| `\` 或 `/` | 顿号（、） |

带 Command/Control/Option 的组合键一律交给应用。没有未上屏编码时，Shift + 字母直接
上屏单个大写字母；正在打拼音时，把已打编码接进临时英文：后续字母都按英文显示，空格
结束并补空格，回车结束不补空格（适合紧接中文），退格 / Esc 可改。临时英文从已有拼音
缓冲开始，所以首字母大写的 `GitHub`、`MacBook` 不会触发，用短语或 Shift 轻点切英文。
翻到首页或末页就停住；候选窗开着时 `=`、`-` 由输入法接管，不会作为字符上屏。

## 实现原理

一次按键的路径：IMKServer 收到事件 → `InputController` → `AppState` 分类按键 →
`WenshanCore` 查词表、组句 → `CandidateWindow` 刷新候选窗 → 写回预编辑。全程不跨
进程，剩下的耗时是前台应用排版预编辑串，任何输入法都一样。

```
swift/Sources/WenshanCore      Swift 规则层：自然码、词表、组句、纠错、词频、输入规则
swift/Sources/WenshanSwift     Swift macOS 壳：IMK 注册、按键处理、候选窗、输入源
engine/ input/                 Go 规则层（iOS 键盘仍在使用，macOS 版回退用）
main/imk/tis/objc/candidate    Go 版 macOS 壳（回退用）
cmd/dictgen                    Rime 词表 → dict.bin
cmd/icon、tisprobe、swap        图标生成、输入源诊断、原子交换 Contents
packaging/ scripts/            Go 版 Info.plist、构建/安装/修复脚本
```

词表流水线：`scripts/fetch-dict.sh` 下载 rime-ice 的 `8105` + `base` + `others`
（约 55 万条），`cmd/dictgen` 把每个音节转成两键编码，主表按编码排序供二分查找，
另存 26 个字母的单键候选（一级简码优先）。单字辅码表来自 rime-frost 的
`moqi_aux_code.txt`，按 2+1 / 2+2 生成三码、四码条目。

## 设计取舍

**不用 librime。** 个人自用只有一个方案，librime 的灵活性用不上，代价却是 CMake 编译
C++、手写几十个函数绑定、YAML 配置。自建词表引擎只要一次二分查找。

**候选窗用 AppKit，不用图形框架。** 一条候选条不需要 GPU 自绘，`NSPanel` 加几个
`NSTextField` 就够，启动和内存都省。

**热路径不跨进程。** 分类按键 → 查词 → 刷新候选窗 → 写回预编辑，全在 `handleEvent`
里完成；再往下只能优化前台应用那部分，不属于输入法。

## 词库与用户数据

选过的词记在 `~/Library/Application Support/Wenshan/freq.tsv`，一次组合里连续单字
选词会记成自造词存在同目录的 `userdict.tsv`。删掉文件即清空。

自定义短语放在同目录的 `phrases.tsv`，每行「编码<TAB>文本」，空行和 `#` 开头的行忽略，
编码用小写字母。固定大小写的英文专名也放这里，例如 `iphone<TAB>iPhone`、
`github<TAB>GitHub`、`iosban<TAB>iOS版`。短语只读，不会被写回；改完重启输入法生效。

## 疑难解答

症状：切到文山打不出候选，只有英文。

```sh
sh scripts/repair.sh
```

清理残留进程、重新注册 bundle、启用输入源。日志在 `~/Library/Logs/Wenshan.log`；
要打印每个按键，先 `touch ~/Library/Application\ Support/Wenshan/debug` 再重启输入法。

## 已知限制

- 只做双拼自然码，不做其他键位方案。
- 单字辅码只覆盖词库里已有的常用字，生僻字可能没有。
- 没有真正的语言模型，长句靠词库和词频，个别同音组合会排错序。
- 临时英文从已有拼音缓冲开始，首字母大写的混合大小写词（`GitHub`、`MacBook`）要用短语或切英文。
- 英文模式只在当前进程内有效。

## 实现

macOS 版是 `swift/` 下的 Swift 实现，bundle id 与旧 Go 版相同，安装后系统里仍是
「文山」。Go 版源码保留在根目录，用于回退和 iOS 键盘。结构、构建和验证见
[swift/README.md](swift/README.md)。

## 许可

词表来自 [rime-ice](https://github.com/iDvel/rime-ice)（GPL-3.0），单字辅码表来自
[rime-frost](https://github.com/gaboolic/rime-frost) 的墨奇部首码（GPL-3.0），因此本项目
整体以 GPL-3.0 发布，词表和辅码表版权归各自作者所有。完整许可证文本见 [LICENSE](LICENSE)。
