# 文山输入法

macOS 上自用的双拼自然码输入法。纯 Go，无 cgo，不依赖外部输入法引擎：词表在构建时
编译进可执行文件，每次按键一次二分查找。

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
| 单个字母 | 一级简码：`l`→了、`w`→我、`d`→的、`b`→不、`n`→你 |
| 1-9 | 选候选 |
| 空格 | 上屏首选 |
| 回车 | 上屏原始编码（中文状态直接打英文：打 `abc` 回车得 abc） |
| 退格 / Esc | 删一键 / 放弃本次输入 |
| Shift 轻点 | 中英切换 |
| Shift+空格 | 全角 / 半角标点切换 |
| 标点 | 转中文全角，引号成对交替 |

带 Command/Control/Option 的组合键一律交给应用。

## 结构

```
main_darwin.go        进程启动：加载框架、注册输入法类、建 IMKServer
imk_darwin.go         按键分类、预编辑、上屏、中英与空格状态
candidate_darwin.go   候选窗：圆角面板 + 每个候选一个色块
objc_darwin.go        purego/objc 选择器与类型转换
punct.go              中文标点表
tis_darwin.go         启动后重新选中自身，逼前台应用重连
engine/               自然码键位、词表二分查找、组句、词频、自造词
cmd/dictgen           Rime 词表 → dict.bin
cmd/icon              生成山形图标
cmd/tisprobe          输入源诊断（列表、选中、启用、重注册）
cmd/swap              安装时原子交换 Contents，避免输入源失效
packaging/            Info.plist 与本地化资源
scripts/              构建、安装、修词库、修复
```

## 几个设计取舍

**不用 librime。** 个人自用只有一个方案，librime 的灵活性用不上，代价却是 CMake 编译
C++、手写几十个函数绑定、YAML 配置。自建词表引擎只要一次二分查找，单键 0.3 微秒。

**候选窗用 AppKit，不用图形框架。** 一条候选条不需要 GPU 自绘，`NSPanel` 加几个
`NSTextField` 就够，启动和内存都省。

**热路径不跨进程。** `handleEvent` 里只做：分类按键 → 查词 → 刷新候选窗 → 写回预编辑。
剩下的耗时是前台应用排版预编辑串，任何输入法都一样。

## 词表

`rime-ice`（GPL-3.0）的 `8105` + `base` + `others`，约 55 万条。每个音节转成两键编码，
主表按编码排序供二分；另存 26 个字母的单键候选（一级简码优先）。

选过的词记在 `~/Library/Application Support/Wenshan/freq.tsv`，一次组合里连续单字
选词会记成自造词存在同目录的 `userdict.tsv`。删掉文件即清空。

## 出问题时

症状：切到文山打不出候选，只有英文。

```sh
sh scripts/repair.sh
```

清理残留进程、重新注册 bundle、启用输入源。日志在 `~/Library/Logs/Wenshan.log`；
要打印每个按键，先 `touch ~/Library/Application\ Support/Wenshan/debug` 再重启输入法。

## 限制

- 只做 macOS、只做双拼自然码。
- 没有真正的语言模型，长句靠词库和词频，个别同音组合会排错序。
- 英文模式只在当前进程内有效。
