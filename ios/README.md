# 文山 iOS（实验）

用 Go 内核 + Swift 键盘扩展验证 iOS 版可行性。当前只做最小链路：
26 键输入、候选条、`MobileType`/`MobileSelect` 上屏、主 App 内引擎自检。

## 结构

- `mobile/`：gomobile 导出的 Go 引擎入口，候选列表用换行分隔的字符串返回。
- `WenshanKeyboard/`：`UIInputViewController` 键盘扩展，词表 `dict.bin` 打进扩展 Bundle。
- `WenshanHost/`：宿主 App，带启用说明和引擎自检。
- `WenshanUITests/`：模拟器 UI 测试，点地球键切到文山并试打 `womf`。
- `project.yml`：XcodeGen 工程定义；`.xcodeproj` 和 Info.plist 都是生成物，不入库。

## 构建

依赖 Xcode 27、Go 1.27、XcodeGen、gomobile：

```sh
go install golang.org/x/mobile/cmd/gomobile@latest
PATH="$(go env GOPATH)/bin:$PATH" gomobile init
brew install xcodegen
sh ios/scripts/build.sh
```

脚本会：

1. 把根目录 `dict.bin` 复制到 `ios/build/dict.bin`；
2. 用 `gomobile bind` 生成 `ios/build/WenshanEngine.xcframework`；
3. 用 `xcodegen` 生成 Xcode 工程；
4. 构建模拟器 App。

产物在 `ios/build/DerivedData/Build/Products/Debug-iphonesimulator/WenshanHost.app`。

## 模拟器启用键盘

安装并启动宿主 App 后，在模拟器里：

1. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 文山；
2. 在输入框里长按地球键切换到文山。

也可以用命令行直接写入键盘偏好（需要先安装 App）：

```sh
UDID=$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
KB=im.wenshan.inputmethod.Wenshan.ios.keyboard
EN='en_US@sw=QWERTY;hw=Automatic'
ZH='zh_Hans-Pinyin@sw=Pinyin-Simplified;hw=Automatic'

xcrun simctl spawn "$UDID" defaults write NSGlobalDomain AppleKeyboards -array "$KB" "$EN"
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences KeyboardLastUsed -string "$KB"
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences KeyboardsCurrentAndNext -array "$KB" "$EN" "$ZH"
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences HardwareKeyboardLastSeen -bool false
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool false
```

## 已知边界

- 词表 18 MB（57 万条），直接打进扩展。真机键盘扩展的 jetsam 预算远小于模拟器，
  上真机前要裁词表、改 App Group + mmap，并实测 RSS。
- 还没做 App Group、用户词频/自造词落盘、符号页、九键、长按、Shift。
- 主 App 的“引擎自检”只为验证 Go 框架在 iOS 进程里能加载词表，正式版应移除，
  否则宿主 App 会多带一份 Go 运行时和词表访问。
- UI 测试用坐标点击，依赖 iPhone 18 Pro 402×874 的布局；换机型要重新对坐标。
