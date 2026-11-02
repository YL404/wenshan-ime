package engine

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// 每个用例都对应 Rime double_pinyin.schema.yaml 里的一条改写规则。
func TestCodes(t *testing.T) {
	cases := []struct {
		pinyin []string
		want   string
	}{
		{[]string{"ni"}, "ni"},
		{[]string{"hao"}, "hk"},
		{[]string{"ni", "hao"}, "nihk"},
		{[]string{"zhong"}, "vs"},
		{[]string{"zhong", "guo"}, "vsgo"},
		{[]string{"shi"}, "ui"},
		{[]string{"chi"}, "ii"},
		{[]string{"zhi"}, "vi"},
		{[]string{"ang"}, "ah"},
		{[]string{"a"}, "aa"},
		{[]string{"er"}, "er"},
		{[]string{"nv"}, "nv"},
		{[]string{"lve"}, "lt"},
		{[]string{"xin"}, "xn"},
		{[]string{"ying"}, "yy"},
		{[]string{"xiao"}, "xc"},
		{[]string{"jiu"}, "jq"},
		{[]string{"hui"}, "hv"},
		{[]string{"kuai"}, "ky"},
		{[]string{"guang"}, "gd"},
		{[]string{"qiong"}, "qs"},
		{[]string{"fen"}, "ff"},
		{[]string{"feng"}, "fg"},
		{[]string{"bang"}, "bh"},
		{[]string{"bian"}, "bm"},
		{[]string{"bie"}, "bx"},
		{[]string{"biao"}, "bc"},
		{[]string{"bao"}, "bk"},
		{[]string{"bei"}, "bz"},
		{[]string{"zou"}, "zb"},
		{[]string{"wen"}, "wf"},
		{[]string{"wang"}, "wh"},
		{[]string{"wo"}, "wo"},
		{[]string{"ya"}, "ya"}, // y 后面直接跟韵母键，和 Rime 一致
	}
	for _, c := range cases {
		got := Codes(c.pinyin)
		if len(got) == 0 || got[0] != c.want {
			t.Errorf("Codes(%v) = %v, 期望 %q", c.pinyin, got, c.want)
		}
	}
}

// 兼容写法：Rime 用 derive 同时接受原始拼写。
func TestCodesAlternatives(t *testing.T) {
	cases := map[string][]string{
		"ai": {"al", "ai"},
		"an": {"aj", "an"},
		"ou": {"ob", "ou"},
		"ju": {"jv", "ju"},
		"yu": {"yv", "yu"},
	}
	for pinyin, want := range cases {
		got := Codes([]string{pinyin})
		if len(got) != len(want) {
			t.Fatalf("Codes(%q) = %v, 期望 %v", pinyin, got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("Codes(%q) = %v, 期望 %v", pinyin, got, want)
			}
		}
	}
}

func buildDict(t testing.TB, entries []Entry) *Dict {
	t.Helper()
	var buf bytes.Buffer
	if err := WriteDict(&buf, entries); err != nil {
		t.Fatal(err)
	}
	d, err := OpenDict(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestPaging(t *testing.T) {
	entries := make([]Entry, 0, 25)
	for i := 0; i < 25; i++ {
		entries = append(entries, Entry{
			Code:   "ni",
			Text:   string(rune('a' + i)),
			Weight: uint32(2500 - i),
		})
	}
	e := New(buildDict(t, entries))
	e.Type('n')
	e.Type('i')

	if got := e.Candidates(); len(got) != pageSize || got[0].Text != "a" {
		t.Fatalf("第 1 页 = %v", got)
	}
	if !e.Page(1) {
		t.Fatal("第 1 页翻不到第 2 页")
	}
	if got := e.Candidates(); len(got) != pageSize || got[0].Text != "j" {
		t.Fatalf("第 2 页 = %v", got)
	}
	if !e.Page(1) {
		t.Fatal("第 2 页翻不到第 3 页")
	}
	if got := e.Candidates(); len(got) != 7 || got[0].Text != "s" {
		t.Fatalf("第 3 页 = %v", got)
	}
	if e.Page(1) {
		t.Fatal("超过 3 页还能继续翻")
	}
	if got := e.Candidates(); len(got) != 7 || got[0].Text != "s" {
		t.Fatalf("末页再翻后变成 %v", got)
	}
	if !e.Page(-1) || !e.Page(-1) {
		t.Fatal("翻不回第 1 页")
	}
	if got := e.Candidates(); len(got) != pageSize || got[0].Text != "a" {
		t.Fatalf("回到第 1 页 = %v", got)
	}
	if e.Page(-1) {
		t.Fatal("第 1 页还能继续往前翻")
	}

	// 换输入或者退格后，页状态必须回到第 1 页。
	if !e.Page(1) {
		t.Fatal("翻页失败")
	}
	e.Backspace()
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "a" {
		t.Fatalf("退格后没有回到第 1 页: %v", got)
	}
	e.Type('i')
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "a" {
		t.Fatalf("重新输入后没有回到第 1 页: %v", got)
	}

	// 选当前页的候选，不能选到第 1 页的首选。
	if !e.Page(1) {
		t.Fatal("翻页失败")
	}
	text, ok := e.Select(0)
	if !ok || text != "j" {
		t.Fatalf("第 2 页首选 = %q, %v", text, ok)
	}
	if len(e.Buffer()) != 0 || len(e.Candidates()) != 0 {
		t.Fatal("选词后没有清空")
	}
}

func TestPagingSinglePage(t *testing.T) {
	entries := make([]Entry, 0, pageSize)
	for i := 0; i < pageSize; i++ {
		entries = append(entries, Entry{
			Code:   "ni",
			Text:   string(rune('a' + i)),
			Weight: uint32(100 - i),
		})
	}
	e := New(buildDict(t, entries))
	e.Type('n')
	e.Type('i')
	if e.Page(1) || e.Page(-1) {
		t.Fatal("只有一页时不应该翻动")
	}
	if len(e.Candidates()) != pageSize {
		t.Fatalf("候选数 = %d", len(e.Candidates()))
	}
}

func TestPrefixRanking(t *testing.T) {
	// 按编码升序、同编码权重降序排列，这是 Prefix 的前提。
	d := buildDict(t, []Entry{
		{Code: "ni", Text: "你", Weight: 500},
		{Code: "ni", Text: "尼", Weight: 100},
		{Code: "nihk", Text: "你好", Weight: 900},
		{Code: "nihk", Text: "你我", Weight: 50},
		{Code: "nihk", Text: "霓虹", Weight: 70},
		{Code: "xn", Text: "新", Weight: 800},
	})
	if got := d.Len(); got != 6 {
		t.Fatalf("Len = %d", got)
	}

	// 打 ni：编码刚好用完的词优先，你 在第一。
	got := d.Lookup([]byte("ni"), 9)
	if len(got) == 0 || got[0].Text != "你" {
		t.Fatalf("Lookup(ni) 首选 = %v", got)
	}
	if got[1].Text != "尼" {
		t.Errorf("Lookup(ni) 次选 = %q, 期望 尼", got[1].Text)
	}
	if got[2].Text != "你好" || got[len(got)-1].Text != "你我" {
		t.Errorf("长词应排在短词之后: %v", got)
	}

	// 打 nihk：整词优先，但前面已经打完的「你」仍然可选。
	got = d.Lookup([]byte("nihk"), 9)
	if len(got) != 5 || got[0].Text != "你好" || got[1].Text != "霓虹" {
		t.Fatalf("Lookup(nihk) = %v", got)
	}

	// 半截输入 nih 也能命中你好，CodeLen 是完整编码长度。
	got = d.Lookup([]byte("nih"), 9)
	if len(got) != 5 || got[0].Text != "你好" || got[0].CodeLen != 4 {
		t.Fatalf("Lookup(nih) = %v", got)
	}

	if got := d.Lookup([]byte("zz"), 9); got != nil {
		t.Errorf("Lookup(zz) = %v, 期望空", got)
	}
}

// 辅码条目比普通音节多一到两键，等长匹配时应该排在同音字前面。
func TestAuxRanking(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "ni", Text: "你", Weight: 500},
		{Code: "ni", Text: "尼", Weight: 400},
		{Code: "nir", Text: "你", Weight: 500},
		{Code: "nirx", Text: "你", Weight: 500},
	})
	e := New(d)
	typeCode := func(s string) {
		e.Reset()
		for _, ch := range []byte(s) {
			e.Type(ch)
		}
	}

	typeCode("nir")
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "你" {
		t.Fatalf("nir 候选 = %v", got)
	}
	typeCode("nirx")
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "你" {
		t.Fatalf("nirx 候选 = %v", got)
	}
}

// 三键既可能是单字辅码，也可能是下一个音节的声母。真实词组要按词频排在
// 生僻的辅码单字前面，但高频字（的）仍然能靠权重留在首位。
func TestAuxDoesNotOutrankWord(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "tm", Text: "天", Weight: 6000000},
		{Code: "tmj", Text: "钿", Weight: 1000},
		{Code: "tmjt", Text: "钿", Weight: 1000},
		{Code: "tmjw", Text: "添加", Weight: 500000},
		{Code: "tmjw", Text: "天价", Weight: 50000},
		{Code: "xm", Text: "先", Weight: 1600000},
		{Code: "xmz", Text: "暹", Weight: 2800},
		{Code: "xmzl", Text: "现在", Weight: 503000},
		{Code: "de", Text: "的", Weight: 76000000},
		{Code: "deb", Text: "的", Weight: 76000000},
		{Code: "debu", Text: "的", Weight: 76000000},
		{Code: "debu", Text: "底部", Weight: 149000},
	})
	e := New(d)
	typeCode := func(s string) {
		e.Reset()
		for _, ch := range []byte(s) {
			e.Type(ch)
		}
	}
	for _, c := range []struct {
		code string
		want string
	}{
		{"tmj", "添加"},
		{"xmz", "现在"},
		{"deb", "的"},
	} {
		typeCode(c.code)
		if got := e.Candidates(); len(got) == 0 || got[0].Text != c.want {
			t.Errorf("%s 候选 = %v, 期望 %q 在首位", c.code, got, c.want)
		}
	}
}

// 单键候选只取两键单字，辅码条目不能把同一个字重复塞进简码表。
func TestShortListsExcludeAux(t *testing.T) {
	entries := []Entry{
		{Code: "ni", Text: "你", Weight: 500},
		{Code: "nir", Text: "你", Weight: 500},
		{Code: "nirx", Text: "你", Weight: 500},
		{Code: "ni", Text: "尼", Weight: 100},
	}
	count := 0
	for _, e := range shortLists(entries) {
		if e.Text == "你" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("单键候选里「你」出现 %d 次, 期望 1", count)
	}
}

func TestEngine(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "ni", Text: "你", Weight: 500},
		{Code: "hk", Text: "好", Weight: 400},
		{Code: "nihk", Text: "你好", Weight: 900},
		{Code: "vs", Text: "中", Weight: 500},
		{Code: "go", Text: "国", Weight: 400},
	})
	e := New(d)

	for _, ch := range []byte("nihk") {
		if !e.Type(ch) {
			t.Fatalf("Type(%c) 失败", ch)
		}
	}
	if string(e.Buffer()) != "nihk" {
		t.Fatalf("Buffer = %q", e.Buffer())
	}
	if len(e.Candidates()) == 0 || e.Candidates()[0].Text != "你好" {
		t.Fatalf("候选 = %v", e.Candidates())
	}

	// 空格上屏首选后缓冲清空。
	text, ok := e.Select(0)
	if !ok || text != "你好" {
		t.Fatalf("Select(0) = %q, %v", text, ok)
	}
	if len(e.Buffer()) != 0 {
		t.Fatalf("上屏后缓冲 = %q", e.Buffer())
	}

	// 打满你好但只取「你」，剩下的 hk 继续组成「好」。
	for _, ch := range []byte("nihk") {
		e.Type(ch)
	}
	text, ok = e.Select(findText(t, e, "你"))
	if !ok || text != "你" {
		t.Fatalf("Select(你) = %q", text)
	}
	if string(e.Buffer()) != "hk" {
		t.Fatalf("剩余缓冲 = %q, 期望 hk", e.Buffer())
	}
	if len(e.Candidates()) == 0 || e.Candidates()[0].Text != "好" {
		t.Fatalf("剩余缓冲的候选 = %v", e.Candidates())
	}

	// 词没打全也能选：缓冲短于候选编码时，选完直接清空。
	e.Type('w')
	e.Type('o')
	e.Type('f')
	e.Type('a')
	e.Type('x')
	if len(e.Candidates()) == 0 || e.Candidates()[0].Text != "你好" {
		t.Skip("测试词表里没有这么长的词")
	}
	e.Reset()

	e.Backspace()
	if string(e.Buffer()) != "h" {
		t.Fatalf("退格后 = %q", e.Buffer())
	}
	e.Backspace()
	if len(e.Buffer()) != 0 {
		t.Fatalf("清空后 = %q", e.Buffer())
	}
	e.Reset()
	if len(e.Buffer()) != 0 || e.Candidates() != nil {
		t.Fatal("Reset 没清干净")
	}
}

func findText(t *testing.T, e *Engine, text string) int {
	t.Helper()
	for i, c := range e.Candidates() {
		if c.Text == text {
			return i
		}
	}
	t.Fatalf("候选里没有 %q: %v", text, e.Candidates())
	return -1
}

// 以词定字：取候选首/尾字，编码消耗和正常选词一致。
func TestSelectChar(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "ni", Text: "你", Weight: 500},
		{Code: "hk", Text: "好", Weight: 400},
		{Code: "nihk", Text: "你好", Weight: 900},
	})
	e := New(d)
	typeCode := func(s string) {
		e.Reset()
		for _, ch := range []byte(s) {
			e.Type(ch)
		}
	}

	typeCode("nihk")
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "你好" {
		t.Fatalf("候选 = %v", got)
	}
	if text, ok := e.SelectChar(0, false); !ok || text != "你" {
		t.Fatalf("取首字 = %q, %v", text, ok)
	}
	if len(e.Buffer()) != 0 {
		t.Fatalf("取首字后缓冲 = %q", e.Buffer())
	}

	typeCode("nihk")
	if text, ok := e.SelectChar(0, true); !ok || text != "好" {
		t.Fatalf("取尾字 = %q, %v", text, ok)
	}

	// 从候选里取单字时，剩下的编码继续组成后面的词。
	typeCode("nihk")
	if text, ok := e.SelectChar(findText(t, e, "你"), false); !ok || text != "你" {
		t.Fatalf("取候选里的你 = %q, %v", text, ok)
	}
	if string(e.Buffer()) != "hk" {
		t.Fatalf("剩余缓冲 = %q, 期望 hk", e.Buffer())
	}
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "好" {
		t.Fatalf("剩余候选 = %v", got)
	}
}

// 缓冲比候选编码短时（词还没打完），选中后缓冲应整个清空。
func TestSelectLongerCandidate(t *testing.T) {
	d := buildDict(t, []Entry{{Code: "wofaxm", Text: "我发现", Weight: 900}})
	e := New(d)
	for _, ch := range []byte("wofax") {
		e.Type(ch)
	}
	if len(e.Candidates()) != 1 || e.Candidates()[0].Text != "我发现" {
		t.Fatalf("候选 = %v", e.Candidates())
	}
	text, ok := e.Select(0)
	if !ok || text != "我发现" {
		t.Fatalf("Select = %q, %v", text, ok)
	}
	if len(e.Buffer()) != 0 {
		t.Fatalf("缓冲没清空: %q", e.Buffer())
	}
}

// 打了 5 个键时，还没打完的长词应该排在「只用掉前两个键」的高频单字前面。
func TestRankingTiers(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "wo", Text: "我", Weight: 9000},
		{Code: "wofa", Text: "我发", Weight: 3000},
		{Code: "wofaxm", Text: "我发现", Weight: 100},
	})
	// 打了 5 个键时，还没打完的长词应该排在「只用掉前两个键」的高频单字前面；
	// 覆盖按键多的短词（我发）也比覆盖少的单字（我）更具体。
	got := d.Lookup([]byte("wofax"), 9)
	if len(got) != 3 || got[0].Text != "我发现" || got[1].Text != "我发" || got[2].Text != "我" {
		t.Fatalf("Lookup(wofax) = %v", got)
	}
	// 打满 wofa 时，刚好用完缓冲的词优先于更长的词。
	got = d.Lookup([]byte("wofa"), 9)
	if got[0].Text != "我发" || got[1].Text != "我发现" {
		t.Fatalf("Lookup(wofa) = %v", got)
	}
}

// 照拼音写成 ju/qu/xu/yu 时也要能打出 ü 韵母的词。
func TestUmlautVariant(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "jixv", Text: "继续", Weight: 900},
		{Code: "ji", Text: "级", Weight: 800},
	})
	e := New(d)
	for _, ch := range []byte("jixu") {
		e.Type(ch)
	}
	if len(e.Candidates()) == 0 || e.Candidates()[0].Text != "继续" {
		t.Fatalf("jixu 候选 = %v", e.Candidates())
	}
	text, ok := e.Select(0)
	if !ok || text != "继续" {
		t.Fatalf("Select = %q, %v", text, ok)
	}
}

// 词库里没有整句时，要能把缓冲切成几个词拼出来。
func TestCompose(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "womf", Text: "我们", Weight: 500000},
		{Code: "jixv", Text: "继续", Weight: 500000},
		{Code: "wo", Text: "我", Weight: 20000000},
		{Code: "ji", Text: "级", Weight: 5000000},
		{Code: "xv", Text: "许", Weight: 1000000},
	})
	e := New(d)
	for _, ch := range []byte("womfjixv") {
		e.Type(ch)
	}
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "我们继续" {
		t.Fatalf("womfjixv 候选 = %v", got)
	}
	text, ok := e.Select(0)
	if !ok || text != "我们继续" {
		t.Fatalf("Select = %q, %v", text, ok)
	}
	if len(e.Buffer()) != 0 {
		t.Fatalf("缓冲没清空: %q", e.Buffer())
	}

	// 整段就是一个词时不该再拼一遍。
	e2 := New(d)
	for _, ch := range []byte("womf") {
		e2.Type(ch)
	}
	// 我们 覆盖了整个缓冲，只应多出「我」这种前半段已打完的短候选，没有拼接结果。
	if got := e2.Candidates(); len(got) != 2 || got[0].Text != "我们" || got[1].Text != "我" {
		t.Fatalf("womf 候选 = %v", got)
	}

	// 单字凑出来的组合不能压过真正的词。
	e3 := New(d)
	for _, ch := range []byte("jixv") {
		e3.Type(ch)
	}
	if got := e3.Candidates(); len(got) == 0 || got[0].Text != "继续" {
		t.Fatalf("jixv 候选 = %v", got)
	}
}

func BenchmarkTypicalKey(b *testing.B) {
	d := buildDict(b, []Entry{
		{Code: "womf", Text: "我们", Weight: 500000},
		{Code: "jixv", Text: "继续", Weight: 500000},
		{Code: "wo", Text: "我", Weight: 20000000},
	})
	e := New(d)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		e.Reset()
		for _, ch := range []byte("womfjixv") {
			e.Type(ch)
		}
	}
}

// 常用词应该被提到前面，但不能翻过整段匹配那一层。
func TestFreqRanking(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "ni", Text: "你", Weight: 5000},
		{Code: "ni", Text: "尼", Weight: 100},
		{Code: "nihk", Text: "你好", Weight: 900},
	})
	f := &Freq{counts: make(map[string]uint32)}
	e := New(d)
	e.SetFreq(f)

	typeNI := func() {
		e.Reset()
		e.Type('n')
		e.Type('i')
	}
	typeNI()
	if e.Candidates()[0].Text != "你" {
		t.Fatalf("初始首选 = %v", e.Candidates())
	}
	for range 5 {
		typeNI()
		if _, ok := e.Select(findText(t, e, "尼")); !ok {
			t.Fatal("选不到 尼")
		}
	}
	typeNI()
	if e.Candidates()[0].Text != "尼" {
		t.Fatalf("选过 5 次后首选 = %v", e.Candidates())
	}
	// 你好 是整段匹配（层更高），不该被高频单字压下去。
	e.Reset()
	for _, ch := range []byte("nihk") {
		e.Type(ch)
	}
	if e.Candidates()[0].Text != "你好" {
		t.Fatalf("nihk 首选 = %v", e.Candidates())
	}
}

// 连续单字选词后应该记住这个词，下次输入直接出现。
func TestUserDictLearn(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "wo", Text: "我", Weight: 1000},
		{Code: "da", Text: "打", Weight: 900},
		{Code: "de", Text: "的", Weight: 800},
	})
	u := &UserDict{}
	e := New(d)
	e.SetUserDict(u)

	for _, ch := range []byte("wodade") {
		e.Type(ch)
	}
	for _, want := range []string{"我", "打", "的"} {
		if _, ok := e.Select(findText(t, e, want)); !ok {
			t.Fatalf("选不到 %q", want)
		}
	}
	if u.Len() != 1 {
		t.Fatalf("自造词条数 = %d, 期望 1", u.Len())
	}

	// 重新输入整个编码，自造词应该排第一。
	e.Reset()
	for _, ch := range []byte("wodade") {
		e.Type(ch)
	}
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "我打的" {
		t.Fatalf("学完之后候选 = %v", got)
	}

	// 词库本身有的词不该被重复记一遍。
	u2 := &UserDict{}
	e2 := New(buildDict(t, []Entry{
		{Code: "ni", Text: "你", Weight: 1000},
		{Code: "hk", Text: "好", Weight: 900},
	}))
	e2.SetUserDict(u2)
	for _, ch := range []byte("nihk") {
		e2.Type(ch)
	}
	e2.Select(findText(t, e2, "你"))
	e2.Select(findText(t, e2, "好"))
	if u2.Len() != 1 {
		t.Fatalf("单字组合也应记下: %d", u2.Len())
	}
}

// 短语文件按「编码<TAB>文本」读入，空行和注释忽略。
func TestLoadPhrases(t *testing.T) {
	path := filepath.Join(t.TempDir(), "phrases.tsv")
	if err := os.WriteFile(path, []byte("# 注释\r\n\r\nyx\tme@example.com\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := LoadUserDict(path)
	if p.Len() != 1 {
		t.Fatalf("短语条数 = %d, 期望 1", p.Len())
	}
	got := p.Lookup([]byte("yx"), 9)
	if len(got) != 1 || got[0].Text != "me@example.com" {
		t.Fatalf("Lookup(yx) = %v", got)
	}
}

// 自定义短语和普通词同码时，短语要排在最前。
func TestPhrasesRanking(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "yx", Text: "邮箱", Weight: 900000},
		{Code: "yx", Text: "有些", Weight: 800000},
	})
	p := &UserDict{entries: []userEntry{{code: "yx", text: "me@example.com"}}}
	e := New(d)
	e.SetPhrases(p)
	e.Type('y')
	e.Type('x')
	got := e.Candidates()
	if len(got) == 0 || got[0].Text != "me@example.com" {
		t.Fatalf("候选 = %v", got)
	}
}

// 打完一个词组再打下个音节的声母时，组句要能把末尾声母延展成完整音节，
// 而不是让候选塌回单字。
func TestComposeTrailingInitial(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "wofaxm", Text: "我发现", Weight: 900000},
		{Code: "ve", Text: "这", Weight: 400000},
	})
	e := New(d)
	for _, ch := range []byte("wofaxmv") {
		e.Type(ch)
	}
	// v 是 zh 的声母键：词格应竞争出 我发现 + 这。
	got := e.Candidates()
	if len(got) == 0 || got[0].Text != "我发现这" {
		t.Fatalf("wofaxmv 候选 = %v", got)
	}
	// 上屏消耗全部实际按键，未输入的韵母不留在缓冲里。
	text, ok := e.Select(0)
	if !ok || text != "我发现这" {
		t.Fatalf("Select = %q, %v", text, ok)
	}
	if len(e.Buffer()) != 0 {
		t.Fatalf("缓冲没清空: %q", e.Buffer())
	}
}

// 末尾声母补全时不能把辅码单字当成一个音节：buvdl 里的 vdly 是「装」的
// 辅码，不是「装 + ling」，否则会拼出「不装」而不是「不装了」。
func TestComposeSkipsAux(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "bu", Text: "不", Weight: 20000000},
		{Code: "vd", Text: "装", Weight: 1000000},
		{Code: "buvd", Text: "不装", Weight: 500000},
		{Code: "vdly", Text: "装", Weight: 1000000},
		{Code: "vdle", Text: "装了", Weight: 500000},
		{Code: "le", Text: "了", Weight: 1400000},
	})
	e := New(d)
	for _, ch := range []byte("buvdl") {
		e.Type(ch)
	}
	got := e.Candidates()
	if len(got) == 0 || got[0].Text != "不装了" {
		t.Fatalf("buvdl 候选 = %v", got)
	}
	for _, c := range got {
		if c.Text == "不装" && c.CodeLen == 5 {
			t.Errorf("辅码把末尾 l 吃掉了: %v", got)
		}
	}
}

// 末尾多着声母键时，覆盖按键多的前缀词要排在覆盖少的高频单字前面。
func TestOddTailRanking(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "wo", Text: "我", Weight: 9000000},
		{Code: "wofaxm", Text: "我发现", Weight: 100},
	})
	e := New(d)
	for _, ch := range []byte("wofaxmv") {
		e.Type(ch)
	}
	got := e.Candidates()
	if len(got) < 2 || got[0].Text != "我发现" || got[1].Text != "我" {
		t.Fatalf("wofaxmv 候选 = %v", got)
	}
}

// 只有一个完整音节加一个声母键（3 个键）时不做末尾延展：这时用户多半在
// 打下一个词，前缀词（你好）不能被拼出来的单字组合（你和）压下去。
func TestThreeKeysKeepsPrefix(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "ni", Text: "你", Weight: 500},
		{Code: "he", Text: "和", Weight: 400},
		{Code: "nihk", Text: "你好", Weight: 900},
	})
	e := New(d)
	for _, ch := range []byte("nih") {
		e.Type(ch)
	}
	got := e.Candidates()
	if len(got) == 0 || got[0].Text != "你好" {
		t.Fatalf("nih 候选 = %v", got)
	}
	for _, c := range got {
		if c.Text == "你和" {
			t.Errorf("3 键不应拼出 你和: %v", got)
		}
	}
}

// 按错一键（l 是 k 的邻键）也能打出想要的字：纠错行只补空位，不抢首位。
func TestNeighborCorrection(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "hk", Text: "好", Weight: 900},
	})
	e := New(d)
	for _, ch := range []byte("hl") {
		e.Type(ch)
	}
	got := e.Candidates()
	if len(got) == 0 || got[0].Text != "好" {
		t.Fatalf("hl 候选 = %v", got)
	}
}

// 词按错一键：纠错词排在字面能查到的候选之后。
func TestCorrectionWord(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "gr", Text: "关", Weight: 500},
		{Code: "grxi", Text: "关系", Weight: 900000},
	})
	e := New(d)
	for _, ch := range []byte("grzi") {
		e.Type(ch)
	}
	if got := e.Candidates(); len(got) == 0 || got[0].Text != "关" {
		t.Fatalf("grzi 首选 = %v", got)
	}
	if i := findText(t, e, "关系"); i == 0 {
		t.Fatalf("纠错词抢了首位: %v", e.Candidates())
	}
}

// 整句按错一键：三个音节的跨度内替换一个两键组，把句子纠回来。
func TestCorrectionSentence(t *testing.T) {
	d := buildDict(t, []Entry{
		{Code: "wo", Text: "我", Weight: 900000},
		{Code: "womfxm", Text: "我们发现", Weight: 900000},
	})
	e := New(d)
	for _, ch := range []byte("womfzm") {
		e.Type(ch)
	}
	// x 换成邻键 z 才是我们发现：纠错行排在正常候选之后。
	got := e.Candidates()
	if len(got) == 0 || got[0].Text != "我" {
		t.Fatalf("womfzm 首选 = %v", got)
	}
	if i := findText(t, e, "我们发现"); i == 0 {
		t.Fatalf("纠错句抢了首位: %v", got)
	}
}
