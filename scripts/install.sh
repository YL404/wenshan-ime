#!/bin/sh
# 装到 ~/Library/Input Methods，并让 LaunchServices 认到这个 bundle。
set -eu
cd "$(dirname "$0")/.."
[ -n "${HOME:-}" ] || { echo "HOME 未设置" >&2; exit 1; }

sh scripts/build.sh

dest="$HOME/Library/Input Methods/Wenshan.app"
mkdir -p "$HOME/Library/Input Methods"
# 等旧实例真正退出：pkill 是异步的，抢在它前面启动会注册不上 IMK 连接。
pkill -f "$dest/Contents/MacOS/Wenshan" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
	pgrep -f "$dest/Contents/MacOS/Wenshan" >/dev/null 2>&1 || break
	sleep 0.2
done
# 只换 Contents，而且用 renamex_np(RENAME_SWAP) 原子交换：
# 整目录删掉再拷，或者先挪走再拷，中间都有一段 bundle 不完整的窗口，
# LaunchServices 会认为应用被卸载，输入源跟着失效。
if [ -d "$dest/Contents" ]; then
	stage="$HOME/Library/Input Methods/.Wenshan.stage"
	rm -rf "$stage"
	mkdir -p "$stage"
	cp -R build/Wenshan.app/Contents "$stage/Contents"
	go run ./cmd/swap "$stage/Contents" "$dest/Contents"
	rm -rf "$stage"
else
	rm -rf "$dest"
	cp -R build/Wenshan.app "$dest"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
	-f "$dest" >/dev/null 2>&1 || true

# 让系统重新认识这个 bundle，并重启 IMK 的两个常驻代理：
# 旧代理和切换器缓存着上一个实例的连接端点，不重启的话，
# 切到文山时要么被静默回退，要么按键继续发给死掉的旧进程。
go run ./cmd/tisprobe -register "$dest" >/dev/null 2>&1 || true
killall imklaunchagent TextInputSwitcher 2>/dev/null || true

echo "已安装: $dest"
echo "首次安装需要在 系统设置 → 键盘 → 输入源 里添加「文山」并点允许。"
echo "注意：升级安装后，已经打开的应用要重启才能拿到新的输入法实例。"
