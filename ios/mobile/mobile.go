// Package mobile 是 iOS 键盘扩展调用的 Go 引擎入口。
//
// gomobile bind 只导出这里的方法，Swift 侧按「按键 -> 候选 -> 上屏」
// 三个动作调用。输入规则在 wenshan/input，macOS 和 iOS 共用同一份；
// 这里的锁只是防止扩展生命周期里偶发的跨线程调用把状态踩坏。
//
// 候选列表用换行分隔的字符串返回：gomobile 不支持 []string 返回值。
package mobile

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unicode/utf8"

	"wenshan/engine"
	"wenshan/input"
)

var (
	mu      sync.Mutex
	sess    *input.Session
	dictMap []byte
	mapped  bool
	lastErr string

	// 光标前的正文，Swift 每次按键前推进来。补空格的判断要用它。
	contextBefore string
)

// Outcome 是一次规则动作的结果。Text 已经包含自动补的空格；
// Consumed 为 false 时 Swift 侧按原键处理（例如空格、回车、退格）。
type Outcome struct {
	Text       string
	Preedit    string
	Candidates string
	Consumed   bool
	Mode       int
	FullWidth  bool
}

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
	eng := engine.New(d)
	s := input.New(eng)
	// 补空格要读光标前一个字符；组合中正文末尾是预编辑串本身，先去掉。
	s.SetLookbehind(func() (rune, bool) {
		text := contextBefore
		if pre := s.Preedit(); pre != "" && strings.HasSuffix(text, pre) {
			text = text[:len(text)-len(pre)]
		}
		if text == "" {
			return 0, false
		}
		r, _ := utf8.DecodeLastRuneInString(text)
		return r, true
	})
	sess = s
	if dataDir != "" {
		eng.SetFreq(engine.LoadFreq(filepath.Join(dataDir, "freq.tsv")))
		eng.SetUserDict(engine.LoadUserDict(filepath.Join(dataDir, "userdict.tsv")))
		eng.SetPhrases(engine.LoadUserDict(filepath.Join(dataDir, "phrases.tsv")))
	}
	return true
}

// SetContextBefore 更新光标前的正文。Swift 在每次按键前调用；
// 规则层判断要不要补空格时读它，读不到就当前面没有字符。
func SetContextBefore(text string) {
	mu.Lock()
	defer mu.Unlock()
	contextBefore = text
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
	if sess == nil {
		return
	}
	if err := sess.SaveFreq(); err != nil {
		lastErr = err.Error()
	}
	if err := sess.SaveUser(); err != nil {
		lastErr = err.Error()
	}
}

func closeLocked() {
	sess = nil
	if mapped {
		syscall.Munmap(dictMap)
	}
	dictMap = nil
	mapped = false
}

func candidatesText(cands []engine.Candidate) string {
	texts := make([]string, len(cands))
	for i, c := range cands {
		texts[i] = c.Text
	}
	return strings.Join(texts, "\n")
}

func candidatesLocked() string {
	if sess == nil {
		return ""
	}
	return candidatesText(sess.Candidates())
}

func outcomeLocked(r input.Result) *Outcome {
	if sess == nil {
		return nil
	}
	flushLocked()
	return &Outcome{
		Text:       r.Text,
		Preedit:    sess.Preedit(),
		Candidates: candidatesLocked(),
		Consumed:   r.Consumed,
		Mode:       int(sess.Mode()),
		FullWidth:  sess.FullWidth(),
	}
}

func currentLocked() *Outcome {
	if sess == nil {
		return nil
	}
	return outcomeLocked(input.Result{Mode: sess.Mode(), FullWidth: sess.FullWidth()})
}

func firstByte(s string) byte {
	if s == "" {
		return 0
	}
	return s[0]
}

// Type 追加一个或多个 ASCII 按键，返回按键后的组合状态。
func Type(keys string) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	var r input.Result
	for i := 0; i < len(keys); i++ {
		r = sess.Type(keys[i])
		if !r.Consumed {
			break
		}
	}
	if len(keys) == 0 {
		return currentLocked()
	}
	return outcomeLocked(r)
}

// ShiftLetter 处理中文态 Shift+字母。
func ShiftLetter(ch string) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.ShiftLetter(firstByte(ch)))
}

// Space 处理空格。没有组合时 Consumed=false，由 Swift 插入空格。
func Space() *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Space())
}

// Return 处理回车。没有组合时 Consumed=false，由 Swift 按宿主语义换行。
func Return() *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Return())
}

// Backspace 删除临时英文或拼音缓冲的一格。
func Backspace() *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Backspace())
}

// Escape 取消临时英文或当前组合。
func Escape() *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Escape())
}

// Page 翻页，delta 为 +1/-1；返回翻页后的候选。
func Page(delta int) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Page(delta))
}

// Select 选中第 i 个候选并上屏，返回要插入的文本。
func Select(i int) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Select(i))
}

// SelectChar 取第 i 个候选的首字或尾字。
func SelectChar(i int, last bool) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.SelectChar(i, last))
}

// SelectGlobal 选出全部候选里的第 i 个，索引可以落在后续页。
func SelectGlobal(i int) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	text, ok := sess.SelectGlobal(i)
	if !ok {
		return nil
	}
	return outcomeLocked(input.Result{
		Text:      text,
		Consumed:  true,
		Mode:      sess.Mode(),
		FullWidth: sess.FullWidth(),
	})
}

// Punctuate 把 ASCII 标点转成中文标点；半角时 Consumed=false。
func Punctuate(ch string) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Punctuate(firstByte(ch)))
}

// Direct 直接插入固定文本（符号页、英文直通）。
func Direct(text string) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Direct(text))
}

// Passthrough 处理交给应用的按键，只更新自动补空格的状态。
func Passthrough(ch string) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Passthrough(firstByte(ch)))
}

// ToggleMode 切换中英模式。
func ToggleMode() *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.ToggleMode())
}

// ToggleFullWidth 切换标点全角/半角。
func ToggleFullWidth() *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.ToggleFullWidth())
}

// Reset 清空当前组合，不删除已经上屏的文本。
func Reset() {
	mu.Lock()
	defer mu.Unlock()
	if sess != nil {
		sess.Reset()
	}
}

// Finish 把未完成的输入上屏并清干净。
func Finish() *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	return outcomeLocked(sess.Finish())
}

// Candidates 返回当前页候选文本。
func Candidates() string {
	mu.Lock()
	defer mu.Unlock()
	return candidatesLocked()
}

// AllCandidates 返回全部候选文本，供键盘展开显示。
func AllCandidates() string {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return ""
	}
	return candidatesText(sess.AllCandidates())
}

// Preedit 返回当前预编辑串（临时英文或拼音缓冲）。
func Preedit() string {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return ""
	}
	return sess.Preedit()
}

// Mode 返回当前模式：0 中文，1 英文。
func Mode() int {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return 0
	}
	return int(sess.Mode())
}

// FullWidth 返回标点是否全角。
func FullWidth() bool {
	mu.Lock()
	defer mu.Unlock()
	return sess != nil && sess.FullWidth()
}
