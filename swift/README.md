# 文山 Swift 内核

`engine/` 和 `input/` 的 Swift 移植。目前只有规则层，macOS 的 IMK 壳仍是 Go 版，
下一步才换。

## 结构

- `Sources/WenshanCore/Dict.swift`：词表格式、二分查找、组句、单键简码
- `Sources/WenshanCore/Ziranma.swift`：自然码编码
- `Sources/WenshanCore/Typo.swift`：邻键纠错
- `Sources/WenshanCore/Freq.swift`、`UserDict.swift`：词频与自造词
- `Sources/WenshanCore/Engine.swift`：候选流、翻页、选词学习
- `Sources/WenshanCore/Session.swift`：标点、中英模式、Shift、临时英文、补空格

## 构建与测试

```sh
cd swift
swift test
```

真实词表的用例需要仓库根目录的 `dict.bin`，没有就跳过（先跑 `sh scripts/build.sh`）。
性能用例只在 release 下跑：

```sh
swift test -c release --filter RealDictTests
```

## 和 Go 版的关系

Go 版仍是实际安装的输入法。Swift 包的 55 个用例逐条对应 `engine/`、`input/` 的
测试；真实 `dict.bin` 上的候选输出做过逐字节差分。macOS 壳和 iOS 桥还没迁移。
