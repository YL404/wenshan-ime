import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Point {
    var x: Double
    var y: Double
}

/// 预乘 alpha 的 RGBA 颜色。
struct RGBA: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}

/// 每像素 4 字节、预乘 alpha 的位图，行优先，原点在左上角。
struct Canvas {
    let width: Int
    let height: Int
    var pix: [UInt8]

    init(width: Int, height: Int, fill: RGBA = .clear) {
        self.width = width
        self.height = height
        pix = [UInt8](repeating: 0, count: width * height * 4)
        if fill != .clear {
            for i in stride(from: 0, to: pix.count, by: 4) {
                pix[i] = fill.r
                pix[i + 1] = fill.g
                pix[i + 2] = fill.b
                pix[i + 3] = fill.a
            }
        }
    }

    @inline(__always)
    func at(_ x: Int, _ y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(r: pix[i], g: pix[i + 1], b: pix[i + 2], a: pix[i + 3])
    }

    @inline(__always)
    mutating func set(_ x: Int, _ y: Int, _ c: RGBA) {
        let i = (y * width + x) * 4
        pix[i] = c.r
        pix[i + 1] = c.g
        pix[i + 2] = c.b
        pix[i + 3] = c.a
    }

    /// 写成 PNG。CoreGraphics 按预乘 alpha 读位图，ImageIO 写盘时自己换成非预乘。
    func writePNG(to path: String) throws {
        let data = Data(pix) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw IconError.encode(path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw IconError.encode(path) }
    }
}

enum IconError: Error, CustomStringConvertible {
    case encode(String)

    var description: String {
        switch self {
        case .encode(let path): return "\(path): PNG 编码失败"
        }
    }
}

func scalePoints(_ pts: [Point], _ s: Double) -> [Point] {
    pts.map { Point(x: $0.x * s, y: $0.y * s) }
}

/// 二次贝塞尔采样 n+1 个点。
func quad(_ p0: Point, _ p1: Point, _ p2: Point, _ n: Int) -> [Point] {
    (0...n).map { i in
        let t = Double(i) / Double(n)
        let u = 1 - t
        return Point(
            x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
            y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y)
    }
}

/// 实心圆。
func disc(_ img: inout Canvas, _ c: RGBA, _ cx: Double, _ cy: Double, _ r: Double) {
    for y in Int(cy - r)...(Int(cy + r) + 1) {
        for x in Int(cx - r)...(Int(cx + r) + 1) {
            guard x >= 0, x < img.width, y >= 0, y < img.height else { continue }
            let dx = Double(x) + 0.5 - cx
            let dy = Double(y) + 0.5 - cy
            if dx * dx + dy * dy <= r * r {
                img.set(x, y, c)
            }
        }
    }
}

/// 扫描线填多边形（奇偶规则），对每段被覆盖的像素调用 paint。
func scanFill(_ img: inout Canvas, _ pts: [Point], _ paint: (inout Canvas, Int, Int) -> Void) {
    var ymin = Double.infinity
    var ymax = -Double.infinity
    for p in pts {
        ymin = min(ymin, p.y)
        ymax = max(ymax, p.y)
    }
    let y0 = max(Int(ymin), 0)
    let y1 = min(Int(ymax) + 1, img.height - 1)
    guard y0 <= y1 else { return }

    var xs: [Double] = []
    for y in y0...y1 {
        let yc = Double(y) + 0.5
        xs.removeAll(keepingCapacity: true)
        for i in pts.indices {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            if (a.y <= yc) == (b.y <= yc) { continue }
            xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
        }
        xs.sort()
        var i = 0
        while i + 1 < xs.count {
            let from = max(Int((xs[i] - 0.5).rounded(.up)), 0)
            let to = min(Int((xs[i + 1] - 0.5).rounded(.down)), img.width - 1)
            if from <= to {
                for x in from...to { paint(&img, x, y) }
            }
            i += 2
        }
    }
}

/// 实色填多边形。传透明色就是挖空。
func fill(_ img: inout Canvas, _ c: RGBA, _ pts: [Point]) {
    scanFill(&img, pts) { img, x, y in img.set(x, y, c) }
}

/// 半透明晕染：dst = dst*(1-a) + c*a。调用时所有像素都已不透明，
/// 直接按直线 alpha 混 RGB 即可。
func fillA(_ img: inout Canvas, _ c: RGBA, _ alpha: Double, _ pts: [Point]) {
    scanFill(&img, pts) { img, x, y in
        let d = img.at(x, y)
        img.set(x, y, RGBA(
            r: UInt8(Double(d.r) * (1 - alpha) + Double(c.r) * alpha),
            g: UInt8(Double(d.g) * (1 - alpha) + Double(c.g) * alpha),
            b: UInt8(Double(d.b) * (1 - alpha) + Double(c.b) * alpha),
            a: 0xff))
    }
}

/// 连续圆角矩形：四角用超椭圆过渡，直边保持平直。
/// r 是圆角半径，n 越大越接近方角；r/n 都按放大后的像素计。
func fillContinuousRoundedRect(
    _ img: inout Canvas, _ c: RGBA,
    _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ r: Double, _ n: Double
) {
    for y in Int(y0.rounded(.down))..<Int(y1.rounded(.up)) {
        for x in Int(x0.rounded(.down))..<Int(x1.rounded(.up)) {
            let px = Double(x) + 0.5
            let py = Double(y) + 0.5
            if px < x0 || px > x1 || py < y0 || py > y1 { continue }
            let cx = max(x0 + r, min(px, x1 - r))
            let cy = max(y0 + r, min(py, y1 - r))
            let dx = abs(px - cx) / r
            let dy = abs(py - cy) / r
            if pow(dx, n) + pow(dy, n) <= 1 {
                img.set(x, y, c)
            }
        }
    }
}

/// 把 10-90 之外的像素清掉，留下圆角方形底板。
/// 边界按到超椭圆的距离换算覆盖率，边沿有一像素宽的过渡；
/// 若只按整像素裁，底边这种接近水平的长弧会留下台阶。
func maskSquircle(_ img: inout Canvas) {
    let n = Double(img.width) / 100  // 1 个 0-100 坐标单位对应的像素数
    for y in 0..<img.height {
        let v = abs((Double(y) + 0.5) / n - 50) / 40
        let v4 = v * v * v * v
        for x in 0..<img.width {
            let u = abs((Double(x) + 0.5) / n - 50) / 40
            let u4 = u * u * u * u
            // f 是超椭圆隐函数，f/|grad f| 是到边界的距离（0-100 坐标单位）。
            let f = u4 * u + v4 * v - 1
            let g = 5 * hypot(u4, v4) / 40
            if g == 0 { continue }
            let cov = min(max(0.5 - f / g * n, 0), 1)
            if cov >= 1 { continue }
            let c = img.at(x, y)
            img.set(x, y, RGBA(
                r: UInt8(Double(c.r) * cov + 0.5),
                g: UInt8(Double(c.g) * cov + 0.5),
                b: UInt8(Double(c.b) * cov + 0.5),
                a: UInt8(Double(c.a) * cov + 0.5)))
        }
    }
}

/// 按 ss×ss 块求平均。位图是预乘 alpha，直接平均即可。
func downsample(_ img: Canvas, _ ss: Int) -> Canvas {
    let w = img.width / ss
    let h = img.height / ss
    var out = Canvas(width: w, height: h)
    let n = UInt32(ss * ss)
    img.pix.withUnsafeBufferPointer { src in
        for y in 0..<h {
            for x in 0..<w {
                var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
                for dy in 0..<ss {
                    let base = ((y * ss + dy) * img.width + x * ss) * 4
                    for dx in 0..<ss {
                        let i = base + dx * 4
                        r += UInt32(src[i])
                        g += UInt32(src[i + 1])
                        b += UInt32(src[i + 2])
                        a += UInt32(src[i + 3])
                    }
                }
                out.set(x, y, RGBA(
                    r: UInt8(r / n), g: UInt8(g / n), b: UInt8(b / n), a: UInt8(a / n)))
            }
        }
    }
    return out
}
