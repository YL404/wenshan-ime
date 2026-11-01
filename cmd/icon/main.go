// Command icon 画文山输入法的山形图标，输出 iconutil 需要的 .iconset 目录。
//
//	go run ./cmd/icon -out build/Wenshan.iconset -preview build/icon-preview.png
//
// 图形直接用扫描线填充画，不依赖任何绘图库；每档先放大四倍再降采样，
// 这样小尺寸也有干净的边缘。
package main

import (
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
)

type point struct{ X, Y float64 }

// 坐标都是 0-100 的归一化值，y 轴朝下。
var (
	backPeak = []point{{27, 34}, {-8, 90}, {56, 90}}
	mainPeak = []point{{54, 14}, {8, 90}, {96, 90}}
	snowCap  = []point{{54, 14}, {63, 37}, {58, 33}, {54, 38}, {49, 33}, {44, 37}}
)

var (
	backColor = color.RGBA{R: 0x7f, G: 0xa3, B: 0xc4, A: 0xff}
	mainColor = color.RGBA{R: 0x2e, G: 0x4a, B: 0x66, A: 0xff}
	capColor  = color.RGBA{R: 0xff, G: 0xff, B: 0xff, A: 0xff}
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

func main() {
	out := flag.String("out", "build/Wenshan.iconset", "输出的 iconset 目录")
	preview := flag.String("preview", "", "另外输出一张预览图")
	flag.Parse()

	if err := os.MkdirAll(*out, 0o755); err != nil {
		log.Fatal(err)
	}
	for _, it := range iconset {
		if err := writePNG(filepath.Join(*out, it.name), render(it.size)); err != nil {
			log.Fatal(err)
		}
	}
	fmt.Printf("%s: %d 个尺寸\n", *out, len(iconset))
	if *preview != "" {
		if err := writePNG(*preview, render(512)); err != nil {
			log.Fatal(err)
		}
		fmt.Println(*preview)
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

// render 画一张 size×size 的图标。小尺寸用 4 倍超采样，大尺寸用 2 倍。
func render(size int) *image.RGBA {
	ss := 4
	if size >= 512 {
		ss = 2
	}
	w := size * ss
	img := image.NewRGBA(image.Rect(0, 0, w, w))
	scale := float64(w) / 100

	fill(img, backColor, scalePoints(backPeak, scale))
	fill(img, mainColor, scalePoints(mainPeak, scale))
	fill(img, capColor, scalePoints(snowCap, scale))

	return downsample(img, ss)
}

func scalePoints(pts []point, s float64) []point {
	out := make([]point, len(pts))
	for i, p := range pts {
		out[i] = point{p.X * s, p.Y * s}
	}
	return out
}

// fill 用扫描线填多边形（奇偶规则）。
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
