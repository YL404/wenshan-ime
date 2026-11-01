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
	if len(items) != 2 || items[0] != "1.你好" || items[1] != "2.你" {
		t.Fatalf("items = %v", items)
	}
}

func TestPunctuate(t *testing.T) {
	if s, ok := punctuate(','); !ok || s != "，" {
		t.Fatalf("逗号 = %q", s)
	}
	if s, _ := punctuate('"'); s != "“" {
		t.Fatalf("第一个引号 = %q", s)
	}
	if s, _ := punctuate('"'); s != "”" {
		t.Fatalf("第二个引号 = %q", s)
	}
	if _, ok := punctuate('-'); ok {
		t.Fatal("减号不该被替换")
	}
}

func TestSpacing(t *testing.T) {
	defer func() { prevClass = prevNone }()

	prevClass = prevCJK
	if !needSpaceBefore('a') || !needSpaceBefore('9') {
		t.Fatal("中文后面接英文或数字应该补空格")
	}
	if needSpaceBefore(',') || needSpaceBefore(0) {
		t.Fatal("标点和空字符不该补空格")
	}
	prevClass = prevASCII
	if needSpaceBefore('a') {
		t.Fatal("英文后面接英文不该补空格")
	}
	if classOf("我") != prevCJK || classOf("abc") != prevASCII || classOf("，") != prevNone || classOf("") != prevNone {
		t.Fatal("classOf 分类不对")
	}
}
