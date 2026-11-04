package main

import (
	"unicode/utf16"
	"unsafe"

	"github.com/ebitengine/purego/objc"

	"wenshan/input"
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
	sess      *input.Session
	curClient objc.ID

	// 用来区分「按住 Shift 打大写」和「轻点 Shift 切中英」。
	shiftDown bool
	shiftUsed bool

	// 光标位置在一个组合里不会变（预编辑串只会往右长），所以每次组合只查一次：
	// 刚 setMarkedText 完就查要等前台应用排版，是这条路径上最贵的一步。
	candCaret  NSRect
	caretValid bool
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
		logf("key type=%d code=%d mods=%#x mode=%v buf=%q inline=%q",
			typ, objc.Send[uintptr](event, selKeyCode), mods, sess.Mode(), sess.Buffer(), sess.Inline())
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
	keyCode := objc.Send[uintptr](event, selKeyCode)
	// 带 Command/Control/Option 的组合键一律放行，交给应用自己处理；
	// 快捷键上不该按光标前的字符补空格。
	if mods&(nsModCommand|nsModControl|nsModOption) != 0 {
		return false
	}
	// 英文直通模式：按键交给应用，补空格仍由规则层判断。
	if sess.Mode() == input.English {
		if res := sess.Passthrough(ch); res.Text != "" {
			insertText(client, res.Text)
		}
		return false
	}

	// 中文态按住 Shift 打大写字母：没有缓冲时直接上屏；
	// 正在打拼音时把已打的编码接进临时英文串，再从这字母继续。
	if raw >= 'A' && raw <= 'Z' && mods&nsModShift != 0 {
		res := sess.ShiftLetter(raw)
		if res.Consumed {
			if res.Text != "" {
				insertText(client, res.Text)
			}
			applyPreedit(client)
			return true
		}
		return false
	}
	// Shift+空格：全角/半角标点切换。临时英文里仍然按空格结束。
	if keyCode == keyCodeSpace && mods&nsModShift != 0 {
		if sess.Inline() != "" {
			res := sess.Space()
			if res.Text != "" {
				insertText(client, res.Text)
			}
			applyPreedit(client)
			return true
		}
		res := sess.ToggleFullWidth()
		if res.FullWidth {
			showHud(self, "全角")
		} else {
			showHud(self, "半角")
		}
		return true
	}

	switch keyCode {
	case keyCodeDelete:
		res := sess.Backspace()
		if res.Consumed {
			applyPreedit(client)
			return true
		}
		return false
	case keyCodeEscape:
		res := sess.Escape()
		if res.Consumed {
			applyPreedit(client)
			return true
		}
		return false
	case keyCodeReturn, keyCodeKeypadEnter:
		// 回车把缓冲里的字母原样上屏，中文状态下不用切模式就能打英文。
		res := sess.Return()
		if res.Consumed {
			insertText(client, res.Text)
			applyPreedit(client)
			return true
		}
		return false
	case keyCodeSpace:
		res := sess.Space()
		if res.Consumed {
			insertText(client, res.Text)
			applyPreedit(client)
			return true
		}
		return false
	case keyCodeTab:
		// 临时英文里 Tab 先结束英文，再交给应用切换焦点，不补空格。
		if sess.Inline() != "" {
			res := sess.CommitInline(false)
			if res.Text != "" {
				insertText(client, res.Text)
				applyPreedit(client)
			}
			return false
		}
		res := sess.Space()
		if res.Consumed {
			insertText(client, res.Text)
			applyPreedit(client)
			return true
		}
		return false
	case keyCodePageUp:
		res := sess.Page(-1)
		if res.Text != "" {
			insertText(client, res.Text)
			applyPreedit(client)
		}
		if res.Consumed {
			showCandidates(client)
			return true
		}
		return false
	case keyCodePageDown:
		res := sess.Page(1)
		if res.Text != "" {
			insertText(client, res.Text)
			applyPreedit(client)
		}
		if res.Consumed {
			showCandidates(client)
			return true
		}
		return false
	}

	if sess.Buffer() != "" && ch >= '1' && ch <= '9' {
		if res := sess.Select(int(ch - '1')); res.Consumed {
			insertText(client, res.Text)
			applyPreedit(client)
			return true
		}
	}
	// [ / ] 取当前候选的首字 / 尾字，编码消耗和正常选词一样。
	if sess.Buffer() != "" && (ch == '[' || ch == ']') {
		if res := sess.SelectChar(0, ch == ']'); res.Consumed {
			insertText(client, res.Text)
			applyPreedit(client)
			return true
		}
	}
	// = / - 翻页。候选窗开着时由输入法接管，到边界也不再当字符上屏。
	if len(sess.Candidates()) > 0 && (ch == '=' || ch == '-') {
		delta := 1
		if ch == '-' {
			delta = -1
		}
		if res := sess.Page(delta); res.Consumed {
			showCandidates(client)
			return true
		}
	}
	if ch >= 'a' && ch <= 'z' {
		if res := sess.Type(raw); res.Consumed {
			applyPreedit(client)
			return true
		}
		return false
	}
	// 标点：先把已经输入的词上屏，再插入中文标点，这个键被消费掉。
	if res := sess.Punctuate(ch); res.Consumed {
		insertText(client, res.Text)
		applyPreedit(client)
		return true
	}
	// 其他可打印字符：先把已经输入的词上屏，这个键照常交给应用。
	if res := sess.Passthrough(ch); res.Text != "" {
		insertText(client, res.Text)
		applyPreedit(client)
	}
	return false
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
	res := sess.ToggleMode()
	caretValid = false
	logf("mode: %v", res.Mode)
	if res.Text != "" && curClient != 0 {
		insertText(curClient, res.Text)
	}
	applyPreedit(curClient)
	if res.Mode == input.English {
		showHud(self, "英")
	} else {
		showHud(self, "中")
	}
}

func activateServer(self objc.ID, cmd objc.SEL, sender objc.ID) {
	sess.Reset()
	caretValid = false
	shiftDown, shiftUsed = false, false
	retainClient(sender)
	hideCandidates()
	logf("activate mode=%v", sess.Mode())
	// 英文模式下切回来要能看见状态，否则就像「打不出中文」。
	if sess.Mode() == input.English {
		showHud(self, "英")
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
	res := sess.Finish()
	if res.Text != "" && client != 0 {
		insertText(client, res.Text)
	}
	caretValid = false
	if client != 0 {
		clearMarked(client)
	}
	hideCandidates()
	dropClient()
	saveLearning()
}

// saveLearning 在输入结束时把词频和自造词落盘，有改动就写，进程被杀也不丢零头。
func saveLearning() {
	if err := sess.Save(true); err != nil {
		logf("保存词频或自造词失败: %v", err)
	}
}

// applyPreedit 把当前预编辑串写给前台应用，并更新候选窗。
func applyPreedit(client objc.ID) {
	retainClient(client)
	text := sess.Preedit()
	if text == "" {
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
	ns := nsString(text)
	// 光标停在预编辑串末尾；缓冲是纯字母，UTF-16 长度等于字节数。
	if clientCan(client, selSetMarkedText) {
		send(client, selSetMarkedText, ns, uintptr(len(text)), 0, nsNotFound, 0)
	}
	send(ns, selRelease)
	showCandidates(client)
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

// charBefore 取光标前一个字符，用来判断中英文之间要不要补空格。
// 不是所有 IMK 客户端都实现或都肯给正文（有的只给当前行，有的直接给 nil），
// 取不到就返回 false，规则层按「前面没有字符」处理。
func charBefore(client objc.ID) (rune, bool) {
	if !clientCan(client, selAttributedSubstring) || !clientCan(client, selSelectedRange) {
		return 0, false
	}
	loc := objc.Send[NSRange](client, selSelectedRange).Location
	// 组合中光标停在预编辑串末尾，要越过它看正文，否则读到的是自己打的字母。
	if clientCan(client, selMarkedRange) {
		if marked := objc.Send[NSRange](client, selMarkedRange); marked.Length > 0 && marked.Location != nsNotFound {
			loc = marked.Location
		}
	}
	if loc == 0 || loc == nsNotFound {
		return 0, false
	}
	u, ok := unitAt(client, loc-1)
	if !ok {
		return 0, false
	}
	// 低代理说明光标前是一个代理对，往前再取一格凑成整字。
	if u >= 0xdc00 && u <= 0xdfff {
		if loc < 2 {
			return 0, false
		}
		hi, ok := unitAt(client, loc-2)
		if !ok || hi < 0xd800 || hi > 0xdbff {
			return 0, false
		}
		return utf16.DecodeRune(rune(hi), rune(u)), true
	}
	if u >= 0xd800 && u <= 0xdfff {
		return 0, false
	}
	return rune(u), true
}

// unitAt 取正文里第 i 个 UTF-16 单元。
func unitAt(client objc.ID, i uintptr) (uint16, bool) {
	attr := send(client, selAttributedSubstring, i, 1)
	if attr == 0 {
		return 0, false
	}
	str := send(attr, selString)
	if str == 0 || objc.Send[uintptr](str, selLength) == 0 {
		return 0, false
	}
	return objc.Send[uint16](str, selCharacterAtIndex, uintptr(0)), true
}

// showCandidates 先把候选窗放好，再让应用去排版预编辑串：候选窗的延迟因此
// 不受前台应用的排版速度影响。
func showCandidates(client objc.ID) {
	cands := sess.Candidates()
	if len(cands) == 0 {
		hideCandidates()
		return
	}
	cand.showCandidates(cands, candCaret, sess.PageNo(), sess.HasNextPage())
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
