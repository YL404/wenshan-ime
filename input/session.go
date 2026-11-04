// Package input 是 macOS 和 iOS 共用的输入规则层。
//
// 平台壳只负责把系统事件或触摸翻译成这里的动作，再把 Result 落到预编辑、
// 候选条和正文。标点、全半角、中英模式、Shift、临时英文、空格/回车/退格
// 以及中英文之间的自动补空格都在这里维护，两端不再各写一份。补空格的判断
// 靠平台壳提供的 lookbehind 读光标前一个字符，规则层不猜正文内容。
package input

import (
	"unicode"
	"unicode/utf8"

	"wenshan/engine"
)

// Mode 是输入模式。英文模式只做直通，不参与拼音组句。
type Mode int

const (
	Chinese Mode = iota
	English
)

// class 是字符的类别，用来判断中英文之间要不要补空格。
type class int

const (
	classNone class = iota
	classCJK
	classASCII
)

// Result 是一次规则动作的结果。Text 已经包含自动补的空格；
// Consumed 为 false 时平台按原键处理（例如没有候选时回车换行）。
type Result struct {
	Text      string
	Consumed  bool
	Mode      Mode
	FullWidth bool
}

// Session 持有一次输入过程的全部规则状态。它只在主线程使用，不加锁。
type Session struct {
	eng        *engine.Engine
	mode       Mode
	fullWidth  bool
	punctAlt   [128]bool
	lookbehind func() (rune, bool)
	inline     string
	inlineSp   bool
}

// SetLookbehind 设置「读光标前一个字符」的钩子。平台壳用它查宿主正文，
// 判断中英文之间要不要补空格。不设置或返回 false 时当作前面没有字符。
func (s *Session) SetLookbehind(fn func() (rune, bool)) { s.lookbehind = fn }

// New 建立规则状态机。eng 可以为 nil，此时只做缓冲和标点规则（用于测试）。
func New(eng *engine.Engine) *Session {
	return &Session{eng: eng, fullWidth: true}
}

func (s *Session) Mode() Mode      { return s.mode }
func (s *Session) FullWidth() bool { return s.fullWidth }
func (s *Session) Inline() string  { return s.inline }

// Buffer 返回当前拼音缓冲。
func (s *Session) Buffer() string {
	if s == nil || s.eng == nil {
		return ""
	}
	return string(s.eng.Buffer())
}

// Preedit 返回应该显示为预编辑的串：临时英文优先，否则是拼音缓冲。
func (s *Session) Preedit() string {
	if s.inline != "" {
		return s.inline
	}
	return s.Buffer()
}

// Candidates 返回当前页候选。
func (s *Session) Candidates() []engine.Candidate {
	if s == nil || s.eng == nil {
		return nil
	}
	return s.eng.Candidates()
}

// PageNo 返回当前候选页码（0 起），供候选窗显示进度。
func (s *Session) PageNo() int {
	if s == nil || s.eng == nil {
		return 0
	}
	return s.eng.PageNo()
}

// HasNextPage 报告是否还有下一页候选，供候选窗显示「还有更多 / 到底」。
func (s *Session) HasNextPage() bool {
	if s == nil || s.eng == nil {
		return false
	}
	return s.eng.HasNextPage()
}

// AllCandidates 返回第 1 页和后续页的全部候选，供键盘展开显示。
func (s *Session) AllCandidates() []engine.Candidate {
	if s == nil || s.eng == nil {
		return nil
	}
	return s.eng.AllCandidates()
}

// Save 把用户词频和自造词写盘，force 的含义见 engine.Engine.Save。
func (s *Session) Save(force bool) error {
	if s == nil || s.eng == nil {
		return nil
	}
	return s.eng.Save(force)
}

func (s *Session) result(text string, consumed bool) Result {
	return Result{Text: text, Consumed: consumed, Mode: s.mode, FullWidth: s.fullWidth}
}

// Type 追加一个字母。临时英文存在时原样追加，否则进入拼音缓冲。
func (s *Session) Type(ch byte) Result {
	if s.inline != "" {
		s.inline += string(ch)
		return s.result("", true)
	}
	if s.mode != Chinese || s.eng == nil {
		return s.result("", false)
	}
	if ch >= 'A' && ch <= 'Z' {
		ch += 'a' - 'A'
	}
	if !s.eng.Type(ch) {
		return s.result("", false)
	}
	return s.result("", true)
}

// ShiftLetter 处理中文态按住 Shift 打大写字母：没有缓冲时直接上屏，
// 正在打拼音时把已打编码接进临时英文串，再从这字母继续。
func (s *Session) ShiftLetter(ch byte) Result {
	if ch >= 'a' && ch <= 'z' {
		ch -= 'a' - 'A'
	}
	if s.inline != "" {
		s.inline += string(ch)
		return s.result("", true)
	}
	if s.mode != Chinese {
		return s.Direct(string(ch))
	}
	if s.Buffer() != "" {
		s.inline = s.Buffer() + string(ch)
		s.inlineSp = s.classBefore("") == classCJK
		s.eng.Reset()
		return s.result("", true)
	}
	text := string(ch)
	if s.classBefore("") == classCJK {
		text = " " + text
	}
	return s.result(text, true)
}

// Direct 直接插入一段固定文本（iOS 的英文字母、数字键、符号页）。组合中的
// 候选先上屏。补空格和 macOS 透传按键（Passthrough）一致：字母或数字
// 紧跟中文时前面补空格，中文紧跟字母或数字时也补。
func (s *Session) Direct(text string) Result {
	out := s.commitPending()
	if text != "" && isASCIIAlnum(text[0]) && s.classBefore(out) == classCJK {
		out += " "
	}
	return s.result(s.commitText(out, text), true)
}

// Space 处理空格：临时英文结束并补空格；有候选选首选；否则原样上屏。
// 没有任何组合时返回 Consumed=false，让平台自己插入空格。
func (s *Session) Space() Result {
	if s.inline != "" {
		return s.result(s.commitInline("", true), true)
	}
	if s.mode == Chinese && s.Buffer() != "" {
		return s.result(s.commitPending(), true)
	}
	return s.result("", false)
}

// Return 处理回车：临时英文不补空格结束；有缓冲时把编码原样上屏。
// 没有组合时返回 Consumed=false，让平台按自己的语义换行。
func (s *Session) Return() Result {
	if s.inline != "" {
		// 回车结束不补空格，后面紧接中文也不自动加。
		return s.result(s.commitInline("", false), true)
	}
	if s.mode == Chinese && s.Buffer() != "" {
		return s.result(s.commitRaw(""), true)
	}
	return s.result("", false)
}

// Backspace 删除临时英文或拼音缓冲的一格；没有组合时交给平台删正文。
func (s *Session) Backspace() Result {
	if s.inline != "" {
		s.inline = s.inline[:len(s.inline)-1]
		if s.inline == "" {
			s.inlineSp = false
		}
		return s.result("", true)
	}
	if s.mode == Chinese && s.Buffer() != "" {
		s.eng.Backspace()
		return s.result("", true)
	}
	return s.result("", false)
}

// Escape 取消临时英文或当前拼音组合。
func (s *Session) Escape() Result {
	if s.inline != "" {
		s.inline = ""
		s.inlineSp = false
		return s.result("", true)
	}
	if s.Buffer() != "" {
		s.eng.Reset()
		return s.result("", true)
	}
	return s.result("", false)
}

// Page 翻页。候选为空时返回 Consumed=false；到边界仍算消费，避免 = / - 上屏。
func (s *Session) Page(delta int) Result {
	if s.inline != "" {
		return s.result(s.commitInline("", false), false)
	}
	if s.eng == nil || len(s.eng.Candidates()) == 0 {
		return s.result("", false)
	}
	s.eng.Page(delta)
	return s.result("", true)
}

// Select 选中第 i 个候选并上屏。
func (s *Session) Select(i int) Result {
	if s.eng == nil {
		return s.result("", false)
	}
	return s.selected(s.eng.Select(i))
}

// SelectChar 取第 i 个候选的首字或尾字。
func (s *Session) SelectChar(i int, last bool) Result {
	if s.eng == nil {
		return s.result("", false)
	}
	return s.selected(s.eng.SelectChar(i, last))
}

// SelectGlobal 选出全部候选里的第 i 个并上屏，索引可以落在后续页。
func (s *Session) SelectGlobal(i int) Result {
	if s.eng == nil {
		return s.result("", false)
	}
	return s.selected(s.eng.SelectGlobal(i))
}

// selected 把引擎选出的文字按补空格规则上屏。
func (s *Session) selected(text string, ok bool) Result {
	if !ok {
		return s.result("", false)
	}
	return s.result(s.commitText("", text), true)
}

// Punctuate 把 ASCII 标点转成中文标点。组合中的候选先上屏；
// 全半角关闭或表里没有这个字符时返回 Consumed=false。
func (s *Session) Punctuate(ch byte) Result {
	if s.mode != Chinese || !s.fullWidth {
		return s.result("", false)
	}
	if _, ok := punctTable[ch]; !ok {
		return s.result("", false)
	}
	out := s.commitPending()
	punct := s.punctuate(ch)
	if alt, ok := numberPunct(s.digitBefore(out), ch); ok {
		punct = alt
	}
	return s.result(out+punct, true)
}

// Passthrough 处理交给应用的按键：先把组合上屏，再按光标前的字符决定
// 要不要补空格。Text 是需要在应用处理按键前插入的文本。
func (s *Session) Passthrough(ch byte) Result {
	var out string
	if ch >= 0x20 {
		out = s.commitPending()
	} else {
		out = s.commitInline("", false)
	}
	if isASCIIAlnum(ch) && s.classBefore(out) == classCJK {
		out += " "
	}
	return s.result(out, false)
}

// ToggleMode 切换中英模式。切到英文时把没上屏的拼音原样打出去。
func (s *Session) ToggleMode() Result {
	out := s.commitInline("", false)
	if s.mode == Chinese {
		out = s.commitRaw(out)
		s.mode = English
	} else {
		s.mode = Chinese
	}
	return s.result(out, true)
}

// ToggleFullWidth 切换标点全角/半角。
func (s *Session) ToggleFullWidth() Result {
	s.fullWidth = !s.fullWidth
	return s.result("", true)
}

// CommitInline 结束临时英文。trailingSpace 为 true 时补一个空格。
func (s *Session) CommitInline(trailingSpace bool) Result {
	if s.inline == "" {
		return s.result("", false)
	}
	return s.result(s.commitInline("", trailingSpace), true)
}

// Finish 把未完成的输入上屏并清干净，用于停用输入法或应用主动结束输入。
func (s *Session) Finish() Result {
	out := s.commitPending()
	s.Reset()
	return s.result(out, out != "")
}

// Reset 清空当前组合，不删除已经上屏的文本，也不改变中英模式和全半角。
func (s *Session) Reset() {
	if s.eng != nil {
		s.eng.Reset()
	}
	s.inline = ""
	s.inlineSp = false
}

// 下面的上屏辅助函数都接收 pending：本次动作已经拼好、还没写进宿主的
// 文本，返回追加之后的结果。补空格和数字后半角句号要看「光标前一个字符」，
// pending 非空时那个字符是 pending 的末尾，而不是宿主正文里的旧内容。

// commitPending 结束临时英文，再把拼音缓冲的首选上屏；没有候选时把编码
// 原样上屏，免得缓冲留在引擎里、预编辑却被后续插入的文本顶掉。
func (s *Session) commitPending() string {
	out := s.commitInline("", false)
	if s.Buffer() == "" {
		return out
	}
	if cand, ok := s.eng.Select(0); ok {
		return s.commitText(out, cand)
	}
	return s.commitRaw(out)
}

// commitText 上屏一段文字，并在中文紧跟英文/数字时补一个空格。
func (s *Session) commitText(pending, text string) string {
	if text == "" {
		return pending
	}
	if classOf(text) == classCJK && s.classBefore(pending) == classASCII {
		return pending + " " + text
	}
	return pending + text
}

// commitRaw 把拼音缓冲原样上屏，不做任何转换。
func (s *Session) commitRaw(pending string) string {
	buf := s.Buffer()
	if buf == "" {
		return pending
	}
	s.eng.Reset()
	if s.classBefore(pending) == classCJK {
		return pending + " " + buf
	}
	return pending + buf
}

// commitInline 把临时英文串上屏。空格结束补一个空格；回车结束不补，
// 方便后面直接紧跟中文（例如 iOS版、iPhone手机）。
func (s *Session) commitInline(pending string, trailingSpace bool) string {
	if s.inline == "" {
		return pending
	}
	text := s.inline
	if s.inlineSp {
		text = " " + text
	}
	if trailingSpace {
		text += " "
	}
	s.inline = ""
	s.inlineSp = false
	return pending + text
}

// charBefore 返回光标前一个字符：pending 非空时取它的末字，否则问宿主正文。
// 问不到时按「前面没有字符」处理。
func (s *Session) charBefore(pending string) (rune, bool) {
	if pending != "" {
		r, _ := utf8.DecodeLastRuneInString(pending)
		return r, true
	}
	if s.lookbehind == nil {
		return 0, false
	}
	return s.lookbehind()
}

// classBefore 返回光标前一个字符的类别，用于判断要不要补空格。
func (s *Session) classBefore(pending string) class {
	r, ok := s.charBefore(pending)
	if !ok {
		return classNone
	}
	return classOfRune(r)
}

// digitBefore 判断光标前一个字符是不是 ASCII 数字，用于数字后的半角句号。
func (s *Session) digitBefore(pending string) bool {
	r, ok := s.charBefore(pending)
	return ok && r < 0x80 && isASCIIDigit(byte(r))
}

func (s *Session) punctuate(ch byte) string {
	alts := punctTable[ch]
	if len(alts) == 1 {
		return alts[0]
	}
	i := 0
	if s.punctAlt[ch] {
		i = 1
	}
	s.punctAlt[ch] = !s.punctAlt[ch]
	return alts[i]
}

func isASCIIDigit(ch byte) bool {
	return ch >= '0' && ch <= '9'
}

func isASCIIAlnum(ch byte) bool {
	return isASCIIDigit(ch) || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z'
}

func startsWithHan(s string) bool {
	for _, r := range s {
		return unicode.Is(unicode.Han, r)
	}
	return false
}

// classOfRune 判断一个字符属于哪一类。
func classOfRune(r rune) class {
	switch {
	case unicode.Is(unicode.Han, r):
		return classCJK
	case r < 0x80 && isASCIIAlnum(byte(r)):
		return classASCII
	}
	return classNone
}

// classOf 判断一段要上屏的文字属于哪一类，用于决定要不要在前面补空格。
func classOf(s string) class {
	switch {
	case startsWithHan(s):
		return classCJK
	case s != "" && isASCIIAlnum(s[0]):
		return classASCII
	}
	return classNone
}
