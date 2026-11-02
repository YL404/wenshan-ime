#!/bin/sh
# 编译 Wenshan.app：Go 可执行文件 + Info.plist + 本地签名。
set -eu
cd "$(dirname "$0")/.."

aux=build/aux/moqi_aux_code.txt
if [ ! -f dict.bin ] || [ "$(head -c 6 dict.bin)" != "WSIME2" ] ||
	[ ! -s "$aux" ] || [ "$aux" -nt dict.bin ]; then
	sh scripts/fetch-dict.sh
	go run ./cmd/dictgen -o dict.bin -aux "$aux" \
		build/rime-ice/8105.dict.yaml build/rime-ice/base.dict.yaml build/rime-ice/others.dict.yaml
fi

app=build/Wenshan.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
go build -trimpath -ldflags "-s -w" -o "$app/Contents/MacOS/Wenshan" .
cp packaging/Info.plist "$app/Contents/Info.plist"
cp -R packaging/zh-Hans.lproj packaging/en.lproj "$app/Contents/Resources/"
go run ./cmd/icon -out build/Wenshan.iconset -menu-out build/WenshanMenu.iconset
iconutil -c icns build/Wenshan.iconset -o "$app/Contents/Resources/Wenshan.icns"
# 菜单栏用 16 pt 模板图；32×32@144dpi 正好是 2x。
sips -s format tiff -s dpiWidth 144 -s dpiHeight 144 \
	build/WenshanMenu.iconset/icon_16x16@2x.png \
	--out "$app/Contents/Resources/WenshanMenu.tiff" >/dev/null
printf 'APPL????' > "$app/Contents/PkgInfo"
# 用固定身份签名（Apple Development 证书）能让系统把每次构建认成同一个应用，
# TCC 授权（"允许启用"）不会因为重新编译而重置。不设就用 ad-hoc。
identity="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$identity" --identifier im.wenshan.inputmethod.Wenshan "$app"
echo "签名身份: $identity"
echo "已生成 $app"
