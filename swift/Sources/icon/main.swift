// icon 画文山输入法的图标：纸色圆角方形 + 分层墨色山峦 + 红日 + 云带，
// 同时输出输入源列表和菜单栏用的 22×16 单色镂空图标，以及 iOS 的满版 AppIcon。
//
//     swift run -c release --package-path swift icon \
//         -out build/Wenshan.iconset -menu-out build/WenshanMenu.iconset
//
// 图形直接用扫描线填充画，不依赖绘图库：山脊是二次贝塞尔采样成的多段折线，
// 云带用半透明晕染。每档先放大数倍再降采样，小尺寸也有干净的边缘。
import Foundation

let paper = RGBA(r: 0xf3, g: 0xec, b: 0xdd, a: 0xff)
let ink = RGBA(r: 0x1f, g: 0x2a, b: 0x36, a: 0xff)
let sealRed = RGBA(r: 0xc0, g: 0x50, b: 0x3a, a: 0xff)
let washFar = RGBA(r: 0xae, g: 0xbc, b: 0xb8, a: 0xff)
let washMid = RGBA(r: 0x7f, g: 0x97, b: 0x9a, a: 0xff)
let washNear = RGBA(r: 0x4a, g: 0x65, b: 0x70, a: 0xff)
let menuInk = RGBA(r: 0, g: 0, b: 0, a: 0xff)

/// iconutil 认的文件名和对应像素尺寸。
let iconset: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

/// 输入源模板图的 1x/2x 两档。macOS 27 的系统输入法图标是 22×16 的连续
/// 圆角底板，「键盘 → 输入源」列表和菜单栏都按这个尺寸画。
let menuIcons: [(name: String, w: Int, h: Int)] = [
    ("icon_22x16.png", 22, 16),
    ("icon_22x16@2x.png", 44, 32),
]

/// 列表图标的点宽度，也是山形坐标的基准。
let menuW = 22.0

/// 输入源图标里挖空的山形，坐标按 22×16 的底板中心对齐。
let mountain = [
    Point(x: 5.2, y: 12.8), Point(x: 7.8, y: 7.2), Point(x: 9.0, y: 8.8),
    Point(x: 11.2, y: 3.2), Point(x: 16.8, y: 12.8),
]

/// 山峦剪影：左右坡各一条二次贝塞尔相接于峰顶，底部延伸出画布。
/// 控制点越贴近基线，坡面越凹。
func ridge(
    _ px: Double, _ py: Double, _ cxL: Double, _ cyL: Double, _ cxR: Double, _ cyR: Double,
    _ bx0: Double, _ bx1: Double, _ by: Double
) -> [Point] {
    let left = quad(Point(x: bx0, y: by), Point(x: cxL, y: cyL), Point(x: px, y: py), 28)
    let right = quad(Point(x: px, y: py), Point(x: cxR, y: cyR), Point(x: bx1, y: by), 28)
    return left + right + [Point(x: bx1, y: by + 40), Point(x: bx0, y: by + 40)]
}

/// 云带：上下两条波浪边围成的横带，跨出画布左右。
func mist(_ yTop: Double, _ yBot: Double) -> [Point] {
    let top = quad(
        Point(x: -10, y: yTop), Point(x: 50, y: yTop + 5), Point(x: 110, y: yTop - 2), 24)
    let bot = quad(
        Point(x: 110, y: yBot), Point(x: 50, y: yBot + 5), Point(x: -10, y: yBot - 1), 24)
    return top + bot + [Point(x: -10, y: yTop - 2)]
}

/// 画 size×size 的满版场景：纸底、红日、四层山峦，云带拦腰。
/// 绘制顺序就是深度顺序：日最远，墨山最近。
func renderScene(_ size: Int) -> Canvas {
    let ss = 4
    let w = size * ss
    var img = Canvas(width: w, height: w, fill: paper)
    let s = Double(w) / 100
    disc(&img, sealRed, 66 * s, 24 * s, 11.5 * s)
    fill(&img, washFar, scalePoints(ridge(54, 34, 14, 64, 88, 56, -10, 110, 64), s))
    fill(&img, washMid, scalePoints(ridge(24, 47, -8, 71, 50, 64, -10, 110, 76), s))
    fillA(&img, paper, 0.65, scalePoints(mist(62, 74), s))
    fill(&img, washNear, scalePoints(ridge(62, 56, 34, 73, 88, 70, -10, 110, 88), s))
    fill(&img, ink, scalePoints(ridge(40, 53, 6, 71, 66, 62, -10, 110, 95), s))
    return downsample(img, ss)
}

/// macOS 的圆角方形 App 图标。
func renderApp(_ size: Int) -> Canvas {
    var out = renderScene(size)
    maskSquircle(&out)
    return out
}

/// 满版 iOS AppIcon。iOS 自己按设备裁圆角，素材不能预切圆角，
/// 也不能带透明边，所以山峦和纸底都铺到画布四边。
func renderIOS(_ size: Int) -> Canvas {
    renderScene(size)
}

/// 输入源模板：22×16 连续圆角底板挖掉一座山。底板尺寸和圆角跟 macOS 27
/// 系统输入法图标对齐，和 ABC、双拼并排时宽高一致；8 倍超采样让圆角边缘
/// 和系统图标一样平滑。
func renderMenu(_ w: Int, _ h: Int) -> Canvas {
    let ss = 8
    var img = Canvas(width: w * ss, height: h * ss)
    let s = Double(w) / menuW * Double(ss)
    fillContinuousRoundedRect(&img, menuInk, 0, 0, Double(w * ss), Double(h * ss), 6.5 * s, 2.8)
    fill(&img, .clear, scalePoints(mountain, s))
    return downsample(img, ss)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func makeDirectory(_ path: String) {
    do {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    } catch {
        fail("\(path): \(error)")
    }
}

func write(_ img: Canvas, _ path: String) {
    do {
        try img.writePNG(to: path)
    } catch {
        fail("\(error)")
    }
}

var options = [
    "-out": "build/Wenshan.iconset",
    "-menu-out": "build/WenshanMenu.iconset",
    "-ios-out": "",
    "-preview": "",
    "-menu-preview": "",
]
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    guard options[arg] != nil else {
        fail("用法: icon [-out 目录] [-menu-out 目录] [-ios-out 文件] [-preview 文件] [-menu-preview 文件]")
    }
    guard let value = args.popFirst() else { fail("\(arg) 后面缺参数") }
    options[arg] = value
}

let out = options["-out"]!
let menuOut = options["-menu-out"]!
makeDirectory(out)
makeDirectory(menuOut)
for it in iconset {
    write(renderApp(it.size), "\(out)/\(it.name)")
}
for it in menuIcons {
    write(renderMenu(it.w, it.h), "\(menuOut)/\(it.name)")
}
print("\(out): \(iconset.count) 个尺寸")
print("\(menuOut): \(menuIcons.count) 个尺寸")
if let path = options["-ios-out"], !path.isEmpty {
    makeDirectory((path as NSString).deletingLastPathComponent)
    write(renderIOS(1024), path)
    print(path)
}
if let path = options["-preview"], !path.isEmpty {
    write(renderApp(512), path)
    print(path)
}
if let path = options["-menu-preview"], !path.isEmpty {
    write(renderMenu(88, 64), path)
    print(path)
}
