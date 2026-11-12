<img src="assets/icon.png" width="128" align="right" alt="文山输入法图标">

<h1>文山输入法<br clear="right"></h1>

macOS 上的双拼输入法，另有 iOS 键盘扩展。键位为自然码。两端都是 Swift 实现，共用
同一套规则层；不依赖 librime 之类的输入法引擎，中英文词表在构建时编译进 app，每次按键
只是几次二分查找。

## 特性

- **轻快**：单进程，按键处理不跨进程；词表按编码排序，二分定位。真实词表上每次按键
  （查词 + 组句 + 纠错）release 约 25–60 µs，远低于一帧。
- **零外部依赖**：不用 librime，不用 CMake；只要 Xcode 自带的 Swift 工具链，中英文词表和
  图标也由同一个 Swift 包里的工具生成。
- **双拼自然码**：每音节两键，支持一级简码（`l`→了、`w`→我、`d`→的、`b`→不、`n`→你）。
- **单字辅码**：单字两键后可再打 1-2 位部首辅码，`ni` → `nir` → `nirx`，同音字不用翻。
- **候选翻页**：一页 9 个，`=` / `-` 或 PageDown / PageUp 翻页，最多 20 页；候选窗开着时
  这两个键只翻页，不当作字符上屏。
- **打快了也不怕**：按错一键多半仍是合法编码，纠错候选补在正常候选后面；打完词组
  接着打下个声母，组句把它延展成完整音节接着预测。
- **中英混输**：中文态直接打英文单词，词库里的词出现在候选里（`hello` 精确命中排第 2，
  `api` 这类短词也收）；Shift+字母追加到组合缓冲，段首大写推导 `Hello` / `HELLO`，
  词中间大写（`i` + Shift+`P`）也保留，`GitHub`、`MacBook`、`iPhone` 这类混排专名由
  词库形态直接给出。回车仍可把原始编码上屏。
- **越用越顺手**：选词自动记词频和「上个字 → 这个词」的接续，一次组合里连续单字选词自动记成自造词。
- **常用短语**：`phrases.tsv` 里按「编码<TAB>文本」放邮箱、地址，输入编码直接置顶。
- **中文标点**：默认全角、引号成对交替，`/` 或 `\` 打顿号，数字后的句号保持半角，
  Shift+空格 切换全半角。

## 安装

```sh
sh swift/scripts/install.sh
```

首次会下载 rime-ice 词库并编译成 `dict.bin`（约 17 MB，已 gitignore）。安装沿用
固定的 bundle id、输入源和 `~/Library/Application Support/Wenshan` 下的词频/短语，
覆盖安装不用重新添加输入源。

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

## iOS

`ios/` 下是 Swift 6 键盘扩展，直接复用 `swift/Sources/WenshanCore` 的规则层。
键盘底板用系统 `UIInputView` 的原生材质，候选字号跟随 Dynamic Type，强调色可在宿主
App 里选；预编辑作为 marked text 写进输入框，候选条只显示词块与展开键。已接通
中英切换、Shift、符号页、按键预览、删除长按按音节退、空格拖光标、触点纠错、
成对标点与智能标点、候选长按置顶/删除、每页候选数和诊断日志，以及用户词频/
自造词/短语加载；仍在模拟器验证阶段，真机内存和发布化未完成。构建、无头模拟器
验证和已知限制见
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
| 回车 | 上屏原始编码（中文状态直接打英文：打 `abc` 回车得 abc，不切模式） |
| 退格 / Esc | 删一键 / 放弃本次输入 |
| Shift + 字母 | 中文态追加到组合缓冲，大小写保留在预编辑里，单词出现在候选中 |
| Shift 轻点 | 中英切换 |
| Shift+空格 | 全角 / 半角标点切换 |
| 标点 | 转中文全角，引号成对交替；数字后的句号保持半角 |
| `\` 或 `/` | 顿号（、） |

带 Command/Control/Option 的组合键一律交给应用。Shift+字母一律追加到组合态，不再直接
上屏，也不会吞掉已打的小写字母（`i` + Shift+`P` 接着打 `hone` 得 `iPhone`）；英文词按
小写编码查独立词表，2 个字母以上的精确命中插在中文首选之后，5 个字母以上的前缀补全
追加到候选末尾，词表不认识时给一条原文兜底。段首大小写按输入推导：首字母大写得
`Hello`，前两个字母大写得 `HELLO`；词中间大写按词库形态直出。空格选首选、回车上屏
原始编码、退格 / Esc 可改。翻到首页或末页就停住；候选窗开着时 `=`、`-` 由输入法接管，
不会作为字符上屏。

## 实现原理

一次按键的路径：IMKServer 收到事件 → `InputController` → `AppState` 分类按键 →
`WenshanCore` 查词表、组句 → `CandidateWindow` 刷新候选窗 → 写回预编辑。全程不跨
进程，剩下的耗时是前台应用排版预编辑串，任何输入法都一样。

```
swift/Sources/WenshanCore      规则层：自然码、词表、组句、纠错、词频、输入规则（macOS 和 iOS 共用）
swift/Sources/WenshanSwift     macOS 壳：IMK 注册、按键处理、候选窗、输入源
swift/Sources/dictgen          Rime 词库 → dict.bin，英文词库 → english.bin
swift/Sources/icon             App 图标、输入源图标、iOS AppIcon
ios/                           iOS 宿主 App 和键盘扩展
scripts/                       下载词库、一键修复
```

词表流水线：`scripts/fetch-dict.sh` 下载 rime-ice 的 `8105` + `base` + `others`
（约 55 万条）和 `en` + `en_ext` 英文词库（约 2.2 万条），`dictgen` 把中文音节转成
两键编码、英文词按小写编码排序，分别生成 `dict.bin` 和 `english.bin` 供二分查找，
中文表另存 26 个字母的单键候选（一级简码优先）。单字辅码表来自 rime-frost 的
`moqi_aux_code.txt`，按 2+1 / 2+2 生成三码、四码条目。两张表编码空间不同，分开存，
英文候选不会污染双拼组句和辅码判断。

## 设计取舍

**不用 librime。** 个人自用只有一个方案，librime 的灵活性用不上，代价却是 CMake 编译
C++、手写几十个函数绑定、YAML 配置。自建词表引擎只要一次二分查找。

**候选窗用 AppKit，不用图形框架。** 一条候选条不需要 GPU 自绘，`NSPanel` 加几个
`NSTextField` 就够，启动和内存都省。

**热路径不跨进程。** 分类按键 → 查词 → 刷新候选窗 → 写回预编辑，全在 `handleEvent`
里完成；再往下只能优化前台应用那部分，不属于输入法。

## 词库与用户数据

选过的词记在 `~/Library/Application Support/Wenshan/freq.tsv`：两列「词<TAB>次数」是词频，
三列「上文末字<TAB>词<TAB>次数」是接续，输入法用它把常接着上一个词出现的候选往前排；
上屏的多字词还会拆出内部相邻字接续，组句时按「前段末字 → 本段」逐段加权。接续靠实际
选词积累，冷启动时没有加成。一次组合里连续单字选词会记成自造词存在同目录的
`userdict.tsv`。删掉文件即清空。

自定义短语放在同目录的 `phrases.tsv`，每行「编码<TAB>文本」，空行和 `#` 开头的行忽略，
编码用小写字母。固定大小写的英文专名也放这里，例如 `myteam<TAB>MyTeam`、
`iosban<TAB>iOS版`（`iPhone`、`GitHub` 等常见专名已在英文词库里，不必另加）。短语只读，
不会被写回；改完切到别的输入源再切回文山就会重新读入。

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
- Shift+字母一律先进组合态，打单个大写字母也要按空格 / 回车上屏；轻点 Shift 切到英文直通。
- 没有真正的语言模型，长句靠词库、词频和本地学到的逐段接续，个别同音组合仍会排错序。
- 英文词表收的是常见词和专名，生僻词、缩写变体可能查不到；这时回车仍能上屏原始编码。
- 英文模式只在当前进程内有效。

## 实现

结构、构建和验证见 [swift/README.md](swift/README.md)。

## 许可

中文词表和英文词表都来自 [rime-ice](https://github.com/iDvel/rime-ice)（GPL-3.0），
单字辅码表来自 [rime-frost](https://github.com/gaboolic/rime-frost) 的墨奇部首码
（GPL-3.0），因此本项目整体以 GPL-3.0 发布，词表和辅码表版权归各自作者所有。
完整许可证文本见 [LICENSE](LICENSE)。
