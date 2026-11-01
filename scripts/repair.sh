#!/bin/sh
# 输入法不响应时的一键修复。
#
# 症状：切到文山后打不出候选，只有英文。
# 原因通常是输入法进程没了但系统以为它还在（连接名被残留进程占着），
# 于是永远不去启动新的实例。
set -eu
cd "$(dirname "$0")/.."
[ -n "${HOME:-}" ] || { echo "HOME 未设置" >&2; exit 1; }

echo "1/4 清掉残留进程"
pkill -9 -f "Wenshan.app/Contents/MacOS" 2>/dev/null || true
sleep 0.5

echo "2/4 重新注册 bundle"
go run ./cmd/tisprobe -register "$HOME/Library/Input Methods/Wenshan.app" | grep -v "^系统已注册"

echo "3/4 重新启用并选中输入源"
go run ./cmd/tisprobe -enable im.wenshan.inputmethod.Wenshan.Hans | grep -E "启用|选中"

echo "4/4 等它启动"
sleep 2
if pgrep -f "Wenshan.app/Contents/MacOS" >/dev/null; then
	echo "输入法已启动，日志："
	tail -3 "$HOME/Library/Logs/Wenshan.log" 2>/dev/null || true
else
	cat <<'TIP'
没能自动启动。请手动做一步：
  切到别的输入源，再切回文山（Ctrl-空格 两次）。
还是不行再到 系统设置 → 键盘 → 输入源 里移除并重新添加「文山」。
TIP
fi
