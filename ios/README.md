# 文山 iOS（实验）

用 Go 内核 + Swift 6 键盘扩展验证 iOS 版可行性。当前功能：
26 键输入、候选条（横滑 + 翻页）、Shift 一次性大写、符号页、
`MobileType`/`MobileSelect` 上屏、主 App 内引擎自检。

## 结构

- `mobile/`：gomobile 导出的 Go 引擎入口，候选列表用换行分隔的字符串返回。
- `WenshanKeyboard/`：键盘扩展，词表 `dict.bin` 打进扩展 Bundle。
  - `WenshanBridge.swift`：gomobile 桥的 Swift 门面，跨语言调用收在这一处。
  - `KeyboardModel.swift`：`@MainActor` 输入状态机（引擎加载、组合、翻页、Shift）。
  - `KeyboardViewController.swift`：UI 构建与渲染，不直接碰引擎桥。
- `WenshanHost/`：宿主 App，带启用说明和引擎自检。
- `WenshanUITests/`：模拟器 UI 测试，试打 `womf` 上屏「我们」。
- `project.yml`：XcodeGen 工程定义（Swift 6 语言模式）；`.xcodeproj` 和 Info.plist 都是生成物，不入库。

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

## 测试

```sh
cd ios
xcodebuild test -project Wenshan.xcodeproj -scheme WenshanHost \
    -destination 'platform=iOS Simulator,id=<模拟器 UDID>' \
    -derivedDataPath build/DerivedData
```

注意：跑测试**不要带 `CODE_SIGNING_ALLOWED=NO`**。未签名的键盘扩展没有
entitlements，iOS 27 模拟器会把它判成无效键盘，输入时永远弹系统键盘。
xcodebuild 默认的 ad-hoc 签名即可。

## 模拟器启用键盘

安装宿主 App 后，在模拟器设置里手动添加：
设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 第三方键盘 → 文山。

命令行写键盘偏好的老办法（`defaults write NSGlobalDomain AppleKeyboards`）
在 iOS 27 模拟器上对第三方键盘失效：条目会被系统剔除，输入时仍弹系统键盘，
只有系统自带键盘（英语/拼音）认这个设置。

聚焦输入框后若无软件键盘弹出，是「硬件键盘」模式在拦：
`defaults write com.apple.keyboard.preferences HardwareKeyboardLastSeen -bool false`
后重启 SpringBoard（`launchctl stop com.apple.SpringBoard`）。

## 已知边界

- 词表 18 MB（57 万条），直接打进扩展。真机键盘扩展的 jetsam 预算远小于模拟器，
  上真机前要裁词表、改 App Group + mmap，并实测 RSS。
- 还没做 App Group、用户词频/自造词落盘、九键、长按。
- 主 App 的“引擎自检”只为验证 Go 框架在 iOS 进程里能加载词表，正式版应移除，
  否则宿主 App 会多带一份 Go 运行时和词表访问。
- UI 测试用坐标点击，依赖 iPhone 18 Pro 402×874 的布局；换机型要重新对坐标。
- 键盘高度写死 270pt，横屏和 iPad 没有单独适配。
