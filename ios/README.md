# 文山 iOS

Go 内核 + Swift 6 键盘扩展。和 macOS 共用 `engine/`，iOS 只负责键盘壳、共享数据和系统输入上下文。

当前可用：26 键自然码、空闲工具栏/输入候选两态顶栏、候选词块与全量候选展开、长按候选取首/尾字、
首选上屏、Shift 一次性大写与双击锁定、中英切换、临时英文、符号页与长按符号、`returnKeyType`
标题与高亮、收起键盘、地球键、按键预览、删除长按连发/滑动删除、空格长按拖光标、快速连打
顺序队列、触感（需完全访问）、iPad 分档/浮动高度、App Group 词表、用户词频/自造词/短语加载。
标点、全半角、Shift、临时英文和自动补空格与 macOS 共用根目录的 `input/` 规则层，iOS 只保留
触摸按键和渲染。

底行按微信键盘/系统键盘的层级排：`123`、地球、句号/逗号小键、宽空格、`中/英`、发送/换行；
Z 行 Shift/删除比字母键宽，A 行左右各缩进半个键。句号键轻点上屏 `。`，长按上屏 `，`；
英文态显示 `.` / `,`。发送/搜索/完成等非默认回车键显示蓝色，长按换行。没有输入时顶栏显示
「文山」、当前模式和全/半角开关；开始输入后同一位置换成候选词块，点右侧展开键看全部候选。

## 结构

- `mobile/`：gomobile 导出的 Go 引擎入口。
  - `Open(dictPath, dataDir)`：映射词表，并从 `dataDir` 加载 `freq.tsv`、`userdict.tsv`、`phrases.tsv`。
  - `Flush()` / `Close()`：把攒够次数的词频和自造词写盘。
- `Shared/AppGroup.swift`：App Group 标识和共享目录路径。
- `WenshanHost/`：宿主 App。
  - `DictDeployer.swift`：把扩展 Bundle 里的 `dict.bin` 原子部署到 App Group。
  - `ContentView.swift`：启用说明、词表状态、用户数据统计/清空、测试输入框。
- `WenshanKeyboard/`：键盘扩展。
  - `WenshanBridge.swift`：gomobile 桥的 Swift 门面。
  - `KeyboardModel.swift`：Swift 侧只保留 Shift 状态和宿主上下文；拼音组合、
    标点、中英模式、临时英文、空格/回车/退格和自动补空格在根目录 `input/`。
  - `KeyboardComponents.swift`：尺寸和按键；`CandidateViews.swift`：空闲工具栏、候选条、全量候选网格；iOS 26 关闭候选条与网格的 scroll edge effect，否则文字会被边缘模糊盖住。
  - `KeyboardViewController.swift`：生命周期、布局、系统输入上下文、渲染。
- `WenshanUITests/`：宿主 App 冒烟测试。
- `project.yml`：XcodeGen 工程定义；`.xcodeproj` 和 Info.plist 是生成物，不入库。

## 数据流

```
WenshanHost
  └─ 部署 dict.bin → App Group: group.im.wenshan.ios
                              ├─ dict.bin
                              └─ Data/
                                   ├─ freq.tsv
                                   ├─ userdict.tsv
                                   └─ phrases.tsv
WenshanKeyboard
  ├─ 优先读 App Group 词表，失败回退扩展 Bundle
  ├─ 引擎 mmap 词表，不整块复制
  └─ 用户数据写共享目录；没有完全访问时退回扩展 Documents
```

开 `RequestsOpenAccess` 只用于写共享目录和主 App 统计；不联网、不上传。关闭完全访问时，
基础输入仍可用，学习记录只存在键盘自己的沙箱里。

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
4. 用默认 ad-hoc 签名构建模拟器 App。

产物在 `ios/build/DerivedData/Build/Products/Debug-iphonesimulator/WenshanHost.app`。

不要给构建或测试加 `CODE_SIGNING_ALLOWED=NO`。未签名的键盘扩展没有 App Group
entitlements，iOS 27 模拟器会把它判成无效键盘，输入时永远弹系统键盘。

## 测试

宿主 App 冒烟测试：

```sh
cd ios
xcodebuild test -project Wenshan.xcodeproj -scheme WenshanHost \
    -destination 'platform=iOS Simulator,id=<模拟器 UDID>' \
    -derivedDataPath build/DerivedData
```

键盘输入在无头模拟器里用 argent 验证：

```sh
argent run boot-device --udid <UDID> --headless
argent run reinstall-app --udid <UDID> --bundleId im.wenshan.ios \
  --appPath "$PWD/ios/build/DerivedData/Build/Products/Debug-iphonesimulator/WenshanHost.app"
argent run launch-app --udid <UDID> --bundleId im.wenshan.ios
```

CoreSimulator 每次启动会自动挂一个硬件键盘，软件键盘因此不出现。用 JXA 调
`SimDevice.setHardwareKeyboardEnabled:keyboardType:error:` 断开它，再聚焦输入框：

```sh
osascript -l JavaScript -e '
ObjC.import("Foundation");
function run([udid, developerDir]) {
  $.NSBundle.bundleWithPath("/Library/Developer/PrivateFrameworks/CoreSimulator.framework").load;
  const context = $.NSClassFromString("SimServiceContext").sharedServiceContextForDeveloperDirError(developerDir, null);
  const device = context.defaultDeviceSetWithError(null).devicesByUDID.objectForKey($.NSUUID.alloc.initWithUUIDString(udid));
  const error = Ref();
  device.setHardwareKeyboardEnabledKeyboardTypeError(false, 0, error);
}' <UDID> "$(xcode-select -p)"
```

然后在宿主 App 里启用文山键盘（设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 第三方键盘 → 文山），
聚焦测试输入框，用 `argent run describe` 取按键坐标或直接用可访问标识。

## 内存

模拟器实测（iPhone 18 Pro，iOS 27.2，Debug）：键盘扩展启动约 30 MB，
完成一次上屏约 32 MB，50 次连续上屏后约 23 MB，收起键盘后回落到约 20 MB；
没有随上屏次数线性增长。词表通过 App Group 文件 mmap，`lsof` 确认映射的是共享容器里的
`dict.bin`，没有整块读入 Go 堆。

模拟器不执行键盘扩展的 jetsam 上限。真机 Release 构建仍需用 Instruments 测冷启动、
首次输入、100 次上屏和 10 分钟空闲；目标控制在 50 MB 以内，给系统留余量。

## 已知边界

- 还没有真机内存数据；iPad/横屏高度和字号是按档位估算，未做截图校准。
- 还没有九宫格、硬件键盘映射；触感需要完全访问。
- 用户数据只在本地；没有 iCloud/WebDAV 同步。`phrases.tsv` 目前需要手动放到
  App Group 的 `Data/` 下，宿主还没有短语编辑器。
- 没有 App Group 的免费签名会退回扩展自己的 Documents，主 App 看不到学习记录。
- 词表 18 MB，仍打包在扩展 Bundle 里作为首次部署的回退；App 体积和扩展内存是两回事。
