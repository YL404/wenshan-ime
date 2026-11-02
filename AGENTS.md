# AGENTS.md

## 提交规范

- 直接在本地 `main` 分支开发，不开分支、不推远端。
- 做完一件事自己提交：一个逻辑改动一个提交，无关改动分开。
- 提交信息用中文，一句话说清为什么改，实现要点需要时再补一行。
- 改 Go 代码时提交前跑 `go vet ./... && go build ./... && go test ./...`，全绿再提交；只改 README、AGENTS 等文档不用跑。
- 改完输入法代码跑 `sh scripts/install.sh` 替换安装版本，供用户直接体验。
- `build/`、`dict.bin` 是生成物，已在 .gitignore，别手动加进来。

## 构建与验证

- `sh scripts/build.sh` 构建 `build/Wenshan.app`；`sh scripts/install.sh` 装到 `~/Library/Input Methods`。
- 首次构建自动下载 rime-ice 词库生成 `dict.bin`（约 17 MB）。
- 日志：`~/Library/Logs/Wenshan.log`。按键调试：`touch ~/Library/Application\ Support/Wenshan/debug` 后重启输入法。
- 项目结构和按键行为见 README.md。
