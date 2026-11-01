// Command swap 原子交换两个目录，供安装脚本更新 .app 的 Contents。
//
// 直接把旧 Contents 挪走再拷新的，中间会有一段「bundle 不完整」的窗口，
// LaunchServices 会认为应用被卸载，输入源跟着失效。renamex_np(RENAME_SWAP)
// 是一次原子交换，两个目录始终有效。
package main

import (
	"fmt"
	"os"

	"github.com/ebitengine/purego"
)

const renameSwap = 0x00000002

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "用法: swap <新目录> <旧目录>")
		os.Exit(2)
	}
	lib, err := purego.Dlopen("/usr/lib/libSystem.B.dylib", purego.RTLD_NOW|purego.RTLD_GLOBAL)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var renamex func(from, to *byte, flags uint32) int32
	purego.RegisterLibFunc(&renamex, lib, "renamex_np")

	if rc := renamex(cstr(os.Args[1]), cstr(os.Args[2]), renameSwap); rc != 0 {
		fmt.Fprintf(os.Stderr, "renamex_np 失败: %d\n", rc)
		os.Exit(1)
	}
}

func cstr(s string) *byte {
	b := make([]byte, len(s)+1)
	copy(b, s)
	return &b[0]
}
