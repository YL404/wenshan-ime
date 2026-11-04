package engine

import "errors"

// maxBuf 是输入缓冲的上限（字节，双拼每音节两字节）。
const maxBuf = 32

const (
	// maxCandidates 是单键简码每个字母最多存的候选数；候选窗每页也用它。
	maxCandidates = 9
	// pageSize 是一页的候选数，对应数字键 1-9。
	pageSize = maxCandidates
	// maxPages 只用于 iOS 键盘一次性展开全部候选的网格上限；逐页翻页不受
	// 它限制，能一直翻到词库给不出更多候选为止。
	maxPages = 20
	// maxCorrections 是纠错段最多保留的候选数。
	maxCorrections = 20
)

// Engine 持有一次输入过程的全部状态。它只在主线程上被调用，不加锁。
type Engine struct {
	dict    *Dict
	freq    *Freq
	user    *UserDict
	phrases *UserDict
	buf     []byte

	// stream 是单一有序候选流：正常候选按分数降序，词库到底后把纠错候选
	// 接在末尾。翻页只是对它的窗口切片，首页和后续页不再各算一份，边界
	// 因此是连续的。只算到「当前需要的页数」，热路径不构建整个候选池。
	stream    []Candidate
	limit     int  // 当前 stream 正常段计算时用的上限
	exhausted bool // 正常段是否已到词库的底
	cands     []Candidate // 当前页 = stream 的切片
	page      int

	// 自造词的学习状态：本次组合输入过的全部按键、连续单字选出来的文字。
	session []byte
	picked  []byte
	singles int
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

// Save 把用户词频和自造词写回磁盘。自造词有改动就写；词频写一次要重写
// 整个文件，force 为 false 时攒够 saveEvery 次才写，适合每次按键后调用；
// force 为 true 时只要有改动就写，用于停用输入法或扩展退出前，不丢零头。
func (e *Engine) Save(force bool) error {
	var freqErr error
	if force || e.freq.due() {
		freqErr = e.freq.Save()
	}
	return errors.Join(freqErr, e.user.Save())
}

// Buffer 返回当前的按键缓冲。
func (e *Engine) Buffer() []byte { return e.buf }

// Candidates 返回当前页的候选，第一个是默认上屏项。
func (e *Engine) Candidates() []Candidate { return e.cands }

// PageNo 返回当前页码（0 起）。
func (e *Engine) PageNo() int { return e.page }

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
	e.stream = nil
	e.limit = 0
	e.exhausted = false
	e.cands = nil
	e.page = 0
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
	e.freq.Bump(text)
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
			e.user.Add(string(e.session), string(e.picked))
		}
		e.session, e.picked, e.singles = e.session[:0], e.picked[:0], 0
	}
	e.refresh()
	return text, true
}

// refresh 重建候选流并回到第 1 页。每次按键只算到第 1 页；后续页在翻页
// 或查询时由 ensure 按需补算，避免热路径一次性构建整个候选池。
func (e *Engine) refresh() {
	e.stream = nil
	e.limit = 0
	e.exhausted = false
	e.cands = nil
	e.page = 0
	if e.dict == nil || len(e.buf) == 0 {
		return
	}
	e.ensure(pageSize)
}

// ensure 保证 stream 至少有 n 个候选，或已经到底。limit 按指数增长，避免
// 每翻一页都全量重算；扩大上限只在尾部追加更低分的候选，前面的顺序不变，
// 所以翻页补算不会让已经看过的页跳动。
func (e *Engine) ensure(n int) {
	for len(e.stream) < n && !e.exhausted {
		e.rebuild(max(n, e.limit*2, pageSize))
	}
}

// rebuild 重新计算正常候选到 limit 个。不足说明词库到底，顺带把纠错候选
// 接在末尾；纠错挂在 tierTypo 层，永远排在正常候选之后，不再单独占首页
// 座位。用户词频在各来源截取前就计入分数，所以 limit 变大时只在尾部追加，
// 已经看过的页不会变。rebuild 换了底层数组，末尾重新把当前页指向新的 stream。
func (e *Engine) rebuild(limit int) {
	normal := e.collect(e.buf, limit, nil)
	// j/q/x/y 后的 ü 在自然码里按 v 键存，但 Rime 也接受照拼音写成 u。
	if alt, ok := umlautVariant(e.buf); ok {
		normal = e.collect(alt, limit, normal)
	}
	e.limit = limit
	e.exhausted = len(normal) < limit
	if e.exhausted {
		normal = append(normal, e.corrections(e.buf, normal)...)
	}
	e.stream = normal
	if e.page*pageSize < len(e.stream) {
		e.setPage(e.page)
	}
}

// corrections 返回纠错候选，按文本去掉正常段里已有的词。只在正常段到底后
// 调用，所以它们作为流末尾固定的一段，位置不随翻页补算漂移。
func (e *Engine) corrections(buf []byte, normal []Candidate) []Candidate {
	corrs := e.dict.Corrections(buf, maxCorrections)
	if alt, ok := umlautVariant(buf); ok {
		corrs = mergeCandidates(corrs, e.dict.Corrections(alt, maxCorrections), maxCorrections)
	}
	out := make([]Candidate, 0, len(corrs))
	for _, c := range corrs {
		if !hasText(normal, c.Text) && !hasText(out, c.Text) {
			out = append(out, c)
		}
	}
	return out
}

// collect 收集一种拼写下的正常候选，最多 limit 个。纠错候选不在这里处理，
// 它们由 corrections 单独接在流末尾，免得「留座位」逻辑让排序随上限漂移。
func (e *Engine) collect(buf []byte, limit int, cands []Candidate) []Candidate {
	if len(buf) == 1 {
		// 单键：给出这个键开头的最高频词，例如 l → 了。
		cands = mergeCandidates(cands, e.dict.Short(buf[0], e.freq), limit)
	} else {
		cands = mergeCandidates(cands, e.dict.Lookup(buf, limit, e.freq), limit)
		for _, c := range e.dict.Compose(buf, limit, e.freq) {
			cands = insertCandidate(cands, c, limit)
		}
	}
	if e.phrases != nil {
		cands = mergeCandidates(cands, e.phrases.Lookup(buf, limit, e.freq), limit)
	}
	if e.user != nil {
		cands = mergeCandidates(cands, e.user.Lookup(buf, limit, e.freq), limit)
	}
	return cands
}

// setPage 把当前页指向 stream 的第 target 页切片。调用前须保证该页有候选。
func (e *Engine) setPage(target int) {
	start := target * pageSize
	end := min((target+1)*pageSize, len(e.stream))
	e.page = target
	e.cands = e.stream[start:end]
}

// Page 翻页。delta 为 +1/-1，返回 false 表示没有翻动（已到首页/末页）。
// 不再有硬页数上限：翻到词库给不出更多候选才停。
func (e *Engine) Page(delta int) bool {
	if delta == 0 || len(e.stream) == 0 {
		return false
	}
	target := e.page + delta
	if target < 0 {
		return false
	}
	e.ensure((target + 1) * pageSize)
	if target*pageSize >= len(e.stream) {
		return false
	}
	e.setPage(target)
	return true
}

// HasNextPage 报告是否还有下一页。按需把流补到下一页页尾再判断，到底后
// 长度固定，结果是确定的；UI 据此显示页码和「还有更多」，不必知道总页数。
func (e *Engine) HasNextPage() bool {
	if len(e.stream) == 0 {
		return false
	}
	e.ensure((e.page + 2) * pageSize)
	return len(e.stream) > (e.page+1)*pageSize
}

// AllCandidates 返回流里的全部候选（最多 maxPages 页），供键盘一次展开。
// 它只补建流，不改变当前页。
func (e *Engine) AllCandidates() []Candidate {
	if len(e.stream) == 0 {
		return nil
	}
	e.ensure(maxPages * pageSize)
	return e.stream[:min(maxPages*pageSize, len(e.stream))]
}

// SelectGlobal 选出流里的第 i 个候选，索引可以落在后续页。
func (e *Engine) SelectGlobal(i int) (string, bool) {
	if i < 0 {
		return "", false
	}
	e.ensure(i + 1)
	if i >= len(e.stream) {
		return "", false
	}
	e.cands = e.stream
	return e.Select(i)
}

func hasText(cands []Candidate, text string) bool {
	for i := range cands {
		if cands[i].Text == text {
			return true
		}
	}
	return false
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
