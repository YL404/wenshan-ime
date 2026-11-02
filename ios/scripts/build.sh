#!/bin/sh
# 构建 iOS 模拟器版：Go 引擎 -> XCFramework -> Xcode 工程。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

if [ ! -f dict.bin ]; then
    echo "缺少 dict.bin，先运行 sh scripts/build.sh 或生成词表" >&2
    exit 1
fi

mkdir -p ios/build
cp dict.bin ios/build/dict.bin

# gomobile 和 gobind 都装在 GOPATH/bin 下。
PATH="$(go env GOPATH)/bin:$PATH" gomobile bind \
    -target=ios \
    -o ios/build/WenshanEngine.xcframework \
    ./ios/mobile

cd ios
xcodegen generate
xcodebuild \
    -project Wenshan.xcodeproj \
    -scheme WenshanHost \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    build

echo
echo "产物: ios/build/DerivedData/Build/Products/Debug-iphonesimulator/WenshanHost.app"
