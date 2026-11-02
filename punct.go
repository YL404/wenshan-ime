package main

// 中文标点。只有一个元素的直接替换；有多个元素的按次序交替（左右引号）。
// 表里没有的字符照常交给应用，避免影响写代码时打的 - / = + * | 之类。
var punctTable = map[byte][]string{
	',':  {"，"},
	'.':  {"。"},
	'?':  {"？"},
	'!':  {"！"},
	':':  {"："},
	';':  {"；"},
	'(':  {"（"},
	')':  {"）"},
	'<':  {"《"},
	'>':  {"》"},
	'[':  {"【"},
	']':  {"】"},
	'{':  {"「"},
	'}':  {"」"},
	'/':  {"、"},
	'\\': {"、"},
	'~':  {"～"},
	'^':  {"……"},
	'_':  {"——"},
	'$':  {"￥"},
	'"':  {"“", "”"},
	'\'': {"‘", "’"},
}

// punctAlternated 记录交替型标点上一次用的是哪一个。
var punctAlternated [128]bool

// punctuate 返回按键对应的中文标点。
func punctuate(ch byte) (string, bool) {
	if int(ch) >= len(punctAlternated) {
		return "", false
	}
	alts, ok := punctTable[ch]
	if !ok {
		return "", false
	}
	if len(alts) == 1 {
		return alts[0], true
	}
	i := 0
	if punctAlternated[ch] {
		i = 1
	}
	punctAlternated[ch] = !punctAlternated[ch]
	return alts[i], true
}
