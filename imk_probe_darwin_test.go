package main

import (
	"os"
	"runtime"
	"testing"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"

	"wenshan/engine"
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

	data, err := os.ReadFile("dict.bin")
	if err != nil {
		t.Skip("dict.bin 不存在:", err)
	}
	dict, err := engine.OpenDict(data)
	if err != nil {
		t.Fatal(err)
	}
	eng = engine.New(dict)

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
	t.Logf("handleEvent 'n' -> %v, buf=%q cands=%d", handled, eng.Buffer(), len(eng.Candidates()))
	if !handled {
		t.Fatal("字母键没被消费")
	}
	if string(eng.Buffer()) != "n" {
		t.Fatalf("缓冲 = %q", eng.Buffer())
	}
	if len(eng.Candidates()) == 0 {
		t.Fatal("没有候选")
	}
}
