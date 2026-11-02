// Command icon 画文山输入法的图标：纸色圆角方形 + 分层墨色山峦 + 红日 + 云带，
// 同时输出菜单栏用的单色方块镂空图标。
//
//	go run ./cmd/icon -out build/Wenshan.iconset -menu-out build/WenshanMenu.iconset
//
// 图形直接用扫描线填充画，不依赖任何绘图库：山脊是二次贝塞尔采样成的多段折线，
// 云带用半透明晕染。每档先放大四倍再降采样，小尺寸也有干净的边缘。
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

// menuIcons 是菜单栏模板图的 1x/2x 两档。
var menuIcons = []struct {
	name string
	size int
}{
	{"icon_16x16.png", 16},
	{"icon_16x16@2x.png", 32},
}

func main() {
	out := flag.String("out", "build/Wenshan.iconset", "App 图标的 iconset 目录")
	menuOut := flag.String("menu-out", "build/WenshanMenu.iconset", "菜单栏图标的 iconset 目录")
	preview := flag.String("preview", "", "另外输出一张 App 图标预览图")
	menuPreview := flag.String("menu-preview", "", "另外输出一张菜单栏图标预览图")
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
		if err := writePNG(filepath.Join(*menuOut, it.name), renderMenu(it.size)); err != nil {
			log.Fatal(err)
		}
	}
	fmt.Printf("%s: %d 个尺寸\n", *out, len(iconset))
	fmt.Printf("%s: %d 个尺寸\n", *menuOut, len(menuIcons))
	if *preview != "" {
		if err := writePNG(*preview, renderApp(512)); err != nil {
			log.Fatal(err)
		}
		fmt.Println(*preview)
	}
	if *menuPreview != "" {
		if err := writePNG(*menuPreview, renderMenu(128)); err != nil {
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

// renderApp 画一张 size×size 的 App 图标：纸底、红日、四层山峦，云带拦腰。
// 绘制顺序就是深度顺序：日最远，墨山最近。
func renderApp(size int) *image.RGBA {
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

	out := downsample(img, ss)
	maskSquircle(out)
	return out
}

// renderMenu 画菜单栏模板：圆角方块挖掉一座山。
func renderMenu(size int) *image.RGBA {
	ss := 4
	w := size * ss
	img := image.NewRGBA(image.Rect(0, 0, w, w))
	scale := float64(w) / 16

	fillRoundedRect(img, menuInk, 0, 0, 16*scale, 16*scale, 3.6*scale)
	clear(img, scalePoints([]point{
		{2.2, 13.2}, {4.8, 7.6}, {6, 9.2}, {8.2, 3.6}, {13.8, 13.2},
	}, scale))

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

// fillRoundedRect 画实心圆角矩形。边界在放大后的像素空间里，降采样负责抗锯齿。
func fillRoundedRect(img *image.RGBA, c color.RGBA, x0, y0, x1, y1, r float64) {
	for y := int(math.Floor(y0)); y < int(math.Ceil(y1)); y++ {
		for x := int(math.Floor(x0)); x < int(math.Ceil(x1)); x++ {
			px, py := float64(x)+0.5, float64(y)+0.5
			if px < x0 || px > x1 || py < y0 || py > y1 {
				continue
			}
			cx := math.Max(x0+r, math.Min(px, x1-r))
			cy := math.Max(y0+r, math.Min(py, y1-r))
			dx, dy := px-cx, py-cy
			if dx*dx+dy*dy <= r*r {
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
	out := image.NewRGBA(image.Rect(0, 0, w, w))
	n := uint32(ss * ss)
	for y := range w {
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
