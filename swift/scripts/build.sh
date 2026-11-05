#!/bin/sh
# 编译 WenshanSwift.app：Swift 可执行文件 + Info.plist + 词表 + 图标。
set -eu
cd "$(dirname "$0")/../.."

if [ ! -f dict.bin ]; then
	echo "缺少 dict.bin，先生成词表" >&2
	sh scripts/fetch-dict.sh
	go run ./cmd/dictgen -o dict.bin -aux build/aux/moqi_aux_code.txt \
		build/rime-ice/8105.dict.yaml build/rime-ice/base.dict.yaml build/rime-ice/others.dict.yaml
fi

swift build -c release --package-path swift --product WenshanSwift

app=build/WenshanSwift.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp swift/.build/release/WenshanSwift "$app/Contents/MacOS/WenshanSwift"
cp swift/Resources/Info.plist "$app/Contents/Info.plist"
cp dict.bin "$app/Contents/Resources/dict.bin"
cp -R swift/Resources/zh-Hans.lproj swift/Resources/en.lproj "$app/Contents/Resources/"

# 图标复用 Go 版的生成器；产物已经在就直接拷。
if [ ! -f build/Wenshan.iconset/icon_512x512@2x.png ] ||
	[ ! -f build/WenshanMenu.iconset/icon_22x16@2x.png ]; then
	go run ./cmd/icon -out build/Wenshan.iconset -menu-out build/WenshanMenu.iconset
fi
iconutil -c icns build/Wenshan.iconset -o "$app/Contents/Resources/Wenshan.icns"
# 输入源图标是 22×16 pt：系统按屏幕倍率取 1x/2x 帧。
sips -s format tiff -s dpiWidth 72 -s dpiHeight 72 \
	build/WenshanMenu.iconset/icon_22x16.png \
	--out build/.menu-swift-1x.tiff >/dev/null
sips -s format tiff -s dpiWidth 144 -s dpiHeight 144 \
	build/WenshanMenu.iconset/icon_22x16@2x.png \
	--out build/.menu-swift-2x.tiff >/dev/null
tiffutil -cat build/.menu-swift-1x.tiff build/.menu-swift-2x.tiff \
	-out "$app/Contents/Resources/WenshanMenu.tiff" >/dev/null
rm -f build/.menu-swift-1x.tiff build/.menu-swift-2x.tiff

printf 'APPL????' > "$app/Contents/PkgInfo"
codesign --force --sign "${CODESIGN_IDENTITY:--}" \
	--identifier im.wenshan.inputmethod.WenshanSwift "$app"
echo "已生成 $app"
