// Package engine 实现双拼自然码的编码与查词。
//
// 键位表直接来自 Rime 的 double_pinyin.schema.yaml（speller/algebra 的
// 改写规则），逐条还原成「声母键 + 韵母键」两张表。因为双拼每个音节固定
// 两个键，编码全等长且可拼接，查词只需要一次前缀匹配，不需要切分歧义。
package engine

// twoLetterInitials 是自然码里占一个键的双字母声母。
var twoLetterInitials = map[string]byte{
	"zh": 'v',
	"ch": 'i',
	"sh": 'u',
}

// oneLetterInitials 是声母到键位的映射，键位与字母本身相同。
var oneLetterInitials = map[byte]byte{
	'b': 'b', 'p': 'p', 'm': 'm', 'f': 'f',
	'd': 'd', 't': 't', 'n': 'n', 'l': 'l',
	'g': 'g', 'k': 'k', 'h': 'h',
	'j': 'j', 'q': 'q', 'x': 'x',
	'r': 'r', 'z': 'z', 'c': 'c', 's': 's',
	'y': 'y', 'w': 'w',
}

// finals 是韵母到键位的映射。零声母音节的 a/o/e 也在这张表里（键位就是它本身）。
var finals = map[string]byte{
	"a": 'a', "o": 'o', "e": 'e', "i": 'i', "u": 'u', "v": 'v',
	"ai": 'l', "ei": 'z', "ao": 'k', "ou": 'b',
	"an": 'j', "en": 'f', "ang": 'h', "eng": 'g', "er": 'r',
	"ia": 'w', "ie": 'x', "iao": 'c', "iu": 'q',
	"ian": 'm', "in": 'n', "iang": 'd', "ing": 'y', "iong": 's',
	"ua": 'w', "uo": 'o', "uai": 'y', "ui": 'v',
	"uan": 'r', "un": 'p', "uang": 'd', "ong": 's',
	"ue": 't', "ve": 't', "van": 'r', "vn": 'p',
}

// isUmlautInitial 报告 j/q/x/y 后的 u 是不是 ü（Rime 用 derive 把它改写成 v）。
func isUmlautInitial(b byte) bool {
	return b == 'j' || b == 'q' || b == 'x' || b == 'y'
}

// splitSyllable 把一个拼音音节拆成声母键和韵母。零声母返回 init 0。
func splitSyllable(syl string) (init byte, fin string) {
	if len(syl) >= 2 {
		if k, ok := twoLetterInitials[syl[:2]]; ok {
			return k, syl[2:]
		}
	}
	if k, ok := oneLetterInitials[syl[0]]; ok {
		return k, syl[1:]
	}
	return 0, ""
}

// syllableCodes 返回一个音节的两键写法。Rime 用 derive 保留了部分原始拼写
// （ju/qu/xu/yu、零声母的 ai/ao/an/en/ou），这些也一并返回，用户两种都打得出。
func syllableCodes(syl string) []string {
	if syl == "" {
		return nil
	}
	init, fin := splitSyllable(syl)
	if init == 0 {
		// 零声母：首字母当占位，韵母照表取键（a→aa、ang→ah、er→er）。
		k, ok := finals[syl]
		if !ok {
			return nil
		}
		out := []string{string([]byte{syl[0], k})}
		// 两字母的零声母韵母（ai/ao/an/en/ou）也接受原样输入。
		if len(syl) == 2 && syl[0] != syl[1] {
			out = append(out, syl)
		}
		return dedupCodes(out)
	}
	if fin == "" {
		return nil
	}
	if isUmlautInitial(init) && fin == "u" {
		fin = "v"
	}
	k, ok := finals[fin]
	if !ok {
		return nil
	}
	out := []string{string([]byte{init, k})}
	if fin == "v" && isUmlautInitial(init) {
		out = append(out, string([]byte{init, 'u'}))
	}
	return dedupCodes(out)
}

func dedupCodes(in []string) []string {
	out := in[:1]
	for _, c := range in[1:] {
		if c != out[0] {
			out = append(out, c)
		}
	}
	return out
}

// Codes 返回整个词组的编码。单音节词会同时给出备选写法；多音节词只用规范写法，
// 避免组合爆炸。
func Codes(syllables []string) []string {
	if len(syllables) == 0 {
		return nil
	}
	if len(syllables) == 1 {
		return syllableCodes(syllables[0])
	}
	code := make([]byte, 0, len(syllables)*2)
	for _, syl := range syllables {
		cs := syllableCodes(syl)
		if len(cs) == 0 {
			return nil
		}
		code = append(code, cs[0]...)
	}
	return []string{string(code)}
}
