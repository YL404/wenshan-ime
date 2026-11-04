package main

import (
	"math"
	"strconv"

	"github.com/ebitengine/purego/objc"

	"wenshan/engine"
)

// 候选窗是一个「永远不会成为焦点」的浮动面板：NSPanel 带
// NSWindowStyleMaskNonactivatingPanel，所以点它不会抢走当前 App 的焦点。
//
// 外观：面板背景是圆角的图层，每个候选是一个独立的圆角色块，
// 选中的那个铺实心强调色、文字转白，和系统候选窗一致。这样高亮块
// 自带内边距和圆角，比给整行文字加背景色好看。同一个面板也用来显示
// 模式提示（中文/英文/全角/半角）。

var (
	selInitWithContentRect   = objc.RegisterName("initWithContentRect:styleMask:backing:defer:")
	selSetLevel              = objc.RegisterName("setLevel:")
	selSetOpaque             = objc.RegisterName("setOpaque:")
	selSetHasShadow          = objc.RegisterName("setHasShadow:")
	selSetIgnoresMouseEvents = objc.RegisterName("setIgnoresMouseEvents:")
	selSetCollectionBehavior = objc.RegisterName("setCollectionBehavior:")
	selSetBackgroundColor    = objc.RegisterName("setBackgroundColor:")
	selOrderFrontRegardless  = objc.RegisterName("orderFrontRegardless")
	selOrderOut              = objc.RegisterName("orderOut:")
	selSetFrameTopLeftPoint  = objc.RegisterName("setFrameTopLeftPoint:")
	selSetContentView        = objc.RegisterName("setContentView:")
	selSetContentSize        = objc.RegisterName("setContentSize:")
	selSetFrame              = objc.RegisterName("setFrame:")
	selSizeWithAttributes    = objc.RegisterName("sizeWithAttributes:")
	selDictWithObject        = objc.RegisterName("dictionaryWithObject:forKey:")
	selFrame                 = objc.RegisterName("frame")
	selScreens               = objc.RegisterName("screens")
	selCount                 = objc.RegisterName("count")
	selObjectAtIndex         = objc.RegisterName("objectAtIndex:")
	selVisibleFrame          = objc.RegisterName("visibleFrame")

	selInitWithFrame      = objc.RegisterName("initWithFrame:")
	selSetBezeled         = objc.RegisterName("setBezeled:")
	selSetDrawsBackground = objc.RegisterName("setDrawsBackground:")
	selSetEditable        = objc.RegisterName("setEditable:")
	selSetSelectable      = objc.RegisterName("setSelectable:")
	selSetStringValue     = objc.RegisterName("setStringValue:")
	selSetTextColor       = objc.RegisterName("setTextColor:")
	selSetFont            = objc.RegisterName("setFont:")
	selSetSingleLine      = objc.RegisterName("setUsesSingleLineMode:")
	selSetLineBreak       = objc.RegisterName("setLineBreakMode:")
	selSetAlignment       = objc.RegisterName("setAlignment:")
	selSetHidden          = objc.RegisterName("setHidden:")
	selAddSubview         = objc.RegisterName("addSubview:")

	selSetWantsLayer    = objc.RegisterName("setWantsLayer:")
	selLayer            = objc.RegisterName("layer")
	selSetCornerRadius  = objc.RegisterName("setCornerRadius:")
	selSetMasksToBounds = objc.RegisterName("setMasksToBounds:")
	selCGColor          = objc.RegisterName("CGColor")

	selColorWithCalibratedWhite = objc.RegisterName("colorWithCalibratedWhite:alpha:")
	selControlAccentColor       = objc.RegisterName("controlAccentColor")
	selSelectedContentBG        = objc.RegisterName("selectedContentBackgroundColor")
	selAlternateSelectedText    = objc.RegisterName("alternateSelectedControlTextColor")
	selClearColor               = objc.RegisterName("clearColor")
	selSystemFontOfSize         = objc.RegisterName("systemFontOfSize:")
	selArrayWithCapacity        = objc.RegisterName("arrayWithCapacity:")
	selAddObject                = objc.RegisterName("addObject:")
	selEffectiveAppearance      = objc.RegisterName("effectiveAppearance")
	selBestMatch                = objc.RegisterName("bestMatchFromAppearancesWithNames:")
	selIsEqualToString          = objc.RegisterName("isEqualToString:")
)

const (
	candFontSize  = 14.0
	candLabelSize = 10.0
	candPadX      = 7.0  // 色块内左右留白
	candPadY      = 3.0  // 色块内上下留白
	candGap       = 6.0  // 候选之间的间隔
	candOuter     = 6.0  // 面板四周留白
	candRadius    = 8.0  // 面板圆角
	chipRadius    = 5.0  // 候选色块圆角
	candLabelSlot = 11.0 // 序号固定槽位
	candLabelGap  = 4.0  // 序号与候选之间的间隔
	maxChips      = 9
)

// NSSize 和 NSPoint 的内存布局一样，都是两个 CGFloat。
type NSSize = NSPoint

type candWindow struct {
	panel    objc.ID
	content  objc.ID
	bg       [maxChips]objc.ID // 圆角色块
	labels   [maxChips]objc.ID // 色块上的序号
	chips    [maxChips]objc.ID // 色块上的候选文字
	pageHint objc.ID           // 候选条右端的页码 / 到底提示

	// 下面这些对象要跨事件循环一直用，必须自己 retain：
	// NSFont/NSColor/NSDictionary 的构造方法返回的都是自动释放对象，
	// 不 retain 的话事件循环一结束就成了野指针。
	font       objc.ID
	labelFont  objc.ID // 序号字体，比候选小一号
	dim        objc.ID // 未选中文字：深色面板配浅灰字
	dimLt      objc.ID // 未选中文字：浅色面板配深灰字
	labelDim   objc.ID // 未选中序号：比候选文字再弱一档
	labelDimLt objc.ID

	// 量文字宽度用的属性字典，只建一次。
	attrs      objc.ID
	labelAttrs objc.ID

	// NSColor.CGColor 返回的只是借用，由 autorelease pool 管着，
	// 事件循环一排水就成野指针，所以也要像 NSColor 一样显式 retain。
	clearColor objc.ID

	panelBGDark objc.ID // CGColor：深色面板底
	panelBGLt   objc.ID // CGColor：浅色面板底
	clearBG     objc.ID // CGColor

	// 查系统当前深浅用的缓存：候选外观名数组 + 深色名。
	appearances objc.ID
	darkName    objc.ID

	shown bool
	hud   bool
}

var cand candWindow

// ensure 懒建面板和色块。失败时返回 false，输入法退化成「只有行内预编辑」。
func (c *candWindow) ensure() bool {
	if c.panel != 0 {
		return true
	}
	panel := send(objc.ID(objc.GetClass("NSPanel")), selAlloc)
	panel = send(panel, selInitWithContentRect, NSRect{W: 10, H: 10},
		uintptr(nsWindowStyleNonactivating), uintptr(nsBackingStoreBuffered), false)
	if panel == 0 {
		logf("候选窗: NSPanel 创建失败")
		return false
	}
	send(panel, selSetLevel, uintptr(nsPopUpMenuWindowLevel))
	send(panel, selSetOpaque, false)
	send(panel, selSetHasShadow, true)
	send(panel, selSetIgnoresMouseEvents, true)
	send(panel, selSetCollectionBehavior, uintptr(nsCollectionCanJoinAllSpaces|nsCollectionFullScreenAux))

	c.font = keep(send(objc.ID(objc.GetClass("NSFont")), selSystemFontOfSize, candFontSize))
	c.labelFont = keep(send(objc.ID(objc.GetClass("NSFont")), selSystemFontOfSize, candLabelSize))
	// 未选中文字备深浅两套：深色面板配浅灰字，浅色面板配深灰字。
	c.dim = keep(send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.82, 1.0))
	c.dimLt = keep(send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.15, 1.0))
	// 序号再弱一档：仍看得清，但不会和候选正文抢注意力。
	c.labelDim = keep(send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.62, 1.0))
	c.labelDimLt = keep(send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.42, 1.0))
	// 面板底也备深浅两套：深色是 HUD 风，浅色接近系统候选条的白底。
	darkPanel := send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.12, 0.97)
	lightPanel := send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.98, 0.97)
	// 高亮底用的是动态色，CGColor 一取就定死，所以每次绘制现取，见 setSelected。
	c.clearColor = keep(send(objc.ID(objc.GetClass("NSColor")), selClearColor))
	c.panelBGDark = keep(send(darkPanel, selCGColor))
	c.panelBGLt = keep(send(lightPanel, selCGColor))
	c.clearBG = keep(send(c.clearColor, selCGColor))
	// 外观名数组缓存下来，绘制时查系统当前深浅（「自动」外观也能拿到当时的实际值）。
	c.darkName = keep(nsString("NSAppearanceNameDarkAqua"))
	aqua := nsString("NSAppearanceNameAqua")
	names := send(objc.ID(objc.GetClass("NSMutableArray")), selArrayWithCapacity, 2)
	send(names, selAddObject, aqua)
	send(names, selAddObject, c.darkName)
	send(aqua, selRelease)
	c.appearances = keep(names)
	// 圆角只裁内容图层自己，裁不掉窗口的背景色；窗口默认背景接近白色，
	// 会从四个圆角缺口露出来，所以窗口背景必须设成透明。
	send(panel, selSetBackgroundColor, c.clearColor)
	// sizeWithAttributes: 直接量文字本身，避免把 NSTextField 的 cell 边距也算进色块。
	fontKey := nsString("NSFont")
	c.attrs = keep(send(objc.ID(objc.GetClass("NSDictionary")), selDictWithObject, c.font, fontKey))
	c.labelAttrs = keep(send(objc.ID(objc.GetClass("NSDictionary")), selDictWithObject, c.labelFont, fontKey))
	send(fontKey, selRelease)

	// 内容视图做成圆角图层，面板本身透明。
	content := send(send(objc.ID(objc.GetClass("NSView")), selAlloc), selInitWithFrame, NSRect{W: 10, H: 10})
	send(content, selSetWantsLayer, true)
	layer := send(content, selLayer)
	send(layer, selSetCornerRadius, candRadius)
	send(layer, selSetMasksToBounds, true)
	send(layer, selSetBackgroundColor, c.panelBGDark)
	send(panel, selSetContentView, content)

	for i := range c.chips {
		// 底色、序号、候选分成三个视图：色块负责圆角和内边距，两个文字视图
		// 的尺寸都等于实测文字大小，这样才能真正居中（NSTextField 的 cell
		// 自带内边距，单靠 setAlignment: 会偏）。
		bg := send(send(objc.ID(objc.GetClass("NSView")), selAlloc), selInitWithFrame, NSRect{W: 10, H: 10})
		send(bg, selSetWantsLayer, true)
		bgLayer := send(bg, selLayer)
		send(bgLayer, selSetCornerRadius, chipRadius)
		send(bg, selSetHidden, true)
		send(content, selAddSubview, bg)

		// 序号在固定宽度的槽位里居中，候选正文从槽位右侧开始。
		label := send(send(objc.ID(objc.GetClass("NSTextField")), selAlloc), selInitWithFrame, NSRect{W: 10, H: 10})
		send(label, selSetBezeled, false)
		send(label, selSetDrawsBackground, false)
		send(label, selSetEditable, false)
		send(label, selSetSelectable, false)
		send(label, selSetFont, c.labelFont)
		send(label, selSetSingleLine, true)
		send(label, selSetLineBreak, uintptr(2)) // NSLineBreakByClipping
		send(label, selSetAlignment, uintptr(2)) // NSTextAlignmentCenter
		send(label, selSetHidden, true)
		send(content, selAddSubview, label)

		chip := send(send(objc.ID(objc.GetClass("NSTextField")), selAlloc), selInitWithFrame, NSRect{W: 10, H: 10})
		send(chip, selSetBezeled, false)
		send(chip, selSetDrawsBackground, false)
		send(chip, selSetEditable, false)
		send(chip, selSetSelectable, false)
		send(chip, selSetFont, c.font)
		// 不加这两行，宽度刚好卡在测量值时文字会折行，第二行被裁掉。
		send(chip, selSetSingleLine, true)
		send(chip, selSetLineBreak, uintptr(2)) // NSLineBreakByClipping
		send(chip, selSetHidden, true)
		send(content, selAddSubview, chip)
		c.bg[i], c.labels[i], c.chips[i] = bg, label, chip
	}

	// 页码 / 到底提示是一个独立的小字视图，放在候选条右端，不占 9 个候选槽。
	hint := send(send(objc.ID(objc.GetClass("NSTextField")), selAlloc), selInitWithFrame, NSRect{W: 10, H: 10})
	send(hint, selSetBezeled, false)
	send(hint, selSetDrawsBackground, false)
	send(hint, selSetEditable, false)
	send(hint, selSetSelectable, false)
	send(hint, selSetFont, c.labelFont)
	send(hint, selSetSingleLine, true)
	send(hint, selSetLineBreak, uintptr(2))
	send(hint, selSetHidden, true)
	send(content, selAddSubview, hint)
	c.pageHint = hint

	c.panel, c.content = panel, content
	return true
}

// showCandidates 显示候选列表，selected 指定的那个填蓝色。pageNo /
// hasNext 用来在右端标出页码和「还有更多」，翻到末页时不再静默无提示：
// 有箭头表示还能往下翻，没箭头就是到底了。
func (c *candWindow) showCandidates(cands []engine.Candidate, caret NSRect, pageNo int, hasNext bool) {
	if !c.ensure() {
		return
	}
	c.hud = false
	hint := ""
	if pageNo > 0 || hasNext {
		hint = strconv.Itoa(pageNo + 1)
		if hasNext {
			hint += " ›"
		}
	}
	c.layout(candidateItems(cands), 0, caret, hint)
}

// candidateItem 是一个候选的两个显示部分：序号和正文分开排版。
type candidateItem struct {
	label string
	text  string
}

// candidateItems 拆出序号和候选正文，序号只负责提示按哪个数字选。
func candidateItems(cands []engine.Candidate) []candidateItem {
	items := make([]candidateItem, len(cands))
	for i, c := range cands {
		items[i] = candidateItem{label: strconv.Itoa(i+1) + ".", text: c.Text}
	}
	return items
}

// showText 显示一小段模式提示。
func (c *candWindow) showText(text string, caret NSRect) {
	if !c.ensure() {
		return
	}
	c.hud = true
	c.layout([]candidateItem{{text: text}}, -1, caret, "")
}

// lightAppearance 判断系统当前是不是浅色外观。按 NSApp.effectiveAppearance
// 解析，「自动」外观也能拿到当时的实际深浅；查不到（NSApp 未起等）返回
// false，维持原来的深色 HUD。
func (c *candWindow) lightAppearance() bool {
	app := send(objc.ID(objc.GetClass("NSApplication")), selSharedApplication)
	if app == 0 || c.appearances == 0 {
		return false
	}
	eff := send(app, selEffectiveAppearance)
	if eff == 0 {
		return false
	}
	best := send(eff, selBestMatch, c.appearances)
	return best != 0 && send(best, selIsEqualToString, c.darkName) == 0
}

// layout 依次排好色块，再按内容调整面板大小和位置。hint 非空时在右端
// 追加页码 / 到底提示。
func (c *candWindow) layout(items []candidateItem, selected int, caret NSRect, hint string) {
	// 每次绘制都按系统当前深浅选一遍配色：面板开着时用户切深浅模式，
	// 下一次出候选就跟着变了，不用额外监听通知。
	light := c.lightAppearance()
	panelBG, dimText, labelDim := c.panelBGDark, c.dim, c.labelDim
	if light {
		panelBG, dimText, labelDim = c.panelBGLt, c.dimLt, c.labelDimLt
	}
	send(send(c.content, selLayer), selSetBackgroundColor, panelBG)

	x, maxH := candOuter, 0.0
	for i := range c.chips {
		bg, label, chip := c.bg[i], c.labels[i], c.chips[i]
		if i >= len(items) {
			send(bg, selSetHidden, true)
			send(label, selSetHidden, true)
			send(chip, selSetHidden, true)
			continue
		}
		send(bg, selSetHidden, false)
		send(chip, selSetHidden, false)

		item := items[i]
		hasLabel := item.label != ""
		send(label, selSetHidden, !hasLabel)

		ns := nsString(item.text)
		send(chip, selSetStringValue, ns)
		size := objc.Send[NSSize](ns, selSizeWithAttributes, c.attrs)
		send(ns, selRelease)
		if !(size.X > 0) || !(size.Y > 0) {
			// 量不出来就退回按字数估，绝不把 NaN 传给 setFrame。
			size = NSSize{X: float64(utf16Len(item.text)) * candFontSize * 0.9, Y: candFontSize * 1.3}
		}

		// 序号单独量高度，然后在固定槽位里垂直居中；槽宽不随数字变化。
		labelHeight := candLabelSize * 1.3
		if hasLabel {
			lns := nsString(item.label)
			send(label, selSetStringValue, lns)
			lsize := objc.Send[NSSize](lns, selSizeWithAttributes, c.labelAttrs)
			send(lns, selRelease)
			if lsize.Y > 0 {
				labelHeight = math.Ceil(lsize.Y)
			}
		}

		bgLayer := send(bg, selLayer)
		if i == selected {
			c.setSelected(bgLayer, chip, label, hasLabel)
		} else {
			send(chip, selSetTextColor, dimText)
			if hasLabel {
				send(label, selSetTextColor, labelDim)
			}
			send(bgLayer, selSetBackgroundColor, c.clearBG)
		}

		// 色块 = 序号槽 + 间距 + 正文 + 两侧内边距；两个文字视图的尺寸
		// 都是实测大小，放在色块内计算好的位置上，不依赖 cell 的对齐。
		tw, th := math.Ceil(size.X)+2, math.Ceil(size.Y)
		innerH := math.Max(th, labelHeight)
		w := tw + 2*candPadX
		if hasLabel {
			w += candLabelSlot + candLabelGap
		}
		h := innerH + 2*candPadY
		xr := math.Round(x)
		textX := xr + candPadX
		send(bg, selSetFrame, NSRect{X: xr, Y: candOuter, W: w, H: h})
		if hasLabel {
			send(label, selSetFrame, NSRect{
				X: textX,
				Y: candOuter + candPadY + (innerH-labelHeight)/2,
				W: candLabelSlot,
				H: labelHeight,
			})
			textX += candLabelSlot + candLabelGap
		}
		send(chip, selSetFrame, NSRect{
			X: textX,
			Y: candOuter + candPadY + (innerH-th)/2,
			W: tw,
			H: th,
		})
		x += w + candGap
		maxH = max(maxH, h)
	}

	// 页码 / 到底提示单独一个视图，接在最后一个候选右侧，不占候选槽位。
	if c.pageHint != 0 {
		if hint == "" {
			send(c.pageHint, selSetHidden, true)
		} else {
			send(c.pageHint, selSetHidden, false)
			send(c.pageHint, selSetTextColor, labelDim)
			ns := nsString(hint)
			send(c.pageHint, selSetStringValue, ns)
			hs := objc.Send[NSSize](ns, selSizeWithAttributes, c.labelAttrs)
			send(ns, selRelease)
			hw := math.Ceil(hs.X) + 4
			hh := math.Ceil(hs.Y)
			send(c.pageHint, selSetFrame, NSRect{
				X: math.Round(x), Y: candOuter + (maxH-hh)/2, W: hw, H: hh,
			})
			x += hw + candGap
		}
	}

	width := x - candGap + candOuter
	height := maxH + 2*candOuter
	send(c.panel, selSetContentSize, NSSize{X: width, Y: height})

	// 光标下方放不下就翻到上方。
	top := caret.Y - 4
	if top-height < 0 {
		top = caret.Y + caret.H + height + 4
	}
	// 贴着屏幕边缘时收回来，别让候选条跑到屏幕外面。
	point := NSPoint{X: caret.X, Y: top}
	if screen := screenFrame(NSPoint{X: caret.X, Y: caret.Y}); screen.W > 0 {
		if point.X+width > screen.X+screen.W {
			point.X = screen.X + screen.W - width
		}
		if point.X < screen.X {
			point.X = screen.X
		}
		if point.Y > screen.Y+screen.H {
			point.Y = screen.Y + screen.H
		}
		if point.Y-height < screen.Y {
			point.Y = screen.Y + height
		}
	}
	send(c.panel, selSetFrameTopLeftPoint, point)
	if !c.shown {
		send(c.panel, selOrderFrontRegardless)
		c.shown = true
	}
}

// setSelected 把选中的色块铺成实心强调色、文字换成白色。用的是一对系统
// 选中态语义色：强调色改成黄、灰时这对色会一起变，白字始终压得住底。
// 两个都是动态色，CGColor 一取就定死，所以每次绘制现取。
func (c *candWindow) setSelected(layer, chip, label objc.ID, hasLabel bool) {
	fill := send(objc.ID(objc.GetClass("NSColor")), selSelectedContentBG)
	text := send(objc.ID(objc.GetClass("NSColor")), selAlternateSelectedText)
	if fill == 0 {
		fill = send(objc.ID(objc.GetClass("NSColor")), selControlAccentColor)
	}
	if text == 0 {
		text = send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 1.0, 1.0)
	}
	send(chip, selSetTextColor, text)
	if hasLabel {
		send(label, selSetTextColor, text)
	}
	if cg := send(fill, selCGColor); cg != 0 {
		send(layer, selSetBackgroundColor, cg)
	}
}

// keep 把自动释放对象变成常驻对象：这些缓存要跨事件循环用，不能让它被回收。
func keep(obj objc.ID) objc.ID {
	if obj != 0 {
		send(obj, selRetain)
	}
	return obj
}

// screenFrame 返回包含指定点的屏幕的可用区域（已扣掉菜单栏和 Dock）。
// 不能直接用 mainScreen：多屏时它可能是另一块屏，按它收边会把窗口推走。
func screenFrame(at NSPoint) NSRect {
	screens := send(objc.ID(objc.GetClass("NSScreen")), selScreens)
	if screens == 0 {
		return NSRect{}
	}
	n := objc.Send[uintptr](screens, selCount)
	for i := uintptr(0); i < n; i++ {
		screen := send(screens, selObjectAtIndex, i)
		f := objc.Send[NSRect](screen, selFrame)
		if at.X >= f.X && at.X <= f.X+f.W && at.Y >= f.Y && at.Y <= f.Y+f.H {
			return objc.Send[NSRect](screen, selVisibleFrame)
		}
	}
	return NSRect{}
}

// utf16Len 是字符串的字符数，估宽度的兜底用。
func utf16Len(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}

// hide 收起面板。
func (c *candWindow) hide() {
	if c.panel == 0 || !c.shown {
		return
	}
	send(c.panel, selOrderOut, 0)
	c.shown = false
	c.hud = false
}

// hideHud 只收模式提示；候选列表正显示时不动它。
func (c *candWindow) hideHud() {
	if c.hud {
		c.hide()
	}
}
