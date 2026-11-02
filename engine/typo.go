package engine

import (
	"math"
	"slices"
)

// 按错一键的邻键纠错：把缓冲按两键组切分，其中恰好一个组被 QWERTY
// 邻键或对调变体替换，替换后的词必须真的在词库里。候选挂在 tierTypo
// 层，只补正常候选剩下的空位，永远不抢首位。
//
// 纠错跨度最多 3 个音节：更长的词组让词格拆成小段补，每条纠错边最多
// 替换一个两键组——漏键和多键不做，那要换一套打错的模型。

// typoPenalty 是一条纠错替换边的额外罚分。只影响多条纠错路径之间选哪条，
// 因为 tierTypo 已经把纠错候选压到正常候选之后。
const typoPenalty = 10

// neighbors 是 QWERTY 键盘的邻键，含斜角：打错一键多半落在这些键上。
var neighbors = [26]string{
	'q' - 'a': "wa", 'w' - 'a': "qeas", 'e' - 'a': "wrsd", 'r' - 'a': "etdf",
	't' - 'a': "ryfg", 'y' - 'a': "tugh", 'u' - 'a': "yihj", 'i' - 'a': "uojk",
	'o' - 'a': "ipkl", 'p' - 'a': "ol",
	'a' - 'a': "qwsz", 's' - 'a': "awedzx", 'd' - 'a': "esrfxc", 'f' - 'a': "rdtgcv",
	'g' - 'a': "tyfhvb", 'h' - 'a': "yugjbn", 'j' - 'a': "uihknm", 'k' - 'a': "iojlm",
	'l' - 'a': "opk",
	'z' - 'a': "asx", 'x' - 'a': "sdzc", 'c' - 'a': "dfxv", 'v' - 'a': "fgcb",
	'b' - 'a': "gvhn", 'n' - 'a': "hjbm", 'm' - 'a': "njkl",
}

// groupVariants 返回一个两键组的全部纠错写法：两键各自换成邻键，加上
// 两键对调。不含原组，也不含重复。
func groupVariants(group []byte) [][]byte {
	var out [][]byte
	add := func(a, b byte) {
		if a == group[0] && b == group[1] {
			return
		}
		for _, v := range out {
			if v[0] == a && v[1] == b {
				return
			}
		}
		out = append(out, []byte{a, b})
	}
	for i := 0; i < 2; i++ {
		for _, n := range neighbors[group[i]-'a'] {
			if i == 0 {
				add(byte(n), group[1])
			} else {
				add(group[0], byte(n))
			}
		}
	}
	if group[0] != group[1] {
		add(group[1], group[0])
	}
	return out
}

// Corrections 返回按错一键的纠错候选：整段缓冲切成两键组，其中恰好一个
// 组被变体替换。候选挂在 tierTypo 层，只补正常候选剩下的空位。
func (d *Dict) Corrections(buf []byte, limit int) []Candidate {
	if len(buf) < 2 || len(buf)%2 != 0 || d.n == 0 || limit <= 0 {
		return nil
	}
	syls := len(buf) / 2

	// best[t][i]：前 i 个音节、是否用过纠错替换（t=1）的最优分。
	// 纠错边只从 t=0 跨到 t=1，所以每条路径最多替换一个两键组。
	const noTypo, withTypo = 0, 1
	best := [2][]float64{make([]float64, syls+1), make([]float64, syls+1)}
	prev := [2][]int{make([]int, syls+1), make([]int, syls+1)}
	prevCode := [2][][]byte{make([][]byte, syls+1), make([][]byte, syls+1)}
	for t := noTypo; t <= withTypo; t++ {
		for i := 0; i <= syls; i++ {
			best[t][i] = math.Inf(-1)
			prev[t][i] = -1
		}
	}
	best[noTypo][0] = 0

	var scratch [maxBuf]byte
	for i := 0; i < syls; i++ {
		// exact 边：和组句一样，任何长度的段；不改变「是否用过纠错」。
		for j := i + 1; j <= syls && j-i <= maxWordSyllables; j++ {
			w, found := d.exactWeight(buf[i*2 : j*2])
			if !found {
				continue
			}
			edge := math.Log(float64(w)+1) - segmentPenalty
			for t := noTypo; t <= withTypo; t++ {
				if math.IsInf(best[t][i], -1) {
					continue
				}
				if s := best[t][i] + edge; s > best[t][j] {
					best[t][j] = s
					prev[t][j] = i
					prevCode[t][j] = nil
				}
			}
		}
		// 纠错边：跨度最多 3 个音节，每条边恰好替换一个两键组，罚分更高。
		if math.IsInf(best[noTypo][i], -1) {
			continue
		}
		for j := i + 1; j <= syls && j-i <= 3; j++ {
			for p := i; p < j; p++ {
				for _, v := range groupVariants(buf[p*2 : p*2+2]) {
					code := append(append(scratch[:0], buf[i*2:p*2]...), v...)
					code = append(code, buf[(p+1)*2:j*2]...)
					w, found := d.exactWeight(code)
					if !found {
						continue
					}
					s := best[noTypo][i] + math.Log(float64(w)+1) - segmentPenalty - typoPenalty
					if s > best[withTypo][j] {
						best[withTypo][j] = s
						prev[withTypo][j] = i
						prevCode[withTypo][j] = append([]byte(nil), code...)
					}
				}
			}
		}
	}

	if math.IsInf(best[withTypo][syls], -1) {
		return nil
	}

	// 回溯：从终点往回走。遇到纠错边（编码非 nil）就切回 noTypo 状态，
	// 之前的路径全部没用过纠错，所以恰好有一条纠错边。
	type span struct {
		start, end int
		code       []byte // 非 nil 表示这段是纠错替换
	}
	var path []span
	i, t := syls, withTypo
	for i > 0 {
		code := prevCode[t][i]
		path = append(path, span{start: prev[t][i], end: i, code: code})
		i = prev[t][i]
		if code != nil {
			t = noTypo
		}
	}
	slices.Reverse(path)

	// 每段的同音备选：普通段直接取 buf 切片；纠错段用替换后的编码。
	alts := make([][]altText, len(path))
	for k := range path {
		code := path[k].code
		if code == nil {
			code = buf[path[k].start*2 : path[k].end*2]
		}
		alts[k] = d.exactAlts(code, altPerSegment)
		if len(alts[k]) == 0 {
			return nil
		}
	}

	var out []Candidate
	emit := func(override int, alt altText) {
		var b []byte
		sum := 0.0
		for k := range path {
			a := alts[k][0]
			if k == override {
				a = alt
			}
			b = append(b, a.text...)
			sum += math.Log(float64(a.weight) + 1)
		}
		// 折算回「单个词」的权重量级，再扣一条纠错罚分；tierTypo 把
		// 纠错候选压到正常候选之后，权重只决定纠错行之间的顺序。
		w := math.Exp(sum-segmentPenalty*float64(len(path))-typoPenalty+segmentPenalty) - 1
		out = insertCandidate(out, Candidate{
			Text:    string(b),
			CodeLen: len(buf),
			score:   int64(tierTypo)<<40 | int64(clampWeight(w)),
		}, limit)
	}
	emit(-1, altText{})
	for k := range path {
		for _, alt := range alts[k][1:] {
			emit(k, alt)
		}
	}
	return out
}
