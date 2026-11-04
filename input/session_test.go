package input

import (
	"bytes"
	"testing"

	"wenshan/engine"
)

func testDict(t *testing.T) *engine.Dict {
	t.Helper()
	var buf bytes.Buffer
	if err := engine.WriteDict(&buf, []engine.Entry{
		{Code: "ni", Text: "你", Weight: 2500},
		{Code: "nihk", Text: "你好", Weight: 2400},
	}); err != nil {
		t.Fatal(err)
	}
	d, err := engine.OpenDict(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// doc 模拟宿主正文：规则层通过 lookbehind 读它最后一格，测试里自己维护。
type doc []rune

func (d *doc) before() (rune, bool) {
	if len(*d) == 0 {
		return 0, false
	}
	return (*d)[len(*d)-1], true
}

func (d *doc) insert(text string) { *d = append(*d, []rune(text)...) }

func (d *doc) delete(n int) { *d = (*d)[:len(*d)-n] }

// withDoc 建一个「光标停在 text 末尾」的会话，返回的 doc 由测试自己维护。
func withDoc(t *testing.T, text string) (*Session, *doc) {
	t.Helper()
	d := new(doc)
	d.insert(text)
	s := New(engine.New(testDict(t)))
	s.SetLookbehind(d.before)
	return s, d
}

func TestPunctuate(t *testing.T) {
	s := New(nil)
	if r := s.Punctuate(','); !r.Consumed || r.Text != "，" {
		t.Fatalf("逗号 = %q, %v", r.Text, r.Consumed)
	}
	if r := s.Punctuate('"'); r.Text != "“" {
		t.Fatalf("第一个引号 = %q", r.Text)
	}
	if r := s.Punctuate('"'); r.Text != "”" {
		t.Fatalf("第二个引号 = %q", r.Text)
	}
	if r := s.Punctuate('-'); r.Consumed {
		t.Fatal("减号不该被替换")
	}
	// 顿号在社区配置里通常同时接受 / 和 \，只留 \ 不容易发现。
	for _, ch := range []byte{'/', '\\'} {
		s := New(nil)
		if r := s.Punctuate(ch); !r.Consumed || r.Text != "、" {
			t.Errorf("顿号键 %q = %q, %v", ch, r.Text, r.Consumed)
		}
	}
}

func TestNumberPunct(t *testing.T) {
	s, _ := withDoc(t, "1")
	if r := s.Punctuate('.'); r.Text != "." {
		t.Fatalf("数字后的句号 = %q", r.Text)
	}
	s, _ = withDoc(t, "我")
	if r := s.Punctuate('.'); r.Text != "。" {
		t.Fatalf("非数字后的句号 = %q", r.Text)
	}
	s, _ = withDoc(t, "1")
	if r := s.Punctuate(','); r.Text != "，" {
		t.Fatalf("逗号不受数字影响 = %q", r.Text)
	}
}

func TestFullWidthOff(t *testing.T) {
	s := New(nil)
	s.ToggleFullWidth()
	if r := s.Punctuate(','); r.Consumed {
		t.Fatal("半角时标点不该被输入法消费")
	}
}

func TestSpacing(t *testing.T) {
	s, _ := withDoc(t, "我")
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("中文后接英文 = %q", r.Text)
	}
	s, _ = withDoc(t, "我")
	if r := s.Passthrough('.'); r.Text != "" {
		t.Fatalf("中文后接标点 = %q", r.Text)
	}
	if classOf("我") != classCJK || classOf("abc") != classASCII ||
		classOf("API") != classASCII || classOf("，") != classNone || classOf("") != classNone {
		t.Fatal("classOf 分类不对")
	}
	// 问不到正文时不补空格，也不该崩。
	if r := New(nil).Passthrough('a'); r.Text != "" {
		t.Fatalf("没有 lookbehind 时补了空格 = %q", r.Text)
	}
}

func TestSelectAndSpace(t *testing.T) {
	s, d := withDoc(t, "")
	s.Type('n')
	s.Type('i')
	r := s.Space()
	if r.Text != "你" || !r.Consumed {
		t.Fatalf("空格选首选 = %q, %v", r.Text, r.Consumed)
	}
	if s.Buffer() != "" {
		t.Fatalf("选词后缓冲 = %q", s.Buffer())
	}
	d.insert(r.Text)
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("中文后接英文补空格 = %q", r.Text)
	}
}

func TestPunctuateCommitsPending(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	if r := s.Punctuate(','); r.Text != "你，" {
		t.Fatalf("标点前先上屏 = %q", r.Text)
	}
}

func TestDirectCommitsPending(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	if r := s.Direct("。"); r.Text != "你。" {
		t.Fatalf("固定文本前先上屏 = %q", r.Text)
	}
}

func TestTempEnglish(t *testing.T) {
	s := New(engine.New(nil))
	s.Type('n')
	s.Type('i')
	if r := s.ShiftLetter('A'); r.Text != "" || s.Preedit() != "niA" {
		t.Fatalf("进入临时英文 = %q, preedit=%q", r.Text, s.Preedit())
	}
	s.Type('B')
	if s.Preedit() != "niAB" {
		t.Fatalf("临时英文追加 = %q", s.Preedit())
	}
	if r := s.Space(); r.Text != "niAB " {
		t.Fatalf("空格结束临时英文 = %q", r.Text)
	}
	if s.Preedit() != "" {
		t.Fatalf("结束后预编辑 = %q", s.Preedit())
	}
}

func TestReturnInline(t *testing.T) {
	s := New(engine.New(nil))
	s.Type('n')
	s.Type('i')
	s.ShiftLetter('A')
	if r := s.Return(); r.Text != "niA" || !r.Consumed {
		t.Fatalf("回车结束临时英文 = %q, %v", r.Text, r.Consumed)
	}
}

func TestPageCommitsInline(t *testing.T) {
	s := New(engine.New(nil))
	s.Type('n')
	s.Type('i')
	s.ShiftLetter('A')
	if r := s.Page(1); r.Text != "niA" || r.Consumed {
		t.Fatalf("翻页先结束临时英文 = %q, %v", r.Text, r.Consumed)
	}
}

func TestPassthroughCommitsPending(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	if r := s.Passthrough('+'); r.Text != "你" || r.Consumed {
		t.Fatalf("透传前先上屏 = %q, %v", r.Text, r.Consumed)
	}
	if s.Buffer() != "" {
		t.Fatalf("上屏后缓冲 = %q", s.Buffer())
	}
}

func TestShiftLetterNoBuffer(t *testing.T) {
	s, _ := withDoc(t, "我")
	if r := s.ShiftLetter('A'); r.Text != " A" {
		t.Fatalf("中文后直接打大写 = %q", r.Text)
	}
}

func TestBackspaceInline(t *testing.T) {
	s := New(engine.New(nil))
	s.Type('n')
	s.Type('i')
	s.ShiftLetter('A')
	if r := s.Backspace(); !r.Consumed || s.Preedit() != "ni" {
		t.Fatalf("退格临时英文 = %q, %v", s.Preedit(), r.Consumed)
	}
	s.Backspace()
	s.Backspace()
	if s.Preedit() != "" {
		t.Fatalf("退空后预编辑 = %q", s.Preedit())
	}
	if r := s.Backspace(); r.Consumed {
		t.Fatal("没有组合时退格应交给平台")
	}
}

func TestReturnAndToggleMode(t *testing.T) {
	s := New(engine.New(nil))
	s.Type('a')
	s.Type('b')
	if r := s.Return(); r.Text != "ab" {
		t.Fatalf("回车原样上屏 = %q", r.Text)
	}

	s = New(engine.New(nil))
	s.Type('a')
	s.Type('b')
	if r := s.ToggleMode(); r.Text != "ab" || s.Mode() != English {
		t.Fatalf("切英文时原样上屏 = %q, mode=%v", r.Text, s.Mode())
	}
	if r := s.Space(); r.Consumed {
		t.Fatal("英文模式空格应交给平台")
	}
}

func TestFinish(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	if r := s.Finish(); r.Text != "你" {
		t.Fatalf("结束输入 = %q", r.Text)
	}
	if s.Preedit() != "" || len(s.Candidates()) != 0 {
		t.Fatal("结束输入后状态没清干净")
	}
}

// 删掉刚上屏的英文（连前面的空格）后重打，正文前一个字符回到中文，仍要补空格。
func TestSpacingAfterDelete(t *testing.T) {
	s, d := withDoc(t, "你")
	d.insert(" abc")
	d.delete(4)
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("删掉英文后重打 = %q", r.Text)
	}
	// 只删字母时前面的空格还在，不能再补一个。
	d.insert(" abc")
	d.delete(3)
	if r := s.Passthrough('a'); r.Text != "" {
		t.Fatalf("删掉字母后重打 = %q", r.Text)
	}
}

// 删掉平台插入的空格后，前面是中文，打英文要补空格。
func TestSpaceThenEnglish(t *testing.T) {
	s, d := withDoc(t, "")
	s.Type('n')
	s.Type('i')
	d.insert(s.Space().Text)
	s.Space()
	d.insert(" ")
	d.delete(1)
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("删掉空格后打英文 = %q", r.Text)
	}
}

// 英文后接中文，中文前面要补空格。
func TestChineseAfterEnglish(t *testing.T) {
	s, _ := withDoc(t, "abc")
	s.Type('n')
	s.Type('i')
	if r := s.Space(); r.Text != " 你" {
		t.Fatalf("英文后接中文 = %q", r.Text)
	}
}

// 英文直通模式同样按正文补空格。
func TestEnglishModeSpacing(t *testing.T) {
	s, _ := withDoc(t, "你")
	s.ToggleMode()
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("英文模式中文后接英文 = %q", r.Text)
	}
}

// 光标前是数字时句号保持半角，退格之后也一样。
func TestDigitAfterDelete(t *testing.T) {
	s, d := withDoc(t, "12")
	d.delete(1)
	if r := s.Punctuate('.'); r.Text != "." {
		t.Fatalf("数字后退格再打句号 = %q", r.Text)
	}
	s, d = withDoc(t, "a1")
	d.delete(1)
	if r := s.Punctuate('.'); r.Text != "。" {
		t.Fatalf("字母后退格再打句号 = %q", r.Text)
	}
}

// 查不到正文时按「前面没有字符」处理，不补空格。
func TestLookbehindFails(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.SetLookbehind(func() (rune, bool) { return 0, false })
	if r := s.Passthrough('a'); r.Text != "" {
		t.Fatalf("查不到正文时补了空格 = %q", r.Text)
	}
}

// 同一次按键里先上屏的候选也算「光标前的字符」：数字后打了中文再按句号，
// 句号要跟着中文变全角；中文候选后透传的数字也要补空格。
func TestPendingTextIsLookbehind(t *testing.T) {
	type1 := func(s *Session, keys string) {
		for i := 0; i < len(keys); i++ {
			s.Type(keys[i])
		}
	}
	s, _ := withDoc(t, "3")
	type1(s, "nihk")
	if r := s.Punctuate('.'); r.Text != " 你好。" {
		t.Fatalf("3 + nihk + 句号 = %q", r.Text)
	}
	s, _ = withDoc(t, "abc")
	type1(s, "nihk")
	if r := s.Passthrough('0'); r.Text != " 你好 " {
		t.Fatalf("abc + nihk + 0 = %q", r.Text)
	}
}

// 缓冲查不到候选时，标点和停用输入法都把编码原样上屏，不留在引擎里。
func TestPendingRawWithoutCandidates(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('q')
	s.Type('q')
	s.Type('q')
	if r := s.Punctuate(','); r.Text != "qqq，" || s.Buffer() != "" {
		t.Fatalf("无候选时标点 = %q, 缓冲 %q", r.Text, s.Buffer())
	}
	s.Type('q')
	s.Type('q')
	s.Type('q')
	if r := s.Finish(); r.Text != "qqq" {
		t.Fatalf("无候选时结束输入 = %q", r.Text)
	}
}
