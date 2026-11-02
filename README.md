# 文山输入法

macOS 上的双拼输入法，键位为自然码。纯 Go 实现，无 cgo，也不依赖 librime 之类的
输入法引擎：词表在构建时编译进可执行文件，每次按键只是一次二分查找。

<!-- 有截图后放到 docs/screenshot.png 并取消注释：
![候选窗](docs/screenshot.png)
-->

## 特性

- **轻快**：单进程，按键处理不跨进程；词表按编码排序，单键查询约 0.3 µs。
- **零外部依赖**：不用 librime，不用 CMake，`go build` 即可构建；词表打包进二进制，装完即用。
- **双拼自然码**：每音节两键，支持一级简码（`l`→了、`w`→我、`d`→的、`b`→不、`n`→你）。
- **越用越顺手**：选词自动记词频，一次组合里连续单字选词自动记成自造词。
- **中文标点**：默认全角、引号成对交替，Shift+空格 切换全半角。

## 安装

```sh
sh scripts/install.sh
```

首次会下载 rime-ice 词库并编译成 `dict.bin`（约 17 MB，已 gitignore）。

签名默认用 ad-hoc（`-`）。用本机开发者证书签名可以让系统把每次构建当成同一个应用，
「允许启用」的授权不会每次重置：

```sh
CODESIGN_IDENTITY="Apple Development: 你的名字 (XXXXXXXXXX)" sh scripts/install.sh
```

然后在 **系统设置 → 键盘 → 输入源 → + → 中文（简体）→ 文山** 添加，
点「允许」授权，Control-空格 切换。

卸载：

```sh
pkill -f "Input Methods/Wenshan.app"; rm -rf ~/Library/Input\ Methods/Wenshan.app
```

## 按键

| 按键 | 行为 |
|---|---|
| 字母 | 双拼自然码，每音节两键 |
| 1-9 | 选候选 |
| 空格 | 上屏首选 |
| 回车 | 上屏原始编码（中文状态直接打英文：打 `abc` 回车得 abc） |
| 退格 / Esc | 删一键 / 放弃本次输入 |
| Shift 轻点 | 中英切换 |
| Shift+空格 | 全角 / 半角标点切换 |
| 标点 | 转中文全角，引号成对交替 |

带 Command/Control/Option 的组合键一律交给应用。

## 实现原理

一次按键的路径：IMKServer 收到事件 → `imk_darwin.go` 分类按键 → `engine` 查词表、
组句 → `candidate_darwin.go` 刷新候选窗 → 写回预编辑。全程不跨进程，剩下的耗时是
前台应用排版预编辑串，任何输入法都一样。

```
main/imk/tis/objc/candidate    macOS 输入法壳：IMK 注册、按键处理、候选窗、输入源管理
engine/                        自然码键位、词表二分查找、组句、词频、自造词
cmd/dictgen                    Rime 词表 → dict.bin
cmd/icon、tisprobe、swap        图标生成、输入源诊断、安装时原子交换 Contents
packaging/ scripts/            Info.plist 与本地化资源；构建、安装、修复脚本
```

词表流水线：`scripts/fetch-dict.sh` 下载 rime-ice 的 `8105` + `base` + `others`
（约 55 万条），`cmd/dictgen` 把每个音节转成两键编码，主表按编码排序供二分查找，
另存 26 个字母的单键候选（一级简码优先）。

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

## 疑难解答

症状：切到文山打不出候选，只有英文。

```sh
sh scripts/repair.sh
```

清理残留进程、重新注册 bundle、启用输入源。日志在 `~/Library/Logs/Wenshan.log`；
要打印每个按键，先 `touch ~/Library/Application\ Support/Wenshan/debug` 再重启输入法。

## 已知限制

- 只做 macOS、只做双拼自然码。
- 没有真正的语言模型，长句靠词库和词频，个别同音组合会排错序。
- 英文模式只在当前进程内有效。

## 许可

词表来自 [rime-ice](https://github.com/iDvel/rime-ice)（GPL-3.0），因此本项目整体以
GPL-3.0 发布，词表版权归 rime-ice 作者所有。
