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
	s := New(nil)
	s.prevDigit = true
	if r := s.Punctuate('.'); r.Text != "." {
		t.Fatalf("数字后的句号 = %q", r.Text)
	}
	s = New(nil)
	if r := s.Punctuate('.'); r.Text != "。" {
		t.Fatalf("非数字后的句号 = %q", r.Text)
	}
	s = New(nil)
	s.prevDigit = true
	if r := s.Punctuate(','); r.Text != "，" {
		t.Fatalf("逗号不受数字影响 = %q", r.Text)
	}
	s = New(nil)
	s.Direct("3")
	if r := s.Punctuate('.'); r.Text != "." {
		t.Fatalf("直通数字后的句号 = %q", r.Text)
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
	s := New(nil)
	s.prevClass = classCJK
	if r := s.Passthrough('a'); r.Text != " " || s.prevClass != classASCII {
		t.Fatalf("中文后接英文 = %q, class=%v", r.Text, s.prevClass)
	}
	s.prevClass = classCJK
	if r := s.Passthrough('.'); r.Text != "" || s.prevClass != classNone {
		t.Fatalf("中文后接标点 = %q, class=%v", r.Text, s.prevClass)
	}
	if classOf("我") != classCJK || classOf("abc") != classASCII ||
		classOf("API") != classASCII || classOf("，") != classNone || classOf("") != classNone {
		t.Fatal("classOf 分类不对")
	}
	// 透传的数字和字母要记成 ASCII，后面的中文才会自动补空格；
	// 透传的标点不补。
	s.prevClass = classNone
	s.Passthrough('3')
	if s.prevClass != classASCII || !s.prevDigit {
		t.Fatal("透传数字后应记成 ASCII 数字")
	}
}

func TestSelectAndSpace(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	if r := s.Space(); r.Text != "你" || !r.Consumed {
		t.Fatalf("空格选首选 = %q, %v", r.Text, r.Consumed)
	}
	if s.Buffer() != "" {
		t.Fatalf("选词后缓冲 = %q", s.Buffer())
	}
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
	if s.prevClass != classNone {
		t.Fatalf("回车后类别 = %v", s.prevClass)
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
	s := New(engine.New(nil))
	s.prevClass = classCJK
	if r := s.ShiftLetter('A'); r.Text != " A" {
		t.Fatalf("中文后直接打大写 = %q", r.Text)
	}
	if s.prevClass != classASCII {
		t.Fatalf("大写后类别 = %v", s.prevClass)
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

// 退格删掉刚上屏的英文后，再打英文仍要按前一个字符补空格。
func TestSpacingAfterDelete(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	if r := s.Space(); r.Text != "你" {
		t.Fatalf("首选 = %q", r.Text)
	}
	s.Type('a')
	s.Type('b')
	s.Type('c')
	if r := s.Space(); r.Text != " abc" {
		t.Fatalf("英文上屏 = %q", r.Text)
	}
	// 四格退格删掉 " abc"，前一个字符回到「你」。
	for i := 0; i < 4; i++ {
		if r := s.Backspace(); r.Consumed {
			t.Fatalf("第 %d 格退格不该被消费", i)
		}
	}
	s.Type('a')
	s.Type('b')
	s.Type('c')
	if r := s.Space(); r.Text != " abc" {
		t.Fatalf("删掉英文后重打 = %q", r.Text)
	}
	// 只删三个字母时原来的空格还在，不能再补一个。
	for i := 0; i < 3; i++ {
		s.Backspace()
	}
	s.Type('a')
	s.Type('b')
	s.Type('c')
	if r := s.Space(); r.Text != "abc" {
		t.Fatalf("删掉字母后重打 = %q", r.Text)
	}
}

// 删掉平台插入的空格、删掉中文标点后，都算回到中文，后面接英文要补空格。
func TestBackspaceRestoresCJK(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	s.Space()
	if r := s.Space(); r.Consumed {
		t.Fatal("没有组合时空格应交给平台")
	}
	s.Backspace()
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("删掉空格后打英文 = %q", r.Text)
	}

	s = New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	s.Space()
	if r := s.Punctuate(','); r.Text != "，" {
		t.Fatalf("逗号 = %q", r.Text)
	}
	s.Backspace()
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("删掉逗号后打英文 = %q", r.Text)
	}
}

// 退格回到数字时，句号仍按小数处理。
func TestBackspaceRestoresDigit(t *testing.T) {
	s := New(engine.New(nil))
	s.Direct("12")
	s.Backspace()
	if r := s.Punctuate('.'); r.Text != "." {
		t.Fatalf("数字后退格再打句号 = %q", r.Text)
	}

	s = New(engine.New(nil))
	s.Direct("a1")
	s.Backspace()
	if r := s.Punctuate('.'); r.Text != "。" {
		t.Fatalf("字母后退格再打句号 = %q", r.Text)
	}
}

// 英文直通模式下的退格同样要回退记录。
func TestEnglishBackspace(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	s.Space()
	s.ToggleMode()
	for _, ch := range []byte{'a', 'b', 'c'} {
		s.Passthrough(ch)
	}
	for i := 0; i < 4; i++ {
		if r := s.Backspace(); r.Consumed {
			t.Fatalf("第 %d 格退格不该被消费", i)
		}
	}
	if r := s.Passthrough('a'); r.Text != " " {
		t.Fatalf("英文模式删掉英文后重打 = %q", r.Text)
	}
}

// 光标可能挪走的地方要作废记录，不能再按旧字符补空格。
func TestUntrack(t *testing.T) {
	s := New(engine.New(testDict(t)))
	s.Type('n')
	s.Type('i')
	s.Space()
	s.Untrack()
	if r := s.Passthrough('a'); r.Text != "" {
		t.Fatalf("作废记录后打英文 = %q", r.Text)
	}
}
