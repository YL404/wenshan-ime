// Command icon 画文山输入法的图标：纸色圆角方形 + 墨山 + 朱红小印，
// 同时输出菜单栏用的单色方块镂空图标。
//
//	go run ./cmd/icon -out build/Wenshan.iconset -menu-out build/WenshanMenu.iconset
//
// 图形直接用扫描线填充画，不依赖任何绘图库；每档先放大四倍再降采样，
// 这样小尺寸也有干净的边缘。
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

// 坐标都是 0-100 的归一化值，y 轴朝下。App 图标的圆角方形占 10-90。
var (
	backPeak = []point{{30, 44}, {2, 86}, {60, 86}}
	mainPeak = []point{{55, 36}, {16, 86}, {94, 86}}
	snowCap  = []point{{55, 36}, {69, 54}, {61, 49}, {55, 54}, {49, 49}, {41, 54}}
	seal     = []point{{74, 15}, {83, 15}, {83, 24}, {74, 24}}
	sealPeak = []point{{76, 22}, {78, 19.5}, {79.2, 20.8}, {80.5, 17}, {82, 22}}
)

var (
	paper   = color.RGBA{R: 0xf3, G: 0xec, B: 0xdd, A: 0xff}
	snow    = color.RGBA{R: 0xf8, G: 0xfb, B: 0xfd, A: 0xff}
	ink     = color.RGBA{R: 0x1f, G: 0x2a, B: 0x36, A: 0xff}
	inkWash = color.RGBA{R: 0x7e, G: 0x93, B: 0xa3, A: 0xff}
	sealRed = color.RGBA{R: 0xc0, G: 0x50, B: 0x3a, A: 0xff}
	menuInk = color.RGBA{A: 0xff}
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

// renderApp 画一张 size×size 的 App 图标：纸色圆角方形、墨山、朱红小印。
func renderApp(size int) *image.RGBA {
	ss := 4
	if size >= 512 {
		ss = 2
	}
	w := size * ss
	img := image.NewRGBA(image.Rect(0, 0, w, w))
	draw.Draw(img, img.Bounds(), &image.Uniform{C: paper}, image.Point{}, draw.Src)

	scale := float64(w) / 100
	fill(img, inkWash, scalePoints(backPeak, scale))
	fill(img, ink, scalePoints(mainPeak, scale))
	fill(img, snow, scalePoints(snowCap, scale))
	fill(img, sealRed, scalePoints(seal, scale))
	fill(img, paper, scalePoints(sealPeak, scale))
	maskSquircle(img)

	return downsample(img, ss)
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
func maskSquircle(img *image.RGBA) {
	b := img.Bounds()
	n := float64(b.Dx())
	for y := 0; y < b.Dy(); y++ {
		ny := math.Abs((float64(y)+0.5)/n*100-50) / 40
		yn := math.Pow(ny, 5)
		for x := 0; x < b.Dx(); x++ {
			nx := math.Abs((float64(x)+0.5)/n*100-50) / 40
			if math.Pow(nx, 5)+yn > 1 {
				img.SetRGBA(x, y, color.RGBA{})
			}
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
