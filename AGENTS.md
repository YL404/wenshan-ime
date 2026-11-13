# AGENTS.md

## 提交规范

- 直接在本地 `main` 分支开发，不开分支、不主动推（授权后可推）。
- 做完一件事自己提交：一个逻辑改动一个提交，无关改动分开。
- 提交信息用中文，一句话说清为什么改，实现要点需要时再补一行。
- 改 Swift 代码提交前在 `swift/` 下跑 `swift build && swift test`，全绿再提交；改了 iOS 代码再跑 `sh ios/scripts/build.sh`。
- 改完 macOS 代码跑 `sh swift/scripts/install.sh` 装到本机。
- 只改文档时跳过这两步。
- `build/`、`dict.bin` 是生成物，已在 .gitignore，别手动加进来。

## 构建与验证

- `sh swift/scripts/build.sh` 构建 `build/Wenshan.app`；`sh swift/scripts/install.sh` 装成「文山」。
- 首次构建自动下载 rime-ice 词库，用 `swift/Sources/dictgen` 生成 `dict.bin`（约 17 MB）。
- 日志：`~/Library/Logs/Wenshan.log`。按键调试：`touch ~/Library/Application\ Support/Wenshan/debug` 后重启输入法。
- 项目结构和按键行为见 README.md。
