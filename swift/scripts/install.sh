#!/bin/sh
# 把文山装到 ~/Library/Input Methods，沿用原来的 bundle id、输入源和用户数据。
set -eu
cd "$(dirname "$0")/../.."
[ -n "${HOME:-}" ] || { echo "HOME 未设置" >&2; exit 1; }

sh swift/scripts/build.sh

dest="$HOME/Library/Input Methods/Wenshan.app"
old="$HOME/Library/Input Methods/WenshanSwift.app"
mkdir -p "$HOME/Library/Input Methods"

# 清掉之前并存测试用的独立 Swift 版和它的输入源。
if [ -d "$old" ]; then
	build/Wenshan.app/Contents/MacOS/Wenshan \
		--disable im.wenshan.inputmethod.WenshanSwift.Hans >/dev/null 2>&1 || true
	build/Wenshan.app/Contents/MacOS/Wenshan \
		--disable im.wenshan.inputmethod.WenshanSwift >/dev/null 2>&1 || true
	pkill -f "$old/Contents/MacOS/WenshanSwift" 2>/dev/null || true
	rm -rf "$old"
fi

# 替换期间先切到 ABC，别让系统还连着旧进程。
build/Wenshan.app/Contents/MacOS/Wenshan --select com.apple.keylayout.ABC >/dev/null 2>&1 || true

pkill -f "$dest/Contents/MacOS/Wenshan" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
	pgrep -f "$dest/Contents/MacOS/Wenshan" >/dev/null 2>&1 || break
	sleep 0.2
done

# 只换 Contents，用 renamex_np(RENAME_SWAP) 原子交换，避免 bundle 出现
# 不完整的窗口，LaunchServices 会认为应用被卸载。
if [ -d "$dest/Contents" ]; then
	stage="$HOME/Library/Input Methods/.Wenshan.stage"
	rm -rf "$stage"
	mkdir -p "$stage"
	cp -R build/Wenshan.app/Contents "$stage/Contents"
	build/Wenshan.app/Contents/MacOS/Wenshan --swap \
		"$stage/Contents" "$dest/Contents"
	rm -rf "$stage"
else
	rm -rf "$dest"
	cp -R build/Wenshan.app "$dest"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
	-f "$dest" >/dev/null 2>&1 || true
"$dest/Contents/MacOS/Wenshan" --register "$dest" >/dev/null 2>&1 || true

# 让系统重新认识这个 bundle，并重启 IMK 的两个常驻代理。
killall imklaunchagent TextInputSwitcher 2>/dev/null || true
sleep 1

# 输入源 ID 是 im.wenshan.inputmethod.Wenshan.Hans，已经添加过的机器不用重新添加。
"$dest/Contents/MacOS/Wenshan" --select im.wenshan.inputmethod.Wenshan.Hans >/dev/null 2>&1 || true

echo "已安装: $dest"
echo "输入源仍是「文山」，用户词频和短语在 ~/Library/Application Support/Wenshan。"
echo "日志: ~/Library/Logs/Wenshan.log"
