#!/bin/sh
# 构建 iOS 模拟器版：Swift 规则层 + Xcode 工程。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

if [ ! -f dict.bin ]; then
    echo "缺少 dict.bin，先运行 sh scripts/build.sh 或生成词表" >&2
    exit 1
fi

mkdir -p ios/build
cp dict.bin ios/build/dict.bin
# 清掉旧的 gomobile 产物，工程已经不再引用它。
rm -rf ios/build/WenshanEngine.xcframework

cd ios
go run ../cmd/icon -ios-out WenshanHost/Assets.xcassets/AppIcon.appiconset/AppIcon.png
xcodegen generate
xcodebuild \
    -project Wenshan.xcodeproj \
    -scheme WenshanHost \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData \
    build

echo
echo "产物: ios/build/DerivedData/Build/Products/Debug-iphonesimulator/WenshanHost.app"
