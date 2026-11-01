// Command tisprobe 列出系统已注册的输入源，用来自查 Wenshan.app 有没有被 macOS 认到。
//
//	go run ./cmd/tisprobe
package main

import (
	"flag"
	"fmt"
	"strings"
	"time"
	"unsafe"

	"github.com/ebitengine/purego"
)

const kCFStringEncodingUTF8 = 0x08000100

func main() {
	selectID := flag.String("select", "", "选中 ID 匹配的输入源")
	register := flag.String("register", "", "重新注册输入法 bundle 路径")
	enable := flag.String("enable", "", "启用并选中匹配的输入源")
	flag.Parse()
	cf, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_NOW|purego.RTLD_GLOBAL)
	check(err)
	hit, err := purego.Dlopen("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", purego.RTLD_NOW|purego.RTLD_GLOBAL)
	check(err)

	var (
		cfStringGetCString        func(s uintptr, buf *byte, size int64, enc uint32) bool
		cfArrayGetCount           func(arr uintptr) int64
		cfArrayGetValueAtIndex    func(arr uintptr, idx int64) uintptr
		tisCreateInputSourceList  func(props uintptr, includeAll bool) uintptr
		tisGetInputSourceProperty func(src, key uintptr) uintptr
		tisSelectInputSource      func(src uintptr) int32
		tisRegisterInputSource    func(url uintptr) int32
		tisEnableInputSource      func(src uintptr) int32
		cfURLCreateFromPath       func(alloc uintptr, path *byte, length int64, isDir bool) uintptr
	)
	purego.RegisterLibFunc(&cfStringGetCString, cf, "CFStringGetCString")
	purego.RegisterLibFunc(&cfArrayGetCount, cf, "CFArrayGetCount")
	purego.RegisterLibFunc(&cfArrayGetValueAtIndex, cf, "CFArrayGetValueAtIndex")
	purego.RegisterLibFunc(&tisCreateInputSourceList, hit, "TISCreateInputSourceList")
	purego.RegisterLibFunc(&tisGetInputSourceProperty, hit, "TISGetInputSourceProperty")
	purego.RegisterLibFunc(&tisSelectInputSource, hit, "TISSelectInputSource")
	purego.RegisterLibFunc(&tisRegisterInputSource, hit, "TISRegisterInputSource")
	purego.RegisterLibFunc(&tisEnableInputSource, hit, "TISEnableInputSource")
	purego.RegisterLibFunc(&cfURLCreateFromPath, cf, "CFURLCreateFromFileSystemRepresentation")

	// 属性键必须用 TIS 导出的那几个 CFString 常量，自己造等值字符串查不到。
	key := func(name string) uintptr {
		addr, err := purego.Dlsym(hit, name)
		check(err)
		var p unsafe.Pointer
		*(*uintptr)(unsafe.Pointer(&p)) = addr
		return *(*uintptr)(p)
	}
	str := func(ref uintptr) string {
		if ref == 0 {
			return ""
		}
		buf := make([]byte, 512)
		if !cfStringGetCString(ref, &buf[0], int64(len(buf)), kCFStringEncodingUTF8) {
			return ""
		}
		n := 0
		for n < len(buf) && buf[n] != 0 {
			n++
		}
		return string(buf[:n])
	}

	sources := tisCreateInputSourceList(0, true)
	if sources == 0 {
		fmt.Println("TISCreateInputSourceList 返回空")
		return
	}
	kID := key("kTISPropertyInputSourceID")
	kName := key("kTISPropertyLocalizedName")
	kSelected := key("kTISPropertyInputSourceIsSelected")

	total := cfArrayGetCount(sources)
	fmt.Printf("系统已注册输入源 %d 个\n", total)
	found := 0
	for i := int64(0); i < total && i < 12; i++ {
		src := cfArrayGetValueAtIndex(sources, i)
		fmt.Printf("  %s\n", str(tisGetInputSourceProperty(src, kID)))
	}
	// 注意：这里只启用，不做禁用。TISDisableInputSource 会把输入源从用户的
	// 列表里移掉，而且很难用代码加回去。
	if *enable != "" {
		// 先找完全相等的（输入法本体），再退回包含匹配（某个模式）。
		pick := func(exact bool) uintptr {
			for i := int64(0); i < cfArrayGetCount(sources); i++ {
				src := cfArrayGetValueAtIndex(sources, i)
				id := str(tisGetInputSourceProperty(src, kID))
				if exact && id == *enable || !exact && strings.Contains(id, *enable) {
					return src
				}
			}
			return 0
		}
		src := pick(true)
		if src == 0 {
			src = pick(false)
		}
		if src != 0 {
			id := str(tisGetInputSourceProperty(src, kID))
			fmt.Printf("  启用 %s -> %d\n", id, tisEnableInputSource(src))
			time.Sleep(300 * time.Millisecond)
			fmt.Printf("  选中 %s -> %d\n", id, tisSelectInputSource(src))
		}
	}
	if *register != "" {
		buf := []byte(*register)
		url := cfURLCreateFromPath(0, &buf[0], int64(len(buf)), true)
		if url == 0 {
			fmt.Println("CFURL 创建失败")
		} else {
			fmt.Printf("重新注册 %s -> 返回 %d\n", *register, tisRegisterInputSource(url))
		}
	}
	// 先处理切换请求：可以切到任何输入源，不只是文山。
	if *selectID != "" {
		for i := int64(0); i < cfArrayGetCount(sources); i++ {
			src := cfArrayGetValueAtIndex(sources, i)
			id := str(tisGetInputSourceProperty(src, kID))
			if !strings.Contains(id, *selectID) {
				continue
			}
			rc := tisSelectInputSource(src)
			fmt.Printf("  选中 %s -> 返回 %d\n", id, rc)
			break
		}
	}
	for i := int64(0); i < cfArrayGetCount(sources); i++ {
		src := cfArrayGetValueAtIndex(sources, i)
		id := str(tisGetInputSourceProperty(src, kID))
		if !strings.Contains(id, "wenshan") {
			continue
		}
		found++
		sel := "未选中"
		if tisGetInputSourceProperty(src, kSelected) != 0 {
			sel = "已选中"
		}
		fmt.Printf("%s\n    %s  [%s]\n", id, str(tisGetInputSourceProperty(src, kName)), sel)
	}
	if found == 0 {
		fmt.Println("没有找到 wenshan 输入源：bundle 还没被 macOS 认到")
	}
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}
