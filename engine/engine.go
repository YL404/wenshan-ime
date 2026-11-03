package engine

import "slices"

// maxBuf 是输入缓冲的上限（字节，双拼每音节两字节）。
const maxBuf = 32

const (
	// maxCandidates 是单键简码每个字母最多存的候选数；候选窗每页也用它。
	maxCandidates = 9
	// pageSize 是一页的候选数，对应数字键 1-9。
	pageSize = maxCandidates
	// maxPages 是候选总页数上限。多音节输入的候选池通常不到 180 个
	// （jintian 137、womf 175），20 页基本能翻完；单音节前缀能拖出
	// 几千个词，更深的候选价值低，一次性构建也会拖慢主线程。
	maxPages = 20
)

// Engine 持有一次输入过程的全部状态。它只在主线程上被调用，不加锁。
type Engine struct {
	dict      *Dict
	freq      *Freq
	user      *UserDict
	phrases   *UserDict
	buf       []byte
	cands     []Candidate // 当前页
	first     []Candidate // 第 1 页，翻页时用来还原
	deep      []Candidate // 第 2 页起的候选，按页切
	page      int
	deepReady bool

	// 自造词的学习状态：本次组合输入过的全部按键、连续单字选出来的文字。
	session      []byte
	picked       []byte
	singles      int
	needSave     bool
	needSaveUser bool
}

// New 建立引擎。dict 可以为 nil，此时只做缓冲管理（用于纯按键测试）。
func New(dict *Dict) *Engine {
	return &Engine{dict: dict}
}

// SetFreq 挂上用户词频表，之后选词会累计、候选会按使用习惯重排。
func (e *Engine) SetFreq(f *Freq) { e.freq = f }

// SetUserDict 挂上自造词表。
func (e *Engine) SetUserDict(u *UserDict) { e.user = u }

// SetPhrases 挂上只读的自定义短语表。它和自造词共用格式，但不会被写回。
func (e *Engine) SetPhrases(p *UserDict) { e.phrases = p }

// SaveUser 把新学的自造词写回磁盘。
func (e *Engine) SaveUser() error {
	if e.user == nil || !e.needSaveUser {
		return nil
	}
	if err := e.user.Save(); err != nil {
		return err
	}
	e.needSaveUser = false
	return nil
}

// SaveFreq 在攒够次数后把词频写回磁盘。
func (e *Engine) SaveFreq() error {
	if e.freq == nil || !e.needSave {
		return nil
	}
	if err := e.freq.Save(); err != nil {
		return err
	}
	e.needSave = false
	return nil
}

// Buffer 返回当前的按键缓冲。
func (e *Engine) Buffer() []byte { return e.buf }

// Candidates 返回当前页的候选，第一个是默认上屏项。
func (e *Engine) Candidates() []Candidate { return e.cands }

// Type 追加一个字母。返回 false 表示缓冲已满，按键未消费。
func (e *Engine) Type(ch byte) bool {
	if len(e.buf) >= maxBuf {
		return false
	}
	if len(e.buf) == 0 {
		e.session = e.session[:0]
		e.picked = e.picked[:0]
		e.singles = 0
	}
	e.buf = append(e.buf, ch)
	e.session = append(e.session, ch)
	e.refresh()
	return true
}

// Backspace 删掉一个字母。返回 false 表示缓冲本来就是空的。
func (e *Engine) Backspace() bool {
	if len(e.buf) == 0 {
		return false
	}
	e.buf = e.buf[:len(e.buf)-1]
	e.refresh()
	return true
}

// Reset 清空缓冲和这一轮的自造词学习状态。
func (e *Engine) Reset() {
	e.buf = e.buf[:0]
	e.cands = nil
	e.first = nil
	e.deep = nil
	e.page = 0
	e.deepReady = false
	e.session = e.session[:0]
	e.picked = e.picked[:0]
	e.singles = 0
}

// Select 取出第 i 个候选并把它占用的编码从缓冲里去掉，返回上屏文本。
// 剩余缓冲会重新查词，所以可以连续选词。
func (e *Engine) Select(i int) (string, bool) {
	return e.selectCandidate(i, nil)
}

// SelectChar 取出第 i 个候选的首字或尾字。编码消耗和 Select 一样：
// 词还没打完时也把整个缓冲消耗掉，避免残留半截编码。
func (e *Engine) SelectChar(i int, last bool) (string, bool) {
	return e.selectCandidate(i, func(text string) string {
		runes := []rune(text)
		if len(runes) == 0 {
			return ""
		}
		if last {
			return string(runes[len(runes)-1])
		}
		return string(runes[0])
	})
}

// selectCandidate 是 Select 和 SelectChar 的共同路径。pick 为 nil 时上屏整段候选。
func (e *Engine) selectCandidate(i int, pick func(string) string) (string, bool) {
	if i < 0 || i >= len(e.cands) {
		return "", false
	}
	c := e.cands[i]
	text := c.Text
	if pick != nil {
		text = pick(text)
		if text == "" {
			return "", false
		}
	}
	// 候选的编码可能比缓冲长（词还没打全，例如 wofax 选「我发现」），
	// 这种情况把缓冲整个消耗掉即可。
	used := c.CodeLen
	if used > len(e.buf) {
		used = len(e.buf)
	}
	if e.freq != nil && e.freq.Bump(text) {
		e.needSave = true
	}
	// 连续单字选词说明词库里没有这个词，组合结束后记成自造词。
	if c.CodeLen == 2 {
		e.singles++
		e.picked = append(e.picked, text...)
	} else {
		e.singles, e.picked = 0, e.picked[:0]
	}
	e.buf = append(e.buf[:0], e.buf[used:]...)
	if len(e.buf) == 0 {
		if e.singles >= 2 && len(e.session) >= 4 {
			if e.user.Add(string(e.session), string(e.picked)) {
				e.needSaveUser = true
			}
		}
		e.session, e.picked, e.singles = e.session[:0], e.picked[:0], 0
	}
	e.refresh()
	return text, true
}

// refresh 重新计算第 1 页候选。一个音节两个键，所以至少两键才有意义。
func (e *Engine) refresh() {
	e.cands = nil
	e.first = nil
	e.deep = nil
	e.page = 0
	e.deepReady = false
	if e.dict == nil || len(e.buf) == 0 {
		return
	}
	first := e.collect(e.buf, pageSize, true, nil)
	// j/q/x/y 后的 ü 在自然码里按 v 键存，但 Rime 也接受照拼音写成 u。
	if alt, ok := umlautVariant(e.buf); ok {
		first = e.collect(alt, pageSize, true, first)
	}
	e.applyFreq(first)
	e.first = first
	e.cands = first
}

// Page 翻页。delta 为 +1/-1，返回 false 表示没有翻动（已到首页/末页）。
func (e *Engine) Page(delta int) bool {
	if delta == 0 || len(e.first) == 0 {
		return false
	}
	target := e.page + delta
	if target < 0 || target >= maxPages {
		return false
	}
	if target == 0 {
		e.page = 0
		e.cands = e.first
		return true
	}
	if !e.deepReady {
		e.buildDeep()
		e.deepReady = true
	}
	start := (target - 1) * pageSize
	if start >= len(e.deep) {
		return false
	}
	end := min(start+pageSize, len(e.deep))
	e.page = target
	e.cands = e.deep[start:end]
	return true
}

// buildDeep 生成第 1 页之外的候选。第 1 页保持 refresh 的结果不变，
// 这里只补后续页，并按文本去掉已经在第 1 页出现过的词。
func (e *Engine) buildDeep() {
	e.deep = nil
	if e.dict == nil || len(e.buf) == 0 {
		return
	}
	// 多取一页的容量：第 1 页的候选可能被纠错候选挤掉几位，过滤后仍要够分页。
	limit := maxPages * pageSize
	deep := e.collect(e.buf, limit, false, nil)
	if alt, ok := umlautVariant(e.buf); ok {
		deep = e.collect(alt, limit, false, deep)
	}
	e.applyFreq(deep)
	out := make([]Candidate, 0, len(deep))
	for _, c := range deep {
		if !hasText(e.first, c.Text) {
			out = append(out, c)
		}
	}
	e.deep = out
}

func hasText(cands []Candidate, text string) bool {
	for i := range cands {
		if cands[i].Text == text {
			return true
		}
	}
	return false
}

// applyFreq 按用户的使用习惯重排层内顺序。加权只落在低位的权重区，
// 所以翻不过「用掉多少键」那一层。
func (e *Engine) applyFreq(cands []Candidate) {
	if e.freq == nil || len(cands) < 2 {
		return
	}
	changed := false
	for i := range cands {
		if n := e.freq.Count(cands[i].Text); n > 0 {
			cands[i].score += freqBoost(n)
			changed = true
		}
	}
	if changed {
		slices.SortFunc(cands, func(a, b Candidate) int {
			switch {
			case better(a, b):
				return -1
			case better(b, a):
				return 1
			}
			return 0
		})
	}
}

// collect 收集一种拼写下的候选，最多 limit 个。withCorrections 为 true 时
// 把纠错候选放到末尾，并给它们留两个座位；第 2 页起不再重复纠错候选。
func (e *Engine) collect(buf []byte, limit int, withCorrections bool, cands []Candidate) []Candidate {
	if len(buf) == 1 {
		// 单键：给出这个键开头的最高频词，例如 l → 了。
		cands = mergeCandidates(cands, e.dict.Short(buf[0]), limit)
	} else {
		cands = mergeCandidates(cands, e.dict.Lookup(buf, limit), limit)
		for _, c := range e.dict.Compose(buf, limit) {
			cands = insertCandidate(cands, c, limit)
		}
	}
	if e.phrases != nil {
		cands = mergeCandidates(cands, e.phrases.Lookup(buf, limit), limit)
	}
	if e.user != nil {
		cands = mergeCandidates(cands, e.user.Lookup(buf, limit), limit)
	}
	if !withCorrections {
		return cands
	}
	// 按错一键的纠错：给纠错行留两个座位，挤掉排尾的正常候选，
	// 不让「打错的输入恰好也是合法音节」时凑出来的候选把它挤没。
	if corrs := e.dict.Corrections(buf, limit); len(corrs) > 0 {
		if len(cands) > limit-2 {
			cands = cands[:limit-2]
		}
		for _, c := range corrs {
			cands = insertCandidate(cands, c, limit)
		}
	}
	return cands
}

// umlautVariant 把 j/q/x/y + u 的两键组合改写成 j/q/x/y + v。
// 双拼里每个音节固定两键，所以按位置判断不会误伤别的韵母。
func umlautVariant(buf []byte) ([]byte, bool) {
	var out []byte
	changed := false
	for i := 0; i+1 < len(buf); i += 2 {
		if c := buf[i]; (c == 'j' || c == 'q' || c == 'x' || c == 'y') && buf[i+1] == 'u' {
			if out == nil {
				out = append([]byte(nil), buf...)
			}
			out[i+1] = 'v'
			changed = true
		}
	}
	return out, changed
}

// mergeCandidates 合并两种拼写写法的候选，保持分层与词频顺序。
func mergeCandidates(a, b []Candidate, limit int) []Candidate {
	if len(b) == 0 {
		return a
	}
	out := make([]Candidate, 0, limit)
	for _, list := range [2][]Candidate{a, b} {
		for _, c := range list {
			out = insertCandidate(out, c, limit)
		}
	}
	return out
}
