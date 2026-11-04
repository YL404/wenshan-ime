package main

import (
	"runtime"
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

	// NSRange 传参与返回：charBefore 靠这两条路径读光标前的正文。
	// 客户端给的是 NSAttributedString，NSString 没有这个方法。
	plain := nsString("我 abc")
	attr := send(send(objc.ID(objc.GetClass("NSAttributedString")), selAlloc),
		objc.RegisterName("initWithString:"), plain)
	if attr == 0 {
		t.Fatal("NSAttributedString 初始化失败")
	}
	sub := send(attr, selAttributedSubstring, 2, 1)
	if sub == 0 {
		t.Fatal("attributedSubstringFromRange: 返回 nil")
	}
	str := send(sub, selString)
	if str == 0 || objc.Send[uintptr](str, selLength) != 1 {
		t.Fatal("取不到正文片段")
	}
	if u := objc.Send[uint16](str, selCharacterAtIndex, uintptr(0)); u != 'a' {
		t.Fatalf("characterAtIndex = %c (%#x)", u, u)
	}
	span := objc.Send[NSRange](plain, objc.RegisterName("rangeOfString:"), nsString("abc"))
	if span.Location != 2 || span.Length != 3 {
		t.Fatalf("rangeOfString = %+v, 期望 {2 3}", span)
	}

	// 真客户端：charBefore 走 selectedRange + attributedSubstringFromRange:。
	// NSTextView 改选区会建输入法光标窗，NSWindow 只能在主线程创建，
	// 测试 goroutine 不一定在主线程上，和其他窗口测试一样带守卫。
	runtime.LockOSThread()
	if send(objc.ID(objc.GetClass("NSThread")), objc.RegisterName("isMainThread")) == 0 {
		t.Log("不在主线程，跳过 NSTextView 部分")
		return
	}
	view := send(send(objc.ID(objc.GetClass("NSTextView")), selAlloc),
		objc.RegisterName("initWithFrame:"), NSRect{W: 300, H: 100})
	if view == 0 {
		t.Fatal("NSTextView 初始化失败")
	}
	send(view, objc.RegisterName("setString:"), plain)
	send(view, objc.RegisterName("setSelectedRange:"), 3, 0)
	if r, ok := charBefore(view); !ok || r != 'a' {
		t.Fatalf("charBefore = %q, %v, 期望 a", r, ok)
	}
	// 光标在行首时问不到前一个字符。
	send(view, objc.RegisterName("setSelectedRange:"), 0, 0)
	if r, ok := charBefore(view); ok {
		t.Fatalf("行首 charBefore = %q, 不该有结果", r)
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
