package main

import (
	"os"
	"runtime"
	"testing"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"

	"wenshan/engine"
	"wenshan/input"
)

// 注册一个 IMKInputController 实例，直接朝它发消息验证事件路径：
// recognizedEvents: 要返回按键掩码；handleEvent:client: 收到合成按键要消费它。
// 如果这里全对而真机上按键不进来，问题就在 TIS/IMK 路由而不在代码。
func TestControllerContract(t *testing.T) {
	runtime.LockOSThread()
	loadAppKit(t)
	if _, err := purego.Dlopen("/System/Library/Frameworks/InputMethodKit.framework/InputMethodKit",
		purego.RTLD_NOW|purego.RTLD_GLOBAL); err != nil {
		t.Fatal(err)
	}
	send(objc.ID(objc.GetClass("NSApplication")), selSharedApplication)
	if send(objc.ID(objc.GetClass("NSThread")), objc.RegisterName("isMainThread")) == 0 {
		t.Skip("不在主线程")
	}

	testSession(t)

	if err := registerController(); err != nil {
		t.Fatal(err)
	}
	cls := objc.ID(objc.GetClass("WenshanInputController"))
	if cls == 0 {
		t.Fatal("WenshanInputController 没注册上")
	}
	ctl := send(send(cls, selAlloc), objc.RegisterName("init"))
	if ctl == 0 {
		t.Fatal("控制器 init 返回空")
	}

	// recognizedEvents: 应返回 keyDown|flagsChanged 掩码。
	selRecog := objc.RegisterName("recognizedEvents:")
	mask := objc.Send[uint](ctl, selRecog, ctl)
	t.Logf("recognizedEvents -> %d", mask)
	if mask != 1<<10|1<<12 {
		t.Fatalf("掩码 = %d，期望 %d", mask, 1<<10|1<<12)
	}

	// 合成一个 NSEvent keyDown 'n'（keyCode=45），看 handleEvent 是否消费。
	selKeyEvent := objc.RegisterName("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:")
	chars := nsString("n")
	event := send(objc.ID(objc.GetClass("NSEvent")), selKeyEvent,
		uintptr(10), NSPoint{X: 0, Y: 0}, uintptr(0), 0.0, 0, 0, chars, chars, false, uintptr(45))
	send(chars, selRelease)
	if event == 0 {
		t.Fatal("NSEvent 创建失败")
	}
	if got := objc.Send[uintptr](event, selEventType); got != 10 {
		t.Fatalf("event.type = %d", got)
	}

	handled := objc.Send[bool](ctl, objc.RegisterName("handleEvent:client:"), event, ctl)
	t.Logf("handleEvent 'n' -> %v, buf=%q cands=%d", handled, sess.Buffer(), len(sess.Candidates()))
	if !handled {
		t.Fatal("字母键没被消费")
	}
	if sess.Buffer() != "n" {
		t.Fatalf("缓冲 = %q", sess.Buffer())
	}
	if len(sess.Candidates()) == 0 {
		t.Fatal("没有候选")
	}
}

// testSession 用真实词表建一个干净的规则状态，两个按键路径测试共用。
func testSession(t *testing.T) {
	t.Helper()
	data, err := os.ReadFile("dict.bin")
	if err != nil {
		t.Skip("dict.bin 不存在:", err)
	}
	dict, err := engine.OpenDict(data)
	if err != nil {
		t.Fatal(err)
	}
	sess = input.New(engine.New(dict))
}

// recordedText 收集 recordingClient 收到的上屏文字。
var recordedText string

// recordInsert 是 recordingClient 的 insertText:replacementRange:。
func recordInsert(self objc.ID, cmd objc.SEL, text objc.ID, loc, length uintptr) {
	recordedText += string(firstByte(text))
}

// TestShiftLetterInserts 验证中文态 Shift+大写在没有拼音缓冲时直接上屏。
// 规则层只返回 Text，写回应用这一步在 handleEvent 里，漏掉就是「按住 Shift 打字没反应」。
func TestShiftLetterInserts(t *testing.T) {
	runtime.LockOSThread()
	loadAppKit(t)
	if _, err := purego.Dlopen("/System/Library/Frameworks/InputMethodKit.framework/InputMethodKit",
		purego.RTLD_NOW|purego.RTLD_GLOBAL); err != nil {
		t.Fatal(err)
	}
	send(objc.ID(objc.GetClass("NSApplication")), selSharedApplication)
	if send(objc.ID(objc.GetClass("NSThread")), objc.RegisterName("isMainThread")) == 0 {
		t.Skip("不在主线程")
	}
	testSession(t)
	if objc.GetClass("WenshanInputController") == 0 {
		if err := registerController(); err != nil {
			t.Fatal(err)
		}
	}

	cls, err := objc.RegisterClass("RecordingClient", objc.GetClass("NSObject"), nil, nil,
		[]objc.MethodDef{{Cmd: selInsertText, Fn: recordInsert}})
	if err != nil {
		t.Fatal(err)
	}
	client := send(send(objc.ID(cls), selAlloc), objc.RegisterName("init"))
	if client == 0 {
		t.Fatal("RecordingClient 初始化失败")
	}

	// 合成 Shift+字母 'a'（keyCode=0）：characters 是大写 A。
	selKeyEvent := objc.RegisterName("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:")
	chars := nsString("A")
	event := send(objc.ID(objc.GetClass("NSEvent")), selKeyEvent,
		uintptr(10), NSPoint{X: 0, Y: 0}, uintptr(nsModShift), 0.0, 0, 0, chars, chars, false, uintptr(0))
	send(chars, selRelease)

	ctl := send(send(objc.ID(objc.GetClass("WenshanInputController")), selAlloc), objc.RegisterName("init"))
	recordedText = ""
	handled := objc.Send[bool](ctl, objc.RegisterName("handleEvent:client:"), event, client)
	if !handled {
		t.Fatal("Shift+字母没被消费")
	}
	if recordedText != "A" {
		t.Fatalf("上屏 = %q，期望 %q", recordedText, "A")
	}
	if sess.Buffer() != "" || sess.Inline() != "" {
		t.Fatalf("不该留下组合: buf=%q inline=%q", sess.Buffer(), sess.Inline())
	}
}
