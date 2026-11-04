// Package mobile 是 iOS 键盘扩展调用的 Go 引擎入口。
//
// gomobile bind 只导出这里的方法，Swift 侧按「按键 -> 候选 -> 上屏」
// 三个动作调用。输入规则在 wenshan/input，macOS 和 iOS 共用同一份；
// 这里的锁只是防止扩展生命周期里偶发的跨线程调用把状态踩坏。
//
// 候选列表用 candidateSeparator 分隔的字符串返回：gomobile 不支持 []string 返回值。
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

	// 光标前正文的最后一个字符（已去掉末尾的预编辑串），Swift 每次按键前
	// 推进来。补空格的判断要用它。
	lastRune rune
	hasLast  bool
)

// Outcome 是一次规则动作的结果。Text 已经包含自动补的空格；
// Consumed 为 false 时 Swift 侧按原键处理（例如空格、回车、退格）。
type Outcome struct {
	Text       string
	Preedit    string
	Candidates string // 当前页候选，用 candidateSeparator 分隔
	Consumed   bool
	Mode       int // 0 中文，1 英文
	FullWidth  bool
}

// Open 映射词表并建立引擎。dictPath 由 Swift 侧从 App Group 或
// 扩展 Bundle 传进来；dataDir 用来加载用户词频、自造词和短语。
func Open(dictPath, dataDir string) bool {
	mu.Lock()
	defer mu.Unlock()

	saveLocked(true)
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
	s.SetLookbehind(func() (rune, bool) { return lastRune, hasLast })
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
//
// 组合中正文末尾挂着预编辑串本身，要在这里、按键动作执行之前去掉：
// 动作里选词会消耗缓冲，到规则层读光标前字符时预编辑已经变了。
func SetContextBefore(text string) {
	mu.Lock()
	defer mu.Unlock()
	if sess != nil {
		if pre := sess.Preedit(); pre != "" {
			text = strings.TrimSuffix(text, pre)
		}
	}
	lastRune, _ = utf8.DecodeLastRuneInString(text)
	hasLast = text != ""
}

// LastError 返回 Open 最近一次失败的原因。
func LastError() string {
	mu.Lock()
	defer mu.Unlock()
	return lastErr
}

// Flush 把词频和自造词里所有未落盘的改动写盘，扩展退出前调用。
// 返回写盘失败的原因，成功时返回空串。
func Flush() string {
	mu.Lock()
	defer mu.Unlock()
	if err := saveLocked(true); err != nil {
		return err.Error()
	}
	return ""
}

// saveLocked 写盘；force 为 false 时词频攒够次数才写，见 engine.Engine.Save。
func saveLocked(force bool) error {
	if sess == nil {
		return nil
	}
	return sess.Save(force)
}

func closeLocked() {
	sess = nil
	if mapped {
		syscall.Munmap(dictMap)
	}
	dictMap = nil
	mapped = false
}

// candidateSeparator 分隔候选文本。gomobile 不支持 []string，只能拼成一个
// 字符串；用 ASCII 单元分隔符，它不会出现在词条里，换行或回车也不会切错。
const candidateSeparator = "\x1f"

func candidatesText(cands []engine.Candidate) string {
	texts := make([]string, len(cands))
	for i, c := range cands {
		texts[i] = c.Text
	}
	return strings.Join(texts, candidateSeparator)
}

// run 在锁内执行一次规则动作，顺带按「攒够次数」写盘，返回动作后的组合状态。
// 词表还没打开时返回 nil。写盘失败不影响这次按键，Flush 时会再写一次。
func run(action func(*input.Session) input.Result) *Outcome {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil
	}
	r := action(sess)
	_ = saveLocked(false)
	return &Outcome{
		Text:       r.Text,
		Preedit:    sess.Preedit(),
		Candidates: candidatesText(sess.Candidates()),
		Consumed:   r.Consumed,
		Mode:       int(sess.Mode()),
		FullWidth:  sess.FullWidth(),
	}
}

func firstByte(s string) byte {
	if s == "" {
		return 0
	}
	return s[0]
}

// Current 返回当前组合状态和模式，不执行任何动作。
func Current() *Outcome {
	return run(func(*input.Session) input.Result { return input.Result{} })
}

// Type 追加一个 ASCII 字母。
func Type(key string) *Outcome {
	return run(func(s *input.Session) input.Result { return s.Type(firstByte(key)) })
}

// ShiftLetter 处理中文态 Shift+字母。
func ShiftLetter(key string) *Outcome {
	return run(func(s *input.Session) input.Result { return s.ShiftLetter(firstByte(key)) })
}

// Space 处理空格。没有组合时 Consumed=false，由 Swift 插入空格。
func Space() *Outcome {
	return run((*input.Session).Space)
}

// Return 处理回车。没有组合时 Consumed=false，由 Swift 按宿主语义换行。
func Return() *Outcome {
	return run((*input.Session).Return)
}

// Backspace 删除临时英文或拼音缓冲的一格。
func Backspace() *Outcome {
	return run((*input.Session).Backspace)
}

// Select 选中当前页第 i 个候选并上屏。
func Select(i int) *Outcome {
	return run(func(s *input.Session) input.Result { return s.Select(i) })
}

// SelectChar 取第 i 个候选的首字或尾字。
func SelectChar(i int, last bool) *Outcome {
	return run(func(s *input.Session) input.Result { return s.SelectChar(i, last) })
}

// SelectGlobal 选出全部候选里的第 i 个，索引可以落在后续页。
func SelectGlobal(i int) *Outcome {
	return run(func(s *input.Session) input.Result { return s.SelectGlobal(i) })
}

// Punctuate 把 ASCII 标点转成中文标点；半角时 Consumed=false。
func Punctuate(ch string) *Outcome {
	return run(func(s *input.Session) input.Result { return s.Punctuate(firstByte(ch)) })
}

// Direct 直接插入固定文本（英文字母、数字键、符号页）。
func Direct(text string) *Outcome {
	return run(func(s *input.Session) input.Result { return s.Direct(text) })
}

// ToggleMode 切换中英模式。
func ToggleMode() *Outcome {
	return run((*input.Session).ToggleMode)
}

// ToggleFullWidth 切换标点全角/半角。
func ToggleFullWidth() *Outcome {
	return run((*input.Session).ToggleFullWidth)
}

// Reset 清空当前组合，不删除已经上屏的文本。
func Reset() {
	mu.Lock()
	defer mu.Unlock()
	if sess != nil {
		sess.Reset()
	}
}

// AllCandidates 返回全部候选文本，供键盘展开显示。分隔符同 Outcome.Candidates。
func AllCandidates() string {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return ""
	}
	return candidatesText(sess.AllCandidates())
}
