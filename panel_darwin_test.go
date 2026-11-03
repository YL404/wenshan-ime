package main

import (
	"os"
	"runtime"
	"testing"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

func loadAppKit(t *testing.T) {
	t.Helper()
	for _, p := range []string{
		"/System/Library/Frameworks/Foundation.framework/Foundation",
		"/System/Library/Frameworks/AppKit.framework/AppKit",
	} {
		if _, err := purego.Dlopen(p, purego.RTLD_NOW|purego.RTLD_GLOBAL); err != nil {
			t.Fatal(err)
		}
	}
}

// 真实地建一次候选窗，确认圆角图层和色块这套调用不会崩、尺寸合理。
// NSWindow 只能在主线程创建，所以这个测试单独存在，并且带主线程守卫。
func TestCandidatePanel(t *testing.T) {
	runtime.LockOSThread()
	loadAppKit(t)
	send(objc.ID(objc.GetClass("NSApplication")), selSharedApplication)
	if send(objc.ID(objc.GetClass("NSThread")), objc.RegisterName("isMainThread")) == 0 {
		t.Skip("不在主线程，跳过窗口测试")
	}

	if !cand.ensure() {
		t.Fatal("候选窗创建失败")
	}
	caret := NSRect{X: 300, Y: 400, W: 2, H: 16}
	cand.layout([]candidateItem{
		{label: "1.", text: "你好"},
		{label: "2.", text: "你"},
		{label: "3.", text: "我"},
	}, 0, caret)
	f := objc.Send[NSRect](cand.panel, selFrame)
	t.Logf("三个候选: frame = %+v", f)
	if f.W < 100 || f.H < 20 {
		t.Fatalf("尺寸不合理: %+v", f)
	}
	if f.X != caret.X || f.Y+f.H != caret.Y-4 {
		t.Fatalf("位置不对: %+v", f)
	}

	// 提示只有一个色块，应该窄一些。
	wide := f.W
	cand.layout([]candidateItem{{text: "英"}}, -1, caret)
	f = objc.Send[NSRect](cand.panel, selFrame)
	t.Logf("模式提示: frame = %+v", f)
	if f.W >= wide || f.W < 30 {
		t.Fatalf("提示尺寸不合理: %+v", f)
	}
	cand.hide()

	// 尺寸随内容变化，位置始终贴着光标。
	send(cand.panel, selSetContentSize, NSSize{X: 200, Y: 30})
	send(cand.panel, selSetFrameTopLeftPoint, NSPoint{X: 640, Y: 500})
	f = objc.Send[NSRect](cand.panel, selFrame)
	if f.W != 200 || f.H != 30 || f.X != 640 || f.Y+f.H != 500 {
		t.Fatalf("面板定位不对: %+v", f)
	}
}

// 图层相关的调用（圆角、背景色）单独验证，不需要建窗口。
func TestLayerSupport(t *testing.T) {
	runtime.LockOSThread()
	loadAppKit(t)

	view := send(send(objc.ID(objc.GetClass("NSView")), selAlloc), selInitWithFrame, NSRect{W: 10, H: 10})
	send(view, selSetWantsLayer, true)
	layer := send(view, selLayer)
	if layer == 0 {
		t.Fatal("view.layer 为空")
	}
	send(layer, selSetCornerRadius, 8.0)
	got := objc.Send[float64](layer, objc.RegisterName("cornerRadius"))
	if got != 8.0 {
		t.Fatalf("cornerRadius = %v", got)
	}
	cg := send(send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.12, 0.97), selCGColor)
	if cg == 0 {
		t.Fatal("NSColor.CGColor 为空")
	}
	send(layer, selSetBackgroundColor, cg)
	send(layer, selSetMasksToBounds, true)
}

// 把候选窗渲染成 PNG，用于肉眼检查对齐和配色。
func TestRenderPanel(t *testing.T) {
	runtime.LockOSThread()
	loadAppKit(t)
	send(objc.ID(objc.GetClass("NSApplication")), selSharedApplication)
	if send(objc.ID(objc.GetClass("NSThread")), objc.RegisterName("isMainThread")) == 0 {
		t.Skip("不在主线程，跳过窗口测试")
	}
	if !cand.ensure() {
		t.Fatal("候选窗创建失败")
	}
	cand.layout([]candidateItem{
		{label: "1.", text: "一般"},
		{label: "2.", text: "一半"},
		{label: "3.", text: "已办"},
		{label: "4.", text: "一班"},
		{label: "5.", text: "一版"},
	}, 0, NSRect{X: 300, Y: 400, W: 2, H: 16})
	for i := 0; i < 5; i++ {
		t.Logf("chip[%d] bg=%+v text=%+v", i,
			objc.Send[NSRect](cand.bg[i], selFrame), objc.Send[NSRect](cand.chips[i], selFrame))
	}

	f := objc.Send[NSRect](cand.panel, selFrame)
	t.Logf("panel = %+v", f)
	send(cand.panel, objc.RegisterName("displayIfNeeded"))

	view := cand.content
	rect := NSRect{W: f.W, H: f.H}
	data := send(view, objc.RegisterName("dataWithPDFInsideRect:"), rect)
	if data == 0 {
		t.Fatal("PDF data 为空")
	}
	os.MkdirAll("build", 0o755)
	if rep := send(view, objc.RegisterName("bitmapImageRepForCachingDisplayInRect:"), rect); rep != 0 {
		send(view, objc.RegisterName("cacheDisplayInRect:toBitmapImageRep:"), rect, rep)
		if png := send(rep, objc.RegisterName("representationUsingType:properties:"), uintptr(4), uintptr(0)); png != 0 {
			p := nsString("build/panel-preview.png")
			send(png, objc.RegisterName("writeToFile:atomically:"), p, false)
			send(p, selRelease)
		}
	}
	path := "build/panel-preview.pdf"
	nsPath := nsString(path)
	ok := send(data, objc.RegisterName("writeToFile:atomically:"), nsPath, false)
	send(nsPath, selRelease)
	if ok == 0 {
		t.Fatal("写 PDF 失败")
	}
	cand.hide()
}
