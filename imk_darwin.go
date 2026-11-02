package main

import (
	"unicode"
	"unsafe"

	"github.com/ebitengine/purego/objc"

	"wenshan/engine"
)

// IMK 回调全部发生在主线程，所以这里的状态不加锁。
// 按键热路径的顺序是：分类按键 → 查词（微秒级）→ 刷新候选窗 → 写回预编辑。

const (
	nsEventTypeKeyDown      = 10
	nsEventTypeFlagsChanged = 12

	nsModShift   = 1 << 17
	nsModControl = 1 << 18
	nsModOption  = 1 << 19
	nsModCommand = 1 << 20

	keyCodeDelete      = 51
	keyCodeEscape      = 53
	keyCodeSpace       = 49
	keyCodeReturn      = 36
	keyCodeKeypadEnter = 76
	keyCodeTab         = 48
	keyCodePageUp      = 116
	keyCodePageDown    = 121
	keyCodeLeftShift   = 56
	keyCodeRightShift  = 60
)

// 这几个选择器只在切换输入模式时用到。
var (
	selRespondsToSelector = objc.RegisterName("respondsToSelector:")
	selAttributesForChar  = objc.RegisterName("attributesForCharacterIndex:lineHeightRectangle:")
	selPerformSelector    = objc.RegisterName("performSelector:withObject:afterDelay:")
	selMouseLocation      = objc.RegisterName("mouseLocation")
	selHideHud            = objc.RegisterName("hideHud")
)

var (
	eng       *engine.Engine
	curClient objc.ID

	// asciiMode 是 Shift 轻点切出来的英文直通模式；fullWidth 控制标点是否转全角。
	asciiMode = false
	fullWidth = true

	// 用来区分「按住 Shift 打大写」和「轻点 Shift 切中英」。
	shiftDown bool
	shiftUsed bool

	// 中英文之间自动补空格时，靠这个记住「光标前刚出现的是什么」。
	// 只信自己的状态，不去问应用：问一次要几个同步往返，是毫秒级开销。
	prevClass int

	// inlineText 是中文态按 Shift+大写切出来的临时英文串。它不进引擎，
	// 预编辑直接显示原文；空格/回车结束，退格/Esc 可改。
	inlineText  string
	inlineSpace bool

	// 光标位置在一个组合里不会变（预编辑串只会往右长），所以每次组合只查一次：
	// 刚 setMarkedText 完就查要等前台应用排版，是这条路径上最贵的一步。
	candCaret  NSRect
	caretValid bool
)

const (
	prevNone  = iota // 未知或刚打过空格/标点
	prevCJK          // 刚上屏中文
	prevASCII        // 刚打出英文或数字
)

// handleEvent 是热路径：它的返回值决定这次按键是否被输入法吃掉。
// 在这里停留的时间直接占用前台 App 的主线程，所以只做必要的事。
func handleEvent(self objc.ID, cmd objc.SEL, event objc.ID, client objc.ID) (handled bool) {
	// 输入法是常驻后台进程，一个 Go panic 就会让它消失、按键全部透传。
	// 这里兜住，宁可这次按键不处理，也不要整个进程退出。
	defer func() {
		if r := recover(); r != nil {
			logf("handleEvent panic: %v", r)
			handled = false
		}
	}()

	typ := send(event, selEventType)
	mods := objc.Send[uintptr](event, selModifierFlags)
	if debugKeys {
		logf("key type=%d code=%d mods=%#x ascii=%v buf=%q inline=%q",
			typ, objc.Send[uintptr](event, selKeyCode), mods, asciiMode, eng.Buffer(), inlineText)
	}

	if typ == nsEventTypeFlagsChanged {
		handleFlags(mods, objc.Send[uintptr](event, selKeyCode), self)
		return false
	}
	if typ != nsEventTypeKeyDown {
		return false
	}
	// 按住 Shift 期间按过别的键，松开时就不算「轻点」。
	if shiftDown {
		shiftUsed = true
	}
	raw := firstByte(send(event, selCharacters))
	ch := raw
	if ch >= 'A' && ch <= 'Z' {
		ch += 'a' - 'A'
	}
	if asciiMode {
		spaceBeforeASCII(client, ch)
		return false
	}
	// 带 Command/Control/Option 的组合键一律放行，交给应用自己处理。
	if mods&(nsModCommand|nsModControl|nsModOption) != 0 {
		return false
	}
	keyCode := objc.Send[uintptr](event, selKeyCode)

	// 临时英文串：字母原样追加，空格/回车结束，退格/Esc 可改。
	// 其他键先把这段英文上屏，再按普通按键继续处理。
	if inlineText != "" {
		switch {
		case raw >= 'a' && raw <= 'z' || raw >= 'A' && raw <= 'Z':
			inlineText += string(raw)
			showInline(client)
			return true
		case keyCode == keyCodeSpace:
			commitInline(client, true)
			return true
		case keyCode == keyCodeReturn || keyCode == keyCodeKeypadEnter:
			commitInline(client, false)
			prevClass = prevNone // 回车结束不补空格，后面紧接中文也不自动加
			return true
		case keyCode == keyCodeDelete:
			inlineText = inlineText[:len(inlineText)-1]
			if inlineText == "" {
				cancelInline(client)
			} else {
				showInline(client)
			}
			return true
		case keyCode == keyCodeEscape:
			cancelInline(client)
			return true
		default:
			commitInline(client, false)
		}
	}

	// 中文态按住 Shift 打大写字母：没有缓冲时直接上屏；
	// 正在打拼音时把已打的编码接进临时英文串，再从这字母继续。
	if raw >= 'A' && raw <= 'Z' && mods&nsModShift != 0 {
		if len(eng.Buffer()) > 0 {
			startInline(client, raw)
			return true
		}
		text := string(raw)
		if needSpaceBefore(raw) {
			text = " " + text
		}
		insertText(client, text)
		prevClass = prevASCII
		return true
	}
	// Shift+空格：全角/半角标点切换。
	if keyCode == keyCodeSpace && mods&nsModShift != 0 {
		fullWidth = !fullWidth
		if fullWidth {
			showHud(self, "全角")
		} else {
			showHud(self, "半角")
		}
		return true
	}

	switch keyCode {
	case keyCodeDelete:
		prevClass = prevNone
		if eng.Backspace() {
			applyPreedit(client)
			return true
		}
		return false
	case keyCodeEscape:
		prevClass = prevNone
		if len(eng.Buffer()) == 0 {
			return false
		}
		eng.Reset()
		applyPreedit(client)
		return true
	case keyCodeReturn, keyCodeKeypadEnter:
		// 回车把缓冲里的字母原样上屏，中文状态下不用切模式就能打英文。
		if commitRaw(client) {
			return true
		}
		prevClass = prevNone
		return false
	case keyCodeSpace, keyCodeTab:
		if text, ok := eng.Select(0); ok {
			commit(client, text)
			return true
		}
		// 没有候选（比如打了一串不成立的编码）时，空格也把原样字母送出去。
		if commitRaw(client) {
			return true
		}
		prevClass = prevNone
		return false
	case keyCodePageUp:
		if len(eng.Candidates()) == 0 {
			return false
		}
		if eng.Page(-1) {
			showCandidates(client)
		}
		return true
	case keyCodePageDown:
		if len(eng.Candidates()) == 0 {
			return false
		}
		if eng.Page(1) {
			showCandidates(client)
		}
		return true
	}

	if len(eng.Buffer()) > 0 && ch >= '1' && ch <= '9' {
		if text, ok := eng.Select(int(ch - '1')); ok {
			commit(client, text)
			return true
		}
	}
	// [ / ] 取当前候选的首字 / 尾字，编码消耗和正常选词一样。
	if len(eng.Buffer()) > 0 && (ch == '[' || ch == ']') {
		if text, ok := eng.SelectChar(0, ch == ']'); ok {
			commit(client, text)
			return true
		}
	}
	// = / - 翻页。候选窗开着时由输入法接管，到边界也不再当字符上屏。
	if len(eng.Candidates()) > 0 && (ch == '=' || ch == '-') {
		delta := 1
		if ch == '-' {
			delta = -1
		}
		if eng.Page(delta) {
			showCandidates(client)
		}
		return true
	}
	if ch >= 'a' && ch <= 'z' {
		if eng.Type(ch) {
			applyPreedit(client)
			return true
		}
		return false
	}
	// 标点：先把已经输入的词上屏，再插入中文标点，这个键被消费掉。
	if s, ok := punctuate(ch); ok && fullWidth {
		if len(eng.Buffer()) > 0 {
			if text, ok := eng.Select(0); ok {
				commit(client, text)
			}
		}
		insertText(client, s)
		prevClass = prevNone
		return true
	}
	// 其他可打印字符：先把已经输入的词上屏，这个键照常交给应用。
	if len(eng.Buffer()) > 0 && ch >= 0x20 {
		if text, ok := eng.Select(0); ok {
			commit(client, text)
		}
	}
	if ch == 0 {
		// 方向键、功能键这类看不到字符的键，状态就不可信了。
		prevClass = prevNone
		return false
	}
	spaceBeforeASCII(client, ch)
	return false
}

// startInline 把当前拼音缓冲转成临时英文串，并接上触发的大写字母。
// prevClass 保持到提交时再更新，这样取消后仍能正确判断中英边界。
func startInline(client objc.ID, ch byte) {
	inlineText = string(eng.Buffer()) + string(ch)
	inlineSpace = prevClass == prevCJK
	eng.Reset()
	caretValid = false
	hideCandidates()
	showInline(client)
}

// showInline 只刷新预编辑串，候选窗在切进临时英文时已经收起。
func showInline(client objc.ID) {
	if inlineText == "" {
		clearMarked(client)
		return
	}
	ns := nsString(inlineText)
	if clientCan(client, selSetMarkedText) {
		send(client, selSetMarkedText, ns, uintptr(len(inlineText)), 0, nsNotFound, 0)
	}
	send(ns, selRelease)
}

// commitInline 把临时英文串上屏。空格结束补一个空格；回车结束不补，
// 方便后面直接紧跟中文（例如 iOS版、iPhone手机）。
func commitInline(client objc.ID, trailingSpace bool) {
	if inlineText == "" {
		return
	}
	text := inlineText
	if inlineSpace {
		text = " " + text
	}
	if trailingSpace {
		text += " "
	}
	inlineText = ""
	inlineSpace = false
	caretValid = false
	if client != 0 {
		insertText(client, text)
	}
	if trailingSpace {
		prevClass = prevNone
	} else {
		prevClass = prevASCII
	}
	hideCandidates()
}

func cancelInline(client objc.ID) {
	inlineText = ""
	inlineSpace = false
	caretValid = false
	clearMarked(client)
	hideCandidates()
}

// spaceBeforeASCII 在「中文紧挨着英文/数字」时补一个空格。
func spaceBeforeASCII(client objc.ID, ch byte) {
	if !needSpaceBefore(ch) {
		return
	}
	if client != 0 {
		insertText(client, " ")
	}
	prevClass = prevASCII
}

// needSpaceBefore 报告这个字符前面是否需要补空格。
func needSpaceBefore(ch byte) bool {
	return isASCIIAlnum(ch) && prevClass == prevCJK
}

func isASCIIAlnum(ch byte) bool {
	return ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z'
}

func startsWithHan(s string) bool {
	for _, r := range s {
		return unicode.Is(unicode.Han, r)
	}
	return false
}

// classOf 判断一段刚上屏的文字属于哪一类，用于后续的空格判断。
func classOf(s string) int {
	switch {
	case startsWithHan(s):
		return prevCJK
	case s != "" && isASCIIAlnum(s[0]):
		return prevASCII
	}
	return prevNone
}

// handleFlags 处理 Shift 按下/松开。只有按下期间没打过别的键才算轻点。
func handleFlags(mods, keyCode uintptr, self objc.ID) {
	if keyCode != keyCodeLeftShift && keyCode != keyCodeRightShift {
		return
	}
	down := mods&nsModShift != 0
	switch {
	case down && !shiftDown:
		shiftDown = true
		// 和 Cmd/Ctrl/Option 一起按的 Shift 不算轻点：像 Cmd+Shift+3 截图
		// 这类快捷键的按键会被系统吃掉，我们只看到 Shift 一按一松。
		shiftUsed = mods&(nsModCommand|nsModControl|nsModOption) != 0
	case !down && shiftDown:
		shiftDown = false
		if !shiftUsed {
			toggleAscii(self)
		}
	}
}

// toggleAscii 在中文/英文直通之间切换。切到英文时把没上屏的拼音按原样打出去，
// 和 Rime 的行为一致。
func toggleAscii(self objc.ID) {
	if inlineText != "" {
		commitInline(curClient, false)
	}
	asciiMode = !asciiMode
	caretValid = false
	logf("mode: ascii=%v", asciiMode)
	if asciiMode && len(eng.Buffer()) > 0 {
		if curClient != 0 {
			text := string(eng.Buffer())
			if prevClass == prevCJK {
				text = " " + text
			}
			insertText(curClient, text)
			prevClass = prevASCII
		}
		eng.Reset()
	}
	hideCandidates()
	if asciiMode {
		showHud(self, "英文")
	} else {
		showHud(self, "中文")
	}
}

func activateServer(self objc.ID, cmd objc.SEL, sender objc.ID) {
	eng.Reset()
	inlineText = ""
	inlineSpace = false
	caretValid = false
	prevClass = prevNone
	shiftDown, shiftUsed = false, false
	retainClient(sender)
	hideCandidates()
	logf("activate ascii=%v", asciiMode)
	// 英文模式下切回来要能看见状态，否则就像「打不出中文」。
	if asciiMode {
		showHud(self, "英文")
	}
}

func deactivateServer(self objc.ID, cmd objc.SEL, sender objc.ID) {
	finishInput(sender)
}

// commitComposition 是应用主动结束输入（例如点在别处）时调用的。
func commitComposition(self objc.ID, cmd objc.SEL, sender objc.ID) {
	finishInput(sender)
}

// hideHud 由 performSelector:afterDelay: 触发，只收掉模式提示，不动候选窗。
func hideHud(self objc.ID, cmd objc.SEL) {
	cand.hideHud()
}

// recognizedEvents 订阅按下和修饰键变化：后者用来识别 Shift 轻点。
func recognizedEvents(self objc.ID, cmd objc.SEL, sender objc.ID) uint {
	mask := uint(1)<<nsEventTypeKeyDown | 1<<nsEventTypeFlagsChanged
	if debugKeys {
		logf("recognizedEvents -> %d", mask)
	}
	return mask
}

// finishInput 把未完成的输入上屏并清干净。
func finishInput(client objc.ID) {
	if client == 0 {
		client = curClient
	}
	if inlineText != "" {
		commitInline(client, false)
	}
	if text, ok := eng.Select(0); ok && client != 0 {
		insertText(client, text)
	}
	eng.Reset()
	caretValid = false
	prevClass = prevNone
	if client != 0 {
		clearMarked(client)
	}
	hideCandidates()
	dropClient()
	saveLearning()
}

// saveLearning 把词频和自造词落盘（各自攒够次数才真正写）。
func saveLearning() {
	if err := eng.SaveFreq(); err != nil {
		logf("保存词频失败: %v", err)
	}
	if err := eng.SaveUser(); err != nil {
		logf("保存自造词失败: %v", err)
	}
}

// applyPreedit 把当前缓冲写给前台应用，并更新候选窗。
func applyPreedit(client objc.ID) {
	retainClient(client)
	buf := eng.Buffer()
	if len(buf) == 0 {
		clearMarked(client)
		hideCandidates()
		caretValid = false
		return
	}
	// 在写预编辑之前查光标：这时前台应用还没开始排版，查询不需要等它。
	if !caretValid {
		candCaret = caretRect(client)
		caretValid = true
	}
	ns := nsString(string(buf))
	// 光标停在预编辑串末尾；缓冲是纯字母，UTF-16 长度等于字节数。
	if clientCan(client, selSetMarkedText) {
		send(client, selSetMarkedText, ns, uintptr(len(buf)), 0, nsNotFound, 0)
	}
	send(ns, selRelease)
	showCandidates(client)
}

// commit 上屏一段文字，然后继续显示剩余缓冲的预编辑。
func commit(client objc.ID, text string) {
	if client == 0 {
		return
	}
	class := classOf(text)
	// 中文紧跟在英文或数字后面时，先补一个空格。
	if prevClass == prevASCII && class == prevCJK {
		text = " " + text
	}
	insertText(client, text)
	prevClass = class
	applyPreedit(client)
	if err := eng.SaveFreq(); err != nil {
		logf("保存词频失败: %v", err)
	}
}

// commitRaw 把输入缓冲原样上屏，不做任何转换。
func commitRaw(client objc.ID) bool {
	buf := eng.Buffer()
	if len(buf) == 0 {
		return false
	}
	text := string(buf)
	eng.Reset()
	caretValid = false
	hideCandidates()
	if client == 0 {
		return true
	}
	if prevClass == prevCJK {
		text = " " + text
	}
	insertText(client, text)
	prevClass = prevASCII
	return true
}

func insertText(client objc.ID, text string) {
	if !clientCan(client, selInsertText) {
		return
	}
	ns := nsString(text)
	send(client, selInsertText, ns, nsNotFound, 0)
	send(ns, selRelease)
}

func clearMarked(client objc.ID) {
	if !clientCan(client, selSetMarkedText) {
		return
	}
	ns := nsString("")
	send(client, selSetMarkedText, ns, 0, 0, nsNotFound, 0)
	send(ns, selRelease)
}

// clientCan 问客户端是否实现了某个方法。IMK 客户端理论上都要实现
// IMKTextInput，但真有不实现的应用：对它发消息会抛 NSException，
// 输入法是常驻进程，一个异常就没了。
func clientCan(client objc.ID, sel objc.SEL) bool {
	return client != 0 && send(client, selRespondsToSelector, sel) != 0
}

// showCandidates 先把候选窗放好，再让应用去排版预编辑串：候选窗的延迟因此
// 不受前台应用的排版速度影响。
func showCandidates(client objc.ID) {
	cands := eng.Candidates()
	if len(cands) == 0 {
		hideCandidates()
		return
	}
	cand.showCandidates(cands, candCaret)
}

func hideCandidates() {
	cand.hide()
}

// showHud 显示一小段模式提示（中文/英文/全角/半角），0.9 秒后自动收起。
func showHud(self objc.ID, text string) {
	cand.showText(text, caretRect(curClient))
	send(self, selPerformSelector, selHideHud, uintptr(0), 0.9)
}

// caretRect 取预编辑串第一个字符的位置。IMK 客户端用的是
// attributesForCharacterIndex:lineHeightRectangle:（Squirrel 同款），
// 不是 firstRectForCharacterRange:，后者在多数应用里返回空矩形。
func caretRect(client objc.ID) NSRect {
	// 不是所有 IMK 客户端都实现这个方法，先问一句，免得抛异常把进程带走。
	if client != 0 && send(client, selRespondsToSelector, selAttributesForChar) != 0 {
		var r NSRect
		send(client, selAttributesForChar, uintptr(0), unsafe.Pointer(&r))
		if validCaret(r) {
			return r
		}
	}
	// 实在取不到就贴着鼠标显示，至少不会跑到屏幕角落。
	p := objc.Send[NSPoint](objc.ID(objc.GetClass("NSEvent")), selMouseLocation)
	return NSRect{X: p.X, Y: p.Y - 24, W: 2, H: 16}
}

func validCaret(r NSRect) bool {
	return r.W > 0 && r.H > 0 && r.H < 200 && r.X > -10000 && r.Y > -10000
}

func retainClient(c objc.ID) {
	if c == 0 || c == curClient {
		return
	}
	if curClient != 0 {
		send(curClient, selRelease)
	}
	curClient = send(c, selRetain)
}

func dropClient() {
	if curClient != 0 {
		send(curClient, selRelease)
		curClient = 0
	}
}
