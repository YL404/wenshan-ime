package main

import (
	"structs"

	"github.com/ebitengine/purego/objc"
)

// 这个文件只放纯 Go 调 Objective-C 需要的零件：选择器缓存和几条类型转换。
// 所有选择器都在启动时注册一次，RegisterName 会拿全局锁，不能放在热路径里。

var (
	selAlloc        = objc.RegisterName("alloc")
	selRelease      = objc.RegisterName("release")
	selRetain       = objc.RegisterName("retain")
	selInitWithUTF8 = objc.RegisterName("initWithUTF8String:")
	selUTF8String   = objc.RegisterName("UTF8String")

	selSharedApplication   = objc.RegisterName("sharedApplication")
	selSetActivationPolicy = objc.RegisterName("setActivationPolicy:")
	selRun                 = objc.RegisterName("run")
	selInitWithName        = objc.RegisterName("initWithName:bundleIdentifier:")

	selSetMarkedText = objc.RegisterName("setMarkedText:selectionRange:replacementRange:")
	selInsertText    = objc.RegisterName("insertText:replacementRange:")

	selCharacters    = objc.RegisterName("characters")
	selModifierFlags = objc.RegisterName("modifierFlags")
	selKeyCode       = objc.RegisterName("keyCode")
	selEventType     = objc.RegisterName("type")

	// 读光标前一个字符用的几个方法，都是 IMKTextInput 的标准接口。
	selSelectedRange       = objc.RegisterName("selectedRange")
	selMarkedRange         = objc.RegisterName("markedRange")
	selAttributedSubstring = objc.RegisterName("attributedSubstringFromRange:")
	selString              = objc.RegisterName("string")
	selLength              = objc.RegisterName("length")
	selCharacterAtIndex    = objc.RegisterName("characterAtIndex:")
)

// nsNotFound 是 Foundation 的 NSNotFound（NSIntegerMax），表示「没有替换范围」。
const nsNotFound = uintptr(1<<63 - 1)

const (
	nsBackingStoreBuffered       = 2
	nsWindowStyleNonactivating   = 1 << 7
	nsPopUpMenuWindowLevel       = 101
	nsCollectionCanJoinAllSpaces = 1 << 0
	nsCollectionFullScreenAux    = 1 << 8
)

// NSPoint/HWPoint 与 C 里的结构体逐字节对应，structs.HostLayout 是 purego 要求的分界标记。
type NSPoint struct {
	_    structs.HostLayout
	X, Y float64
}

type NSRect struct {
	_          structs.HostLayout
	X, Y, W, H float64
}

// NSRange 是 Foundation 的 {location, length}，arm64 上 16 字节走寄存器返回。
type NSRange struct {
	_        structs.HostLayout
	Location uintptr
	Length   uintptr
}

func send(id objc.ID, sel objc.SEL, args ...any) objc.ID {
	return objc.Send[objc.ID](id, sel, args...)
}

// nsString 用 UTF-8 建一个调用了 init 的 NSString（引用计数 1，用完要 release）。
func nsString(s string) objc.ID {
	cls := objc.ID(objc.GetClass("NSString"))
	return send(send(cls, selAlloc), selInitWithUTF8, s+"\x00")
}

// firstByte 取 NSEvent 里字符的第一个字节，没有字符时返回 0。
func firstByte(ns objc.ID) byte {
	if ns == 0 {
		return 0
	}
	p := objc.Send[*byte](ns, selUTF8String)
	if p == nil {
		return 0
	}
	return *p
}
