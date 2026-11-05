#!/bin/sh
# 装到 ~/Library/Input Methods，和 Go 版并存。
set -eu
cd "$(dirname "$0")/../.."
[ -n "${HOME:-}" ] || { echo "HOME 未设置" >&2; exit 1; }

sh swift/scripts/build.sh

dest="$HOME/Library/Input Methods/WenshanSwift.app"
mkdir -p "$HOME/Library/Input Methods"
# 等旧实例真正退出：pkill 是异步的，抢在它前面启动会注册不上 IMK 连接。
pkill -f "$dest/Contents/MacOS/WenshanSwift" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
	pgrep -f "$dest/Contents/MacOS/WenshanSwift" >/dev/null 2>&1 || break
	sleep 0.2
done

# 只换 Contents，用 renamex_np(RENAME_SWAP) 原子交换，避免 bundle 出现
# 不完整的窗口，LaunchServices 会认为应用被卸载。
if [ -d "$dest/Contents" ]; then
	stage="$HOME/Library/Input Methods/.WenshanSwift.stage"
	rm -rf "$stage"
	mkdir -p "$stage"
	cp -R build/WenshanSwift.app/Contents "$stage/Contents"
	build/WenshanSwift.app/Contents/MacOS/WenshanSwift --swap \
		"$stage/Contents" "$dest/Contents"
	rm -rf "$stage"
else
	rm -rf "$dest"
	cp -R build/WenshanSwift.app "$dest"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
	-f "$dest" >/dev/null 2>&1 || true
"$dest/Contents/MacOS/WenshanSwift" --register "$dest" >/dev/null 2>&1 || true

# 让系统重新认识这个 bundle，并重启 IMK 的两个常驻代理。
killall imklaunchagent TextInputSwitcher 2>/dev/null || true

echo "已安装: $dest"
echo "首次安装需要在 系统设置 → 键盘 → 输入源 里添加「文山 Swift」并点允许。"
echo "日志: ~/Library/Logs/WenshanSwift.log"
