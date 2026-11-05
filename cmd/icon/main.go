// Command icon 画文山输入法的图标：纸色圆角方形 + 分层墨色山峦 + 红日 + 云带，
// 同时输出输入源列表和菜单栏用的 22×16 单色镂空图标，以及 iOS 的满版 AppIcon。
//
//	go run ./cmd/icon -out build/Wenshan.iconset -menu-out build/WenshanMenu.iconset
//
// 图形直接用扫描线填充画，不依赖任何绘图库：山脊是二次贝塞尔采样成的多段折线，
// 云带用半透明晕染。每档先放大数倍再降采样，小尺寸也有干净的边缘。
package main

import (
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
)

type point struct{ X, Y float64 }

var (
	paper    = color.RGBA{R: 0xf3, G: 0xec, B: 0xdd, A: 0xff}
	ink      = color.RGBA{R: 0x1f, G: 0x2a, B: 0x36, A: 0xff}
	sealRed  = color.RGBA{R: 0xc0, G: 0x50, B: 0x3a, A: 0xff}
	washFar  = color.RGBA{R: 0xae, G: 0xbc, B: 0xb8, A: 0xff}
	washMid  = color.RGBA{R: 0x7f, G: 0x97, B: 0x9a, A: 0xff}
	washNear = color.RGBA{R: 0x4a, G: 0x65, B: 0x70, A: 0xff}
	menuInk  = color.RGBA{A: 0xff}
)

// iconset 是 iconutil 认的文件名和对应像素尺寸。
var iconset = []struct {
	name string
	size int
}{
	{"icon_16x16.png", 16},
	{"icon_16x16@2x.png", 32},
	{"icon_32x32.png", 32},
	{"icon_32x32@2x.png", 64},
	{"icon_128x128.png", 128},
	{"icon_128x128@2x.png", 256},
	{"icon_256x256.png", 256},
	{"icon_256x256@2x.png", 512},
	{"icon_512x512.png", 512},
	{"icon_512x512@2x.png", 1024},
}

// menuIcons 是输入源模板图的 1x/2x 两档。macOS 27 的系统输入法图标是
// 22×16 的连续圆角底板，“键盘 → 输入源”列表和菜单栏都按这个尺寸画。
var menuIcons = []struct {
	name string
	w, h int
}{
	{"icon_22x16.png", 22, 16},
	{"icon_22x16@2x.png", 44, 32},
}

// menuW 是列表图标的点宽度，也是山形坐标的基准。
const menuW = 22

func main() {
	out := flag.String("out", "build/Wenshan.iconset", "App 图标的 iconset 目录")
	menuOut := flag.String("menu-out", "build/WenshanMenu.iconset", "输入源图标的 iconset 目录")
	iosOut := flag.String("ios-out", "", "另外输出 iOS 的 1024×1024 满版 AppIcon")
	preview := flag.String("preview", "", "另外输出一张 App 图标预览图")
	menuPreview := flag.String("menu-preview", "", "另外输出一张输入源图标预览图")
	flag.Parse()

	for _, dir := range []string{*out, *menuOut} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			log.Fatal(err)
		}
	}
	for _, it := range iconset {
		if err := writePNG(filepath.Join(*out, it.name), renderApp(it.size)); err != nil {
			log.Fatal(err)
		}
	}
	for _, it := range menuIcons {
		if err := writePNG(filepath.Join(*menuOut, it.name), renderMenu(it.w, it.h)); err != nil {
			log.Fatal(err)
		}
	}
	fmt.Printf("%s: %d 个尺寸\n", *out, len(iconset))
	fmt.Printf("%s: %d 个尺寸\n", *menuOut, len(menuIcons))
	if *iosOut != "" {
		if err := os.MkdirAll(filepath.Dir(*iosOut), 0o755); err != nil {
			log.Fatal(err)
		}
		if err := writePNG(*iosOut, renderIOS(1024)); err != nil {
			log.Fatal(err)
		}
		fmt.Println(*iosOut)
	}
	if *preview != "" {
		if err := writePNG(*preview, renderApp(512)); err != nil {
			log.Fatal(err)
		}
		fmt.Println(*preview)
	}
	if *menuPreview != "" {
		if err := writePNG(*menuPreview, renderMenu(88, 64)); err != nil {
			log.Fatal(err)
		}
		fmt.Println(*menuPreview)
	}
}

func writePNG(path string, img image.Image) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := png.Encode(f, img); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// renderScene 画 size×size 的满版场景：纸底、红日、四层山峦，云带拦腰。
// 绘制顺序就是深度顺序：日最远，墨山最近。
func renderScene(size int) *image.RGBA {
	ss := 4
	w := size * ss
	img := image.NewRGBA(image.Rect(0, 0, w, w))
	draw.Draw(img, img.Bounds(), &image.Uniform{C: paper}, image.Point{}, draw.Src)

	s := float64(w) / 100
	disc(img, sealRed, 66*s, 24*s, 11.5*s)
	fill(img, washFar, scalePoints(ridge(54, 34, 14, 64, 88, 56, -10, 110, 64), s))
	fill(img, washMid, scalePoints(ridge(24, 47, -8, 71, 50, 64, -10, 110, 76), s))
	fillA(img, paper, 0.65, scalePoints(mist(62, 74), s))
	fill(img, washNear, scalePoints(ridge(62, 56, 34, 73, 88, 70, -10, 110, 88), s))
	fill(img, ink, scalePoints(ridge(40, 53, 6, 71, 66, 62, -10, 110, 95), s))

	return downsample(img, ss)
}

// renderApp 画 macOS 的圆角方形 App 图标。
func renderApp(size int) *image.RGBA {
	out := renderScene(size)
	maskSquircle(out)
	return out
}

// renderIOS 画满版 iOS AppIcon。iOS 自己按设备裁圆角，素材不能预切圆角，
// 也不能带透明边，所以山峦和纸底都铺到画布四边。
func renderIOS(size int) *image.RGBA {
	return renderScene(size)
}

// mountain 是输入源图标里挖空的山形，坐标按 22×16 的底板中心对齐。
var mountain = []point{
	{5.2, 12.8}, {7.8, 7.2}, {9.0, 8.8}, {11.2, 3.2}, {16.8, 12.8},
}

// renderMenu 画输入源模板：22×16 连续圆角底板挖掉一座山。
// 底板尺寸和圆角跟 macOS 27 系统输入法图标对齐，和 ABC、双拼并排时
// 宽高一致；8 倍超采样让圆角边缘和系统图标一样平滑。
func renderMenu(w, h int) *image.RGBA {
	ss := 8
	img := image.NewRGBA(image.Rect(0, 0, w*ss, h*ss))
	s := float64(w) / menuW * float64(ss)

	fillContinuousRoundedRect(img, menuInk, 0, 0, float64(w*ss), float64(h*ss), 6.5*s, 2.8)
	clear(img, scalePoints(mountain, s))

	return downsample(img, ss)
}

func scalePoints(pts []point, s float64) []point {
	out := make([]point, len(pts))
	for i, p := range pts {
		out[i] = point{p.X * s, p.Y * s}
	}
	return out
}

// quad 二次贝塞尔采样 n+1 个点。
func quad(p0, p1, p2 point, n int) []point {
	pts := make([]point, 0, n+1)
	for i := 0; i <= n; i++ {
		t := float64(i) / float64(n)
		u := 1 - t
		pts = append(pts, point{
			X: u*u*p0.X + 2*u*t*p1.X + t*t*p2.X,
			Y: u*u*p0.Y + 2*u*t*p1.Y + t*t*p2.Y,
		})
	}
	return pts
}

// ridge 山峦剪影：左右坡各一条二次贝塞尔相接于峰顶，底部延伸出画布。
// 控制点越贴近基线，坡面越凹。
func ridge(px, py, cxL, cyL, cxR, cyR, bx0, bx1, by float64) []point {
	left := quad(point{bx0, by}, point{cxL, cyL}, point{px, py}, 28)
	right := quad(point{px, py}, point{cxR, cyR}, point{bx1, by}, 28)
	pts := append(append([]point{}, left...), right...)
	return append(pts, point{bx1, by + 40}, point{bx0, by + 40})
}

// mist 云带：上下两条波浪边围成的横带，跨出画布左右。
func mist(yTop, yBot float64) []point {
	top := quad(point{-10, yTop}, point{50, yTop + 5}, point{110, yTop - 2}, 24)
	bot := quad(point{110, yBot}, point{50, yBot + 5}, point{-10, yBot - 1}, 24)
	pts := append(append([]point{}, top...), bot...)
	return append(pts, point{-10, yTop - 2})
}

// disc 实心圆。
func disc(img *image.RGBA, c color.RGBA, cx, cy, r float64) {
	b := img.Bounds()
	for y := int(cy - r); y <= int(cy+r)+1; y++ {
		for x := int(cx - r); x <= int(cx+r)+1; x++ {
			if x < b.Min.X || x >= b.Max.X || y < b.Min.Y || y >= b.Max.Y {
				continue
			}
			dx, dy := float64(x)+0.5-cx, float64(y)+0.5-cy
			if dx*dx+dy*dy <= r*r {
				img.SetRGBA(x, y, c)
			}
		}
	}
}

// fill 用扫描线填多边形（奇偶规则）。传透明色就是挖空。
func fill(img *image.RGBA, c color.RGBA, pts []point) {
	b := img.Bounds()
	ymin, ymax := math.Inf(1), math.Inf(-1)
	for _, p := range pts {
		ymin = math.Min(ymin, p.Y)
		ymax = math.Max(ymax, p.Y)
	}
	y0 := max(int(ymin), b.Min.Y)
	y1 := min(int(ymax)+1, b.Max.Y-1)

	var xs []float64
	for y := y0; y <= y1; y++ {
		yc := float64(y) + 0.5
		xs = xs[:0]
		for i := range pts {
			a, bb := pts[i], pts[(i+1)%len(pts)]
			if (a.Y <= yc) == (bb.Y <= yc) {
				continue
			}
			xs = append(xs, a.X+(yc-a.Y)/(bb.Y-a.Y)*(bb.X-a.X))
		}
		sort.Float64s(xs)
		for i := 0; i+1 < len(xs); i += 2 {
			from := max(int(math.Ceil(xs[i]-0.5)), b.Min.X)
			to := min(int(math.Floor(xs[i+1]-0.5)), b.Max.X-1)
			for x := from; x <= to; x++ {
				img.SetRGBA(x, y, c)
			}
		}
	}
}

func clear(img *image.RGBA, pts []point) {
	fill(img, color.RGBA{}, pts)
}

// fillA 半透明晕染：dst = dst*(1-a) + c*a。调用时所有像素都已不透明，
// 直接按直线 alpha 混 RGB 即可。
func fillA(img *image.RGBA, c color.RGBA, alpha float64, pts []point) {
	b := img.Bounds()
	ymin, ymax := math.Inf(1), math.Inf(-1)
	for _, p := range pts {
		ymin = math.Min(ymin, p.Y)
		ymax = math.Max(ymax, p.Y)
	}
	y0 := max(int(ymin), b.Min.Y)
	y1 := min(int(ymax)+1, b.Max.Y-1)

	var xs []float64
	for y := y0; y <= y1; y++ {
		yc := float64(y) + 0.5
		xs = xs[:0]
		for i := range pts {
			a, bb := pts[i], pts[(i+1)%len(pts)]
			if (a.Y <= yc) == (bb.Y <= yc) {
				continue
			}
			xs = append(xs, a.X+(yc-a.Y)/(bb.Y-a.Y)*(bb.X-a.X))
		}
		sort.Float64s(xs)
		for i := 0; i+1 < len(xs); i += 2 {
			from := max(int(math.Ceil(xs[i]-0.5)), b.Min.X)
			to := min(int(math.Floor(xs[i+1]-0.5)), b.Max.X-1)
			for x := from; x <= to; x++ {
				d := img.RGBAAt(x, y)
				img.SetRGBA(x, y, color.RGBA{
					R: uint8(float64(d.R)*(1-alpha) + float64(c.R)*alpha),
					G: uint8(float64(d.G)*(1-alpha) + float64(c.G)*alpha),
					B: uint8(float64(d.B)*(1-alpha) + float64(c.B)*alpha),
					A: 0xff,
				})
			}
		}
	}
}

// fillContinuousRoundedRect 画连续圆角矩形：四角用超椭圆过渡，直边保持平直。
// r 是圆角半径，n 越大越接近方角；r/n 都按放大后的像素计。
func fillContinuousRoundedRect(img *image.RGBA, c color.RGBA, x0, y0, x1, y1, r, n float64) {
	for y := int(math.Floor(y0)); y < int(math.Ceil(y1)); y++ {
		for x := int(math.Floor(x0)); x < int(math.Ceil(x1)); x++ {
			px, py := float64(x)+0.5, float64(y)+0.5
			if px < x0 || px > x1 || py < y0 || py > y1 {
				continue
			}
			cx := math.Max(x0+r, math.Min(px, x1-r))
			cy := math.Max(y0+r, math.Min(py, y1-r))
			dx := math.Abs(px-cx) / r
			dy := math.Abs(py-cy) / r
			if math.Pow(dx, n)+math.Pow(dy, n) <= 1 {
				img.SetRGBA(x, y, c)
			}
		}
	}
}

// maskSquircle 把 10-90 之外的像素清掉，留下圆角方形底板。
// 边界按到超椭圆的距离换算覆盖率，边沿有一像素宽的过渡；
// 若只按整像素裁，底边这种接近水平的长弧会留下台阶。
func maskSquircle(img *image.RGBA) {
	b := img.Bounds()
	n := float64(b.Dx()) / 100 // 1 个 0-100 坐标单位对应的像素数
	for y := 0; y < b.Dy(); y++ {
		v := math.Abs((float64(y)+0.5)/n-50) / 40
		v4 := v * v * v * v
		for x := 0; x < b.Dx(); x++ {
			u := math.Abs((float64(x)+0.5)/n-50) / 40
			u4 := u * u * u * u
			// f 是超椭圆隐函数，f/|grad f| 是到边界的距离（0-100 坐标单位）。
			f := u4*u + v4*v - 1
			g := 5 * math.Hypot(u4, v4) / 40
			if g == 0 {
				continue
			}
			cov := min(max(0.5-f/g*n, 0), 1)
			if cov >= 1 {
				continue
			}
			c := img.RGBAAt(x, y)
			img.SetRGBA(x, y, color.RGBA{
				R: uint8(float64(c.R)*cov + 0.5),
				G: uint8(float64(c.G)*cov + 0.5),
				B: uint8(float64(c.B)*cov + 0.5),
				A: uint8(float64(c.A)*cov + 0.5),
			})
		}
	}
}

// downsample 按 ss×ss 块求平均。image.RGBA 是预乘 alpha，直接平均即可。
func downsample(img *image.RGBA, ss int) *image.RGBA {
	w := img.Bounds().Dx() / ss
	h := img.Bounds().Dy() / ss
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	n := uint32(ss * ss)
	for y := range h {
		for x := range w {
			var r, g, b, a uint32
			for dy := range ss {
				base := img.PixOffset(x*ss, y*ss+dy)
				for dx := range ss {
					i := base + dx*4
					r += uint32(img.Pix[i])
					g += uint32(img.Pix[i+1])
					b += uint32(img.Pix[i+2])
					a += uint32(img.Pix[i+3])
				}
			}
			out.SetRGBA(x, y, color.RGBA{
				R: uint8(r / n), G: uint8(g / n), B: uint8(b / n), A: uint8(a / n),
			})
		}
	}
	return out
}
