package engine

import "slices"

// maxBuf 是输入缓冲的上限（字节，双拼每音节两字节）。
const maxBuf = 32

// maxCandidates 是候选个数，对应数字键 1-9。
const maxCandidates = 9

// Engine 持有一次输入过程的全部状态。它只在主线程上被调用，不加锁。
type Engine struct {
	dict  *Dict
	freq  *Freq
	user  *UserDict
	buf   []byte
	cands []Candidate

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

// Candidates 返回当前候选，第一个是默认上屏项。
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
	e.session = e.session[:0]
	e.picked = e.picked[:0]
	e.singles = 0
}

// Select 取出第 i 个候选并把它占用的编码从缓冲里去掉，返回上屏文本。
// 剩余缓冲会重新查词，所以可以连续选词。
func (e *Engine) Select(i int) (string, bool) {
	if i < 0 || i >= len(e.cands) {
		return "", false
	}
	c := e.cands[i]
	// 候选的编码可能比缓冲长（词还没打全，例如 wofax 选「我发现」），
	// 这种情况把缓冲整个消耗掉即可。
	used := c.CodeLen
	if used > len(e.buf) {
		used = len(e.buf)
	}
	if e.freq != nil && e.freq.Bump(c.Text) {
		e.needSave = true
	}
	// 连续单字选词说明词库里没有这个词，组合结束后记成自造词。
	if c.CodeLen == 2 {
		e.singles++
		e.picked = append(e.picked, c.Text...)
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
	return c.Text, true
}

// refresh 重新计算候选。一个音节两个键，所以至少两键才有意义。
func (e *Engine) refresh() {
	e.cands = nil
	if e.dict == nil || len(e.buf) == 0 {
		return
	}
	e.collect(e.buf)
	// j/q/x/y 后的 ü 在自然码里按 v 键存，但 Rime 也接受照拼音写成 u。
	if alt, ok := umlautVariant(e.buf); ok {
		e.collect(alt)
	}
	e.applyFreq()
}

// applyFreq 按用户的使用习惯重排层内顺序。加权只落在低位的权重区，
// 所以翻不过「用掉多少键」那一层。
func (e *Engine) applyFreq() {
	if e.freq == nil || len(e.cands) < 2 {
		return
	}
	changed := false
	for i := range e.cands {
		if n := e.freq.Count(e.cands[i].Text); n > 0 {
			e.cands[i].score += freqBoost(n)
			changed = true
		}
	}
	if changed {
		slices.SortFunc(e.cands, func(a, b Candidate) int {
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

// collect 收集一种拼写下的候选：词典里的词，以及把缓冲整段拼起来的结果。
func (e *Engine) collect(buf []byte) {
	if len(buf) == 1 {
		// 单键：给出这个键开头的最高频词，例如 l → 了。
		e.cands = mergeCandidates(e.cands, e.dict.Short(buf[0]), maxCandidates)
	} else {
		e.cands = mergeCandidates(e.cands, e.dict.Lookup(buf, maxCandidates), maxCandidates)
		for _, c := range e.dict.Compose(buf, maxCandidates) {
			e.cands = insertCandidate(e.cands, c, maxCandidates)
		}
	}
	if e.user != nil {
		e.cands = mergeCandidates(e.cands, e.user.Lookup(buf, maxCandidates), maxCandidates)
	}
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
