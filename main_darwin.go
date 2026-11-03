// Command Wenshan 是 macOS 上的双拼自然码输入法主体。
//
// 它由系统在切换到「文山」输入源时启动，是一个没有 Dock 图标的后台进程：
// 先注册 IMKInputController 的子类，再建 IMKServer，最后进入 AppKit 事件循环。
// 按键处理和候选窗都在这个进程里，不跨进程、不依赖外部输入法引擎。
package main

import (
	_ "embed"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"

	"wenshan/engine"
	"wenshan/input"
)

// dict.bin 由 cmd/dictgen 从 Rime 词库生成，跟着可执行文件一起映射进内存，
// 运行时零解析、按页懒加载。
//
//go:embed dict.bin
var dictBin []byte

const (
	bundleID  = "im.wenshan.inputmethod.Wenshan"
	connName  = bundleID + ".Connection"
	inputMode = bundleID + ".Hans"
)

var (
	logFile   *os.File
	debugKeys bool // ~/Library/Application Support/Wenshan/debug 存在时打印每个按键
)

func logf(format string, args ...any) { log.Printf(format, args...) }

func main() {
	// AppKit 要求 UI 和事件循环待在同一个线程上，锁住它。
	runtime.LockOSThread()

	openLog()
	defer logFile.Close()

	if err := loadFrameworks(); err != nil {
		log.Fatalf("加载系统框架失败: %v", err)
	}
	dict, err := engine.OpenDict(dictBin)
	if err != nil {
		log.Fatalf("词表: %v", err)
	}
	eng := engine.New(dict)
	eng.SetFreq(engine.LoadFreq(freqPath()))
	eng.SetUserDict(engine.LoadUserDict(userDictPath()))
	eng.SetPhrases(engine.LoadUserDict(phrasesPath()))
	sess = input.New(eng)
	// 补空格的判断要读宿主正文：光标前一个字符。查不到就当前面没有字符。
	sess.SetLookbehind(func() (rune, bool) {
		r, ok := charBefore(curClient)
		if debugKeys {
			logf("lookbehind %q ok=%v", r, ok)
		}
		return r, ok
	})

	app := send(objc.ID(objc.GetClass("NSApplication")), selSharedApplication)
	if app == 0 {
		log.Fatal("NSApplication 不可用")
	}
	// accessory：没有 Dock 图标，但仍然是一个正常的事件循环。
	send(app, selSetActivationPolicy, uintptr(1))

	if err := registerController(); err != nil {
		log.Fatalf("注册输入法类失败: %v", err)
	}
	// 这两个参数要的是 NSString，不能传 C 字符串指针。
	name, bundle := nsString(connName), nsString(bundleID)
	server := send(send(objc.ID(objc.GetClass("IMKServer")), selAlloc), selInitWithName, name, bundle)
	send(name, selRelease)
	send(bundle, selRelease)
	if server == 0 {
		log.Fatal("IMKServer 创建失败")
	}

	logf("就绪: %s, 词表 %d 条", connName, dict.Len())

	// 稍等 IMK 把服务挂好，再重新选中自己：升级或崩溃重启之后，
	// 前台 App 还连着旧实例，不重新选一次它不会把按键交过来。
	go func() {
		time.Sleep(600 * time.Millisecond)
		if err := selectOwnInputSource(); err != nil {
			logf("重新选中输入源失败: %v", err)
		}
	}()
	send(app, selRun) // 不返回
}

// loadFrameworks 用 dlopen 把系统框架载入。纯 Go 二进制没有链接它们，
// AppKit 和 InputMethodKit 里的类必须在这里显式加载后才能用。
func loadFrameworks() error {
	for _, path := range []string{
		"/System/Library/Frameworks/Foundation.framework/Foundation",
		"/System/Library/Frameworks/AppKit.framework/AppKit",
		"/System/Library/Frameworks/InputMethodKit.framework/InputMethodKit",
	} {
		if _, err := purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_GLOBAL); err != nil {
			return err
		}
	}
	return nil
}

// registerController 把 Go 函数注册成 IMKInputController 子类的方法。
// Info.plist 里的 InputMethodServerControllerClass 指向这个类名。
func registerController() error {
	_, err := objc.RegisterClass("WenshanInputController", objc.GetClass("IMKInputController"), nil, nil,
		[]objc.MethodDef{
			{Cmd: objc.RegisterName("handleEvent:client:"), Fn: handleEvent},
			{Cmd: objc.RegisterName("activateServer:"), Fn: activateServer},
			{Cmd: objc.RegisterName("deactivateServer:"), Fn: deactivateServer},
			{Cmd: objc.RegisterName("commitComposition:"), Fn: commitComposition},
			{Cmd: objc.RegisterName("recognizedEvents:"), Fn: recognizedEvents},
			{Cmd: selHideHud, Fn: hideHud},
		})
	return err
}

// freqPath 是用户词频文件的位置。
func freqPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "freq.tsv"
	}
	return filepath.Join(home, "Library", "Application Support", "Wenshan", "freq.tsv")
}

// userDictPath 是自造词文件的位置。
func userDictPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "userdict.tsv"
	}
	return filepath.Join(home, "Library", "Application Support", "Wenshan", "userdict.tsv")
}

// phrasesPath 是自定义短语文件的位置。格式同 userdict.tsv，但只读。
func phrasesPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "phrases.tsv"
	}
	return filepath.Join(home, "Library", "Application Support", "Wenshan", "phrases.tsv")
}

// openLog 把日志写到 ~/Library/Logs/Wenshan.log：系统启动输入法时没有终端，
// stderr 拿不到东西。
func openLog() {
	home, err := os.UserHomeDir()
	if err != nil {
		log.SetOutput(os.Stderr)
		return
	}
	f, err := os.OpenFile(filepath.Join(home, "Library", "Logs", "Wenshan.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.SetOutput(os.Stderr)
		return
	}
	logFile = f
	log.SetOutput(f)
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	// 把标准错误也接过来：Go panic 和系统框架的报错只会写到 fd 2，
	// 由系统启动时那个 fd 是丢掉的。
	if err := syscall.Dup2(int(f.Fd()), 2); err != nil {
		log.Printf("重定向 stderr 失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(freqPath()), "debug")); err == nil {
		debugKeys = true
		log.Printf("调试模式：打印每个按键")
	}
}
