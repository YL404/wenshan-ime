package engine

import (
	"bytes"
	"cmp"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"slices"
	"strings"
	"unicode/utf8"
)

// 词表二进制格式（小端）：
//
//	[0:6]   magic "WSIME2"
//	[6:8]   保留
//	[8:12]  条目数 n
//	[12:16] 字符串区长度
//	[16:20] 单字母简码条数 m
//	[20:24] 保留
//	之后 n×16 主记录、m×16 简码记录，最后是编码和词条的字符串区。
//
// 主记录按编码升序、同编码按权重降序排列，所以一次二分就能定位前缀区间。
// 简码记录是每个字母开头权重最高的若干条，按字母分组，供单键输入使用。
const (
	dictMagic  = "WSIME2"
	headerSize = 24
	recordSize = 16
)

// maxScan 是一次前缀查询最多检查的条目数，防止两字母前缀退化成全表扫描。
const maxScan = 20000

// Candidate 是一个候选词。
type Candidate struct {
	Text    string
	CodeLen int // 编码长度（字节），选词后要从输入缓冲里去掉这么多
	score   int64
}

// Dict 是映射到内存的词表，只读。
type Dict struct {
	n     int
	short int
	rec   []byte
	blob  []byte
}

// OpenDict 解析词表。返回的 Dict 引用传入的字节切片，不做拷贝。
func OpenDict(data []byte) (*Dict, error) {
	if len(data) < headerSize || string(data[:6]) != dictMagic {
		return nil, errors.New("dict: 文件头不对")
	}
	n := int(binary.LittleEndian.Uint32(data[8:12]))
	blobLen := int(binary.LittleEndian.Uint32(data[12:16]))
	short := int(binary.LittleEndian.Uint32(data[16:20]))
	recEnd := headerSize + (n+short)*recordSize
	if n < 0 || short < 0 || blobLen < 0 || recEnd > len(data) || recEnd+blobLen > len(data) {
		return nil, errors.New("dict: 文件被截断")
	}
	return &Dict{
		n:     n,
		short: short,
		rec:   data[headerSize:recEnd],
		blob:  data[recEnd : recEnd+blobLen],
	}, nil
}

// Len 返回条目数。
func (d *Dict) Len() int { return d.n }

func (d *Dict) code(i int) []byte {
	r := d.rec[i*recordSize:]
	off := binary.LittleEndian.Uint32(r[0:4])
	return d.blob[off : off+uint32(r[12])]
}

func (d *Dict) text(i int) []byte {
	r := d.rec[i*recordSize:]
	off := binary.LittleEndian.Uint32(r[4:8])
	return d.blob[off : off+uint32(r[13])]
}

func (d *Dict) weight(i int) uint32 {
	return binary.LittleEndian.Uint32(d.rec[i*recordSize+8:])
}

// lowerBound 返回第一个编码不小于 prefix 的条目下标。
func (d *Dict) lowerBound(prefix []byte) int {
	lo, hi := 0, d.n
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if bytes.Compare(d.code(mid), prefix) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// 候选分四层：编码刚好用完缓冲的最优先（打 ni 给「你」，打 nihk 给「你好」），
// 其次是还没打完的长词（打 wofax 给「我发现」），再次是只用掉前几个键的短词。
// 层号放在高位，层内按词频排。tierTypo 留给纠错候选，永远在正常候选之后。
const (
	tierTypo  = 0 // 按错一键纠出来的词，只补空位，不抢正常候选的位置
	tierShort = 1 // 编码比缓冲短
	tierLong  = 2 // 编码比缓冲长，词还没打完
	tierExact = 3 // 编码刚好用完缓冲
)

func candidateScore(weight uint32, codeLen, bufLen int) int64 {
	tier := int64(tierShort)
	switch {
	case codeLen == bufLen:
		tier = tierExact
	case codeLen > bufLen:
		tier = tierLong
	}
	// 末尾多着一个声母键（奇数缓冲）时，覆盖按键多的短词更具体，排在
	// 覆盖少的单字前面：打 wofaxmv 时「我发现」不该沉到「握」「窝」后面。
	// 编码最长 32 字节占 6 位，与 32 位的权重区不重叠。
	if bufLen%2 == 1 && tier == tierShort {
		return tier<<40 | int64(codeLen)<<32 | int64(weight)
	}
	return tier<<40 | int64(weight)
}

// lookupScore 是词表条目的分数。三键编码只可能来自单字辅码（词的编码都是
// 偶数），它不是一个打完的词，按「词还没打完」处理，让真实词组按词频和它
// 竞争：打 tmj 时「添加」要排在「钿」前面，而高频字「的」（deb）仍然靠
// 权重留在前面。
func lookupScore(weight uint32, codeLen, bufLen int) int64 {
	if codeLen == 3 && bufLen == 3 {
		return int64(tierLong)<<40 | int64(weight)
	}
	return candidateScore(weight, codeLen, bufLen)
}

// Lookup 返回输入缓冲的候选。两种来源合并：
//
//   - 编码以缓冲开头的词（还没打完，例如 nih 时的「你好」）；
//   - 前半段已经打完的词（例如打 nihk 时仍列出「你」，选中就只上屏「你」）。
//
// 合并在结果上按权重排序，编码刚好用完整个缓冲的词加权。用户词频 f 在
// 截取前 limit 个之前就计入分数，常用词不会因为词库权重低被截掉；f 可以为 nil。
func (d *Dict) Lookup(buf []byte, limit int, f *Freq) []Candidate {
	if len(buf) < 2 || limit <= 0 || d.n == 0 {
		return nil
	}
	best := make([]Candidate, 0, limit)
	// 已打完的更短词：只需在等长段里找，代价很小。
	for l := 2; l < len(buf); l += 2 {
		best = d.exactInto(best, buf[:l], len(buf), limit, f)
	}
	// 整个缓冲：前缀匹配，含还没打完的长词。
	best = d.prefixInto(best, buf, limit, f)
	if len(best) == 0 {
		return nil
	}
	return best
}

// prefixInto 把编码以 prefix 开头的条目合进 best。
func (d *Dict) prefixInto(best []Candidate, prefix []byte, limit int, f *Freq) []Candidate {
	scanned := 0
	for i := d.lowerBound(prefix); i < d.n && scanned < maxScan; i++ {
		code := d.code(i)
		if len(code) < len(prefix) || !bytes.Equal(code[:len(prefix)], prefix) {
			break
		}
		scanned++
		text := string(d.text(i))
		best = insertCandidate(best, Candidate{
			Text:    text,
			CodeLen: len(code),
			score:   lookupScore(d.weight(i), len(code), len(prefix)) + f.boost(text),
		}, limit)
	}
	return best
}

// exactInto 把编码恰好等于 code 的条目合进 best。
func (d *Dict) exactInto(best []Candidate, code []byte, bufLen, limit int, f *Freq) []Candidate {
	for i := d.lowerBound(code); i < d.n; i++ {
		c := d.code(i)
		if len(c) != len(code) || !bytes.Equal(c, code) {
			break
		}
		text := string(d.text(i))
		best = insertCandidate(best, Candidate{
			Text:    text,
			CodeLen: len(code),
			score:   lookupScore(d.weight(i), len(code), bufLen) + f.boost(text),
		}, limit)
	}
	return best
}

// 拼接参数：单个词最多覆盖 8 个音节；每多切一个词扣 segmentPenalty。
// 单字权重普遍在百万级（自然对数 14-17），所以这个惩罚必须大于它，
// 否则「级+许」这种高频单字凑出来的东西会压过真正的词「继续」。
const (
	maxWordSyllables = 8
	segmentPenalty   = 20.0
	altPerSegment    = 3
)

// Short 返回某个字母开头的最高频词，用于单键输入（比如 l 打「了」）。
func (d *Dict) Short(letter byte, f *Freq) []Candidate {
	var out []Candidate
	base := d.n * recordSize
	for i := 0; i < d.short; i++ {
		r := d.rec[base+i*recordSize:]
		off := binary.LittleEndian.Uint32(r[0:4])
		codeLen := int(r[12])
		if codeLen < 2 || d.blob[off] != letter {
			continue
		}
		textOff := binary.LittleEndian.Uint32(r[4:8])
		textLen := int(r[13])
		text := string(d.blob[textOff : textOff+uint32(textLen)])
		out = append(out, Candidate{
			Text:    text,
			CodeLen: codeLen,
			score:   candidateScore(binary.LittleEndian.Uint32(r[8:12]), codeLen, 1) + f.boost(text),
		})
	}
	return out
}

// isAuxEntry 报告一个词条是不是单字辅码。词编码每个音节两键，单字只有
// 两键编码；更长的单字编码都是辅码，不能当词组参与组句。
func isAuxEntry(text string, codeLen int) bool {
	return codeLen > 2 && utf8.RuneCountInString(text) == 1
}

// exactWeight 返回编码恰好等于 code 的真实词最高权重。辅码单字不算词：
// 否则组句会把 buvdl 里的 vdly 当成「装」，把末尾的 l 吃掉。
func (d *Dict) exactWeight(code []byte) (uint32, bool) {
	for i := d.lowerBound(code); i < d.n; i++ {
		c := d.code(i)
		if !bytes.Equal(c, code) {
			break
		}
		if isAuxEntry(string(d.text(i)), len(c)) {
			continue
		}
		return d.weight(i), true
	}
	return 0, false
}

// altText 是同一编码下的一种写法。
type altText struct {
	text   string
	weight uint32
}

// exactAlts 返回编码恰好等于 code 的前 n 种真实词写法，权重从高到低。
func (d *Dict) exactAlts(code []byte, n int) []altText {
	var out []altText
	for i := d.lowerBound(code); i < d.n && len(out) < n; i++ {
		c := d.code(i)
		if !bytes.Equal(c, code) {
			break
		}
		text := string(d.text(i))
		if isAuxEntry(text, len(c)) {
			continue
		}
		out = append(out, altText{text: text, weight: d.weight(i)})
	}
	return out
}

// Compose 把整个缓冲切成若干词，返回若干种拼法（最优的一种加上逐段换同音词的变体）。
// 词库里的条目大多是词而不是整句，靠这一步才能打出「我们继续」这种组合。
//
// 末尾多出一个声母键时（缓冲奇数长），把它当作可延展的半个音节：枚举 26 个
// 韵母键补全最后一个音节，让词格按词频竞争出「我发现 + zh → 我发现这」。
// 未输入的韵母不算进编码，候选仍然只消耗实际打过的键。
func (d *Dict) Compose(buf []byte, limit int, f *Freq) []Candidate {
	if len(buf) < 4 || d.n == 0 || limit <= 0 {
		return nil
	}
	odd := len(buf)%2 == 1
	syls := len(buf) / 2
	total := syls
	if odd {
		total++
	}
	best := make([]float64, total+1)
	prev := make([]int, total+1)
	segs := make([]int, total+1)
	for i := 1; i <= total; i++ {
		best[i] = math.Inf(-1)
		prev[i] = -1
	}
	for i := 0; i < syls; i++ {
		if math.IsInf(best[i], -1) {
			continue
		}
		for j := i + 1; j <= syls && j-i <= maxWordSyllables; j++ {
			w, found := d.exactWeight(buf[i*2 : j*2])
			if !found {
				continue
			}
			if s := best[i] + math.Log(float64(w)+1) - segmentPenalty; s > best[j] {
				best[j] = s
				prev[j] = i
				segs[j] = segs[i] + 1
			}
		}
	}
	// 末尾那个声母音节：词跨 [i,total) 的编码是 buf[i*2:] 再补一个韵母键。
	var lastFinal byte
	if odd {
		var scratch [maxBuf]byte
		for i := max(0, total-maxWordSyllables); i <= syls; i++ {
			if math.IsInf(best[i], -1) {
				continue
			}
			code := append(scratch[:0], buf[i*2:]...)
			for f := byte('a'); f <= 'z'; f++ {
				code = append(code, f)
				w, found := d.exactWeight(code)
				code = code[:len(code)-1]
				if !found {
					continue
				}
				if s := best[i] + math.Log(float64(w)+1) - segmentPenalty; s > best[total] {
					best[total] = s
					prev[total] = i
					segs[total] = segs[i] + 1
					lastFinal = f
				}
			}
		}
	}
	if prev[total] < 0 || segs[total] < 2 {
		return nil
	}

	// 回溯出每段的边界（以音节计）。
	ends := make([]int, 0, segs[total])
	for i := total; i > 0; i = prev[i] {
		ends = append(ends, i)
	}
	slices.Reverse(ends)
	starts := make([]int, len(ends))
	from := 0
	for k, e := range ends {
		starts[k] = from
		from = e
	}

	// 每段的同音备选：普通段直接取 buf 切片；末尾声母段要补上选中的韵母键。
	var trail []byte
	alts := make([][]altText, len(ends))
	for k := range ends {
		var code []byte
		if ends[k]*2 <= len(buf) {
			code = buf[starts[k]*2 : ends[k]*2]
		} else {
			trail = append(trail[:0], buf[starts[k]*2:]...)
			trail = append(trail, lastFinal)
			code = trail
		}
		alts[k] = d.exactAlts(code, altPerSegment)
		if len(alts[k]) == 0 {
			return nil
		}
	}

	var out []Candidate
	emit := func(override int, alt altText) {
		var b strings.Builder
		sum := 0.0
		for k := range ends {
			a := alts[k][0]
			if k == override {
				a = alt
			}
			b.WriteString(a.text)
			sum += math.Log(float64(a.weight) + 1)
		}
		// 折算回「单个词」的权重量级，方便和词典里的词一起排序。
		w := math.Exp(sum-segmentPenalty*float64(len(ends))+segmentPenalty) - 1
		text := b.String()
		out = insertCandidate(out, Candidate{
			Text:    text,
			CodeLen: len(buf),
			score:   candidateScore(clampWeight(w), len(buf), len(buf)) + f.boost(text),
		}, limit)
	}
	emit(-1, altText{})
	for k := range ends {
		for _, alt := range alts[k][1:] {
			emit(k, alt)
		}
	}
	return out
}

func clampWeight(w float64) uint32 {
	switch {
	case w <= 0:
		return 0
	case w > math.MaxUint32:
		return math.MaxUint32
	}
	return uint32(w)
}

// better 报告 a 是否该排在 b 前面：先看分数，同分时编码短的更具体。
func better(a, b Candidate) bool {
	if a.score != b.score {
		return a.score > b.score
	}
	return a.CodeLen < b.CodeLen
}

// insertCandidate 把 c 插入按分数降序排列的列表，保持长度不超过 limit，
// 并按文本去重（同一个词可能有多条读音）。
func insertCandidate(best []Candidate, c Candidate, limit int) []Candidate {
	for _, b := range best {
		if b.Text == c.Text {
			if b.score >= c.score {
				return best
			}
			break
		}
	}
	pos := len(best)
	for i, b := range best {
		if better(c, b) {
			pos = i
			break
		}
	}
	if pos >= limit {
		return best
	}
	if len(best) < limit {
		best = append(best, Candidate{})
	}
	copy(best[pos+1:], best[pos:])
	best[pos] = c
	// 去重：插入后可能和后面的同名词重复
	for i := pos + 1; i < len(best); i++ {
		if best[i].Text == c.Text {
			copy(best[i:], best[i+1:])
			best = best[:len(best)-1]
			break
		}
	}
	return best
}

// 一级简码是自然码传统的一键简码，单键输入时排在最前。
// 光靠词频定不出来：词库里「了」的字频权重只有 349 万，「来」有 1483 万。
var singleKey = map[byte]string{
	'q': "请", 'w': "我", 'e': "而", 'r': "人", 't': "他",
	'y': "一", 'u': "是", 'i': "出", 'o': "欧", 'p': "片",
	'a': "按", 's': "三", 'd': "的", 'f': "分", 'g': "个",
	'h': "和", 'j': "就", 'k': "可", 'l': "了",
	'z': "在", 'x': "小", 'c': "才", 'v': "这", 'b': "不",
	'n': "你", 'm': "们",
}

// shortLists 算出每个字母的单键候选，按字母分组。
// 每条给一个递减的合成权重，让存储顺序就是显示顺序。
func shortLists(entries []Entry) []Entry {
	var per [26][]Entry
	var curated [26]Entry
	var hasCurated [26]bool
	for _, e := range entries {
		// 单键候选只从两键单字里选，别把三、四码的辅码条目也算进来。
		if len(e.Code) != 2 || e.Code[0] < 'a' || e.Code[0] > 'z' {
			continue
		}
		// 单键只给单字，避免「版权」「三国群英传」这类高频长词混进来。
		if utf8.RuneCountInString(e.Text) != 1 {
			continue
		}
		i := e.Code[0] - 'a'
		if want, ok := singleKey[e.Code[0]]; ok && e.Text == want && !hasCurated[i] {
			curated[i], hasCurated[i] = e, true
		}
		list := per[i]
		pos := len(list)
		for j, x := range list {
			if e.Weight > x.Weight {
				pos = j
				break
			}
		}
		if pos >= maxCandidates {
			continue
		}
		list = append(list, Entry{})
		copy(list[pos+1:], list[pos:])
		list[pos] = e
		if len(list) > maxCandidates {
			list = list[:maxCandidates]
		}
		per[i] = list
	}

	var out []Entry
	for i := range per {
		list := per[i]
		if hasCurated[i] {
			// 把约定的简码提到最前，其余顺延。
			list = slices.DeleteFunc(list, func(e Entry) bool { return e.Text == curated[i].Text })
			list = append([]Entry{curated[i]}, list...)
			if len(list) > maxCandidates {
				list = list[:maxCandidates]
			}
		}
		for rank, e := range list {
			e.Weight = shortBaseWeight - uint32(rank)*1_000_000
			out = append(out, e)
		}
	}
	return out
}

// shortBaseWeight 是单键候选的起始权重，只用于定序，不代表真实词频。
const shortBaseWeight = 2_000_000_000

// Entry 是构建词表时的一条记录。
type Entry struct {
	Code   string
	Text   string
	Weight uint32
}

// WriteDict 把 entries 写成词表格式。entries 必须已按 Code 升序、同 Code 按
// Weight 降序排好，Prefix 的二分查找依赖这个顺序。
func WriteDict(w io.Writer, entries []Entry) error {
	// 二分查找依赖排序，这里兜底，调用方不用自己排。
	entries = slices.Clone(entries)
	slices.SortFunc(entries, func(a, b Entry) int {
		if c := strings.Compare(a.Code, b.Code); c != 0 {
			return c
		}
		return cmp.Compare(b.Weight, a.Weight)
	})

	shorts := shortLists(entries)
	all := append(entries, shorts...)

	blobLen := 0
	for _, e := range all {
		blobLen += len(e.Code) + len(e.Text)
	}
	head := make([]byte, headerSize)
	copy(head, dictMagic)
	binary.LittleEndian.PutUint32(head[8:12], uint32(len(entries)))
	binary.LittleEndian.PutUint32(head[12:16], uint32(blobLen))
	binary.LittleEndian.PutUint32(head[16:20], uint32(len(shorts)))
	if _, err := w.Write(head); err != nil {
		return err
	}

	recs := make([]byte, 0, len(all)*recordSize)
	blob := make([]byte, 0, blobLen)
	for _, e := range all {
		codeOff := len(blob)
		blob = append(blob, e.Code...)
		textOff := len(blob)
		blob = append(blob, e.Text...)
		var r [recordSize]byte
		binary.LittleEndian.PutUint32(r[0:4], uint32(codeOff))
		binary.LittleEndian.PutUint32(r[4:8], uint32(textOff))
		binary.LittleEndian.PutUint32(r[8:12], e.Weight)
		r[12] = byte(len(e.Code))
		r[13] = byte(len(e.Text))
		recs = append(recs, r[:]...)
	}
	if _, err := w.Write(recs); err != nil {
		return err
	}
	_, err := w.Write(blob)
	return err
}
