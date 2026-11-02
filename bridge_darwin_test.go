package main

import (
	"testing"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"

	"wenshan/engine"
)

// 验证几处容易踩 ABI 的调用：NSString 往返、指针返回、NSRect 返回、结构体传参。
func TestObjCBridge(t *testing.T) {
	if _, err := purego.Dlopen("/System/Library/Frameworks/AppKit.framework/AppKit",
		purego.RTLD_NOW|purego.RTLD_GLOBAL); err != nil {
		t.Fatal(err)
	}

	// NSString 往返 + UTF8String 返回指针
	ns := nsString("文山")
	if ns == 0 {
		t.Fatal("nsString 返回 nil")
	}
	if got := firstByte(ns); got == 0 {
		t.Fatal("firstByte 读不到内容")
	}

	// 结构体传参：initWithFrame: 接 NSRect
	label := send(send(objc.ID(objc.GetClass("NSTextField")), selAlloc), selInitWithFrame,
		NSRect{X: 1, Y: 2, W: 300, H: 30})
	if label == 0 {
		t.Fatal("NSTextField 初始化失败")
	}

	// 浮点结构体返回：frame
	frame := objc.Send[NSRect](label, objc.RegisterName("frame"))
	if frame.W != 300 || frame.H != 30 {
		t.Fatalf("frame = %+v, 期望 300x30", frame)
	}
}

func TestCandidateItems(t *testing.T) {
	items := candidateItems([]engine.Candidate{{Text: "你好"}, {Text: "你"}})
	if len(items) != 2 ||
		items[0].label != "1." || items[0].text != "你好" ||
		items[1].label != "2." || items[1].text != "你" {
		t.Fatalf("items = %v", items)
	}
}
