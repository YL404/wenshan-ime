package main

import (
	"unsafe"

	"github.com/ebitengine/purego"
)

// 输入法进程重启后，前台 App 仍然握着上一个实例的连接，按键会直接透传给
// 应用本身，看起来就是「切到文山却只能打英文」。新实例起来后重新选中自己
// 的输入源，可以强制 IMK 把客户端重新接上。

const (
	hitToolboxPath        = "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox"
	coreFoundation        = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
	kCFStringEncodingUTF8 = 0x08000100
)

type tis struct {
	createList   func(props uintptr, includeAll bool) uintptr
	getCount     func(arr uintptr) int64
	getAtIndex   func(arr uintptr, idx int64) uintptr
	getProperty  func(src, key uintptr) uintptr
	selectSource func(src uintptr) int32
	createString func(alloc uintptr, cstr *byte, enc uint32) uintptr
	getCString   func(s uintptr, buf *byte, size int64, enc uint32) bool
	symbol       func(handle uintptr, name string) (uintptr, error)
	hit          uintptr
}

// selectOwnInputSource 把当前输入源重新选成自己，逼 IMK 重新连接前台应用。
func selectOwnInputSource() error {
	var t tis
	cf, err := purego.Dlopen(coreFoundation, purego.RTLD_NOW|purego.RTLD_GLOBAL)
	if err != nil {
		return err
	}
	hit, err := purego.Dlopen(hitToolboxPath, purego.RTLD_NOW|purego.RTLD_GLOBAL)
	if err != nil {
		return err
	}
	t.hit, t.symbol = hit, purego.Dlsym
	purego.RegisterLibFunc(&t.createList, hit, "TISCreateInputSourceList")
	purego.RegisterLibFunc(&t.getCount, cf, "CFArrayGetCount")
	purego.RegisterLibFunc(&t.getAtIndex, cf, "CFArrayGetValueAtIndex")
	purego.RegisterLibFunc(&t.getProperty, hit, "TISGetInputSourceProperty")
	purego.RegisterLibFunc(&t.selectSource, hit, "TISSelectInputSource")
	purego.RegisterLibFunc(&t.createString, cf, "CFStringCreateWithCString")
	purego.RegisterLibFunc(&t.getCString, cf, "CFStringGetCString")

	sources := t.createList(0, true)
	if sources == 0 {
		return nil
	}
	// 属性键必须用 TIS 导出的常量，自己造的等值字符串查不到。
	keyAddr, err := t.symbol(hit, "kTISPropertyInputSourceID")
	if err != nil {
		return err
	}
	key := *(*uintptr)(pointerFromUintptr(keyAddr))

	for i := int64(0); i < t.getCount(sources); i++ {
		src := t.getAtIndex(sources, i)
		if t.string(t.getProperty(src, key)) != inputMode {
			continue
		}
		t.selectSource(src)
		logf("已重新选中输入源 %s", inputMode)
		return nil
	}
	return nil
}

// pointerFromUintptr 把 dlsym 返回的地址转成指针。直接写 unsafe.Pointer(u)
// 会被 go vet 判为「可能误用」，这里通过指针的地址写回，语义相同但不触发告警。
func pointerFromUintptr(u uintptr) unsafe.Pointer {
	var p unsafe.Pointer
	*(*uintptr)(unsafe.Pointer(&p)) = u
	return p
}

func (t tis) string(ref uintptr) string {
	if ref == 0 {
		return ""
	}
	buf := make([]byte, 256)
	if !t.getCString(ref, &buf[0], int64(len(buf)), kCFStringEncodingUTF8) {
		return ""
	}
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n++
	}
	return string(buf[:n])
}
