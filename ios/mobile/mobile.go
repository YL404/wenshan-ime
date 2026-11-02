// Package mobile 是 iOS 键盘扩展调用的 Go 引擎入口。
//
// gomobile bind 只导出这里的方法，Swift 侧按「按键 -> 候选 -> 上屏」
// 三个动作调用。引擎本身仍然只在主线程使用，这里的锁只是防止
// 扩展生命周期里偶发的跨线程调用把状态踩坏。
//
// 候选列表用换行分隔的字符串返回：gomobile 不支持 []string 返回值。
package mobile

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	"wenshan/engine"
)

var (
	mu      sync.Mutex
	eng     *engine.Engine
	dictMap []byte
	mapped  bool
	lastErr string
)

// Open 映射词表并建立引擎。dictPath 由 Swift 侧从 App Group 或
// 扩展 Bundle 传进来；dataDir 用来加载用户词频、自造词和短语。
func Open(dictPath, dataDir string) bool {
	mu.Lock()
	defer mu.Unlock()

	flushLocked()
	closeLocked()
	lastErr = ""

	f, err := os.Open(dictPath)
	if err != nil {
		lastErr = err.Error()
		return false
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		lastErr = err.Error()
		return false
	}
	data, err := syscall.Mmap(int(f.Fd()), 0, int(st.Size()), syscall.PROT_READ, syscall.MAP_PRIVATE)
	f.Close()
	if err != nil {
		// 模拟器或某些容器不支持 mmap 时退回整块读入，功能不变。
		data, err = os.ReadFile(dictPath)
		if err != nil {
			lastErr = err.Error()
			return false
		}
	} else {
		mapped = true
	}
	d, err := engine.OpenDict(data)
	if err != nil {
		if mapped {
			syscall.Munmap(data)
			mapped = false
		}
		lastErr = err.Error()
		return false
	}
	dictMap = data
	eng = engine.New(d)
	if dataDir != "" {
		eng.SetFreq(engine.LoadFreq(filepath.Join(dataDir, "freq.tsv")))
		eng.SetUserDict(engine.LoadUserDict(filepath.Join(dataDir, "userdict.tsv")))
		eng.SetPhrases(engine.LoadUserDict(filepath.Join(dataDir, "phrases.tsv")))
	}
	return true
}

// LastError 返回 Open 或引擎操作最近一次失败的原因。
func LastError() string {
	mu.Lock()
	defer mu.Unlock()
	return lastErr
}

// Close 保存用户数据并释放映射。
func Close() {
	mu.Lock()
	defer mu.Unlock()
	flushLocked()
	closeLocked()
}

// Flush 把攒够次数的词频和自造词写盘。扩展退出前调用。
func Flush() {
	mu.Lock()
	defer mu.Unlock()
	flushLocked()
}

func flushLocked() {
	if eng == nil {
		return
	}
	if err := eng.SaveFreq(); err != nil {
		lastErr = err.Error()
	}
	if err := eng.SaveUser(); err != nil {
		lastErr = err.Error()
	}
}

func closeLocked() {
	eng = nil
	if mapped {
		syscall.Munmap(dictMap)
	}
	dictMap = nil
	mapped = false
}

// Type 追加一个或多个 ASCII 按键，返回当前页候选文本。
func Type(keys string) string {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		return ""
	}
	for i := 0; i < len(keys); i++ {
		if !eng.Type(keys[i]) {
			break
		}
	}
	return candidatesLocked()
}

// Backspace 删除一个按键，返回当前页候选文本。
func Backspace() string {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		return ""
	}
	eng.Backspace()
	return candidatesLocked()
}

// Select 选中第 i 个候选并上屏，返回要插入的文本。
func Select(i int) string {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		return ""
	}
	text, ok := eng.Select(i)
	if !ok {
		return ""
	}
	flushLocked()
	return text
}

// Candidates 返回当前页候选文本。
func Candidates() string {
	mu.Lock()
	defer mu.Unlock()
	return candidatesLocked()
}

// Page 翻页，delta 为 +1/-1；返回翻页后的候选。
func Page(delta int) string {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		return ""
	}
	eng.Page(delta)
	return candidatesLocked()
}

// Buffer 返回当前按键缓冲，用于 marked text。
func Buffer() string {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		return ""
	}
	return string(eng.Buffer())
}

// Reset 清空当前组合，不删除已经上屏的文本。
func Reset() {
	mu.Lock()
	defer mu.Unlock()
	if eng != nil {
		eng.Reset()
	}
}

func candidatesLocked() string {
	if eng == nil {
		return ""
	}
	cs := eng.Candidates()
	out := make([]string, len(cs))
	for i, c := range cs {
		out[i] = c.Text
	}
	return strings.Join(out, "\n")
}
