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
// 选中的那个铺一层强调色淡底，再带一点投影浮起来。这样高亮块自带
// 内边距和圆角，比给整行文字加背景色好看。同一个面板也用来显示
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

	selSetShadow       = objc.RegisterName("setShadow:")
	selInit            = objc.RegisterName("init")
	selSetShadowOffset = objc.RegisterName("setShadowOffset:")
	selSetShadowBlur   = objc.RegisterName("setShadowBlurRadius:")
	selSetShadowColor  = objc.RegisterName("setShadowColor:")

	selColorWithCalibratedWhite = objc.RegisterName("colorWithCalibratedWhite:alpha:")
	selColorWithCalibratedRed   = objc.RegisterName("colorWithCalibratedRed:green:blue:alpha:")
	selBlendedColor             = objc.RegisterName("blendedColorWithFraction:ofColor:")
	selControlAccentColor       = objc.RegisterName("controlAccentColor")
	selLabelColor               = objc.RegisterName("labelColor")
	selClearColor               = objc.RegisterName("clearColor")
	selSystemFontOfSize         = objc.RegisterName("systemFontOfSize:")
	selArrayWithCapacity        = objc.RegisterName("arrayWithCapacity:")
	selAddObject                = objc.RegisterName("addObject:")
	selEffectiveAppearance      = objc.RegisterName("effectiveAppearance")
	selBestMatch                = objc.RegisterName("bestMatchFromAppearancesWithNames:")
	selIsEqualToString          = objc.RegisterName("isEqualToString:")
)

const (
	candFontSize = 14.0
	candPadX     = 7.0 // 色块内左右留白
	candPadY     = 3.0 // 色块内上下留白
	candGap      = 6.0 // 候选之间的间隔
	candOuter    = 6.0 // 面板四周留白
	candRadius   = 8.0 // 面板圆角
	chipRadius   = 5.0 // 候选色块圆角
	maxChips     = 9
)

// NSSize 和 NSPoint 的内存布局一样，都是两个 CGFloat。
type NSSize = NSPoint

type candWindow struct {
	panel   objc.ID
	content objc.ID
	bg      [maxChips]objc.ID // 圆角色块
	chips   [maxChips]objc.ID // 色块上的文字

	// 下面这些对象要跨事件循环一直用，必须自己 retain：
	// NSFont/NSColor/NSDictionary 的构造方法返回的都是自动释放对象，
	// 不 retain 的话事件循环一结束就成了野指针。
	font  objc.ID
	label objc.ID // 选中文字：跟随系统标签色，深浅外观自动变
	dim   objc.ID // 未选中文字：深色面板配浅灰字
	dimLt objc.ID // 未选中文字：浅色面板配深灰字

	// 量文字宽度用的属性字典，只建一次。
	attrs objc.ID

	// NSColor.CGColor 返回的只是借用，由 autorelease pool 管着，
	// 事件循环一排水就成野指针，所以也要像 NSColor 一样显式 retain。
	clearColor objc.ID

	panelBGDark objc.ID // CGColor：深色面板底
	panelBGLt   objc.ID // CGColor：浅色面板底
	panelDark   objc.ID // NSColor：深色面板底，和强调色混淡底用
	panelLt     objc.ID // NSColor：浅色面板底
	clearBG     objc.ID // CGColor
	shadow      objc.ID // NSShadow：高亮块的投影

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
	// 选中文字用系统标签色：浅色外观是近黑，深色外观是白，淡蓝底上都够清楚。
	c.label = keep(send(objc.ID(objc.GetClass("NSColor")), selLabelColor))
	// 未选中文字备深浅两套：深色面板配浅灰字，浅色面板配深灰字。
	c.dim = keep(send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.82, 1.0))
	c.dimLt = keep(send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.15, 1.0))
	// 面板底也备深浅两套：深色是 HUD 风，浅色接近系统候选条的白底。
	darkPanel := send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.12, 0.97)
	lightPanel := send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.98, 0.97)
	// 高亮底不能用缓存的 CGColor：强调色和深浅一变，旧值就定死了。
	// 每次绘制时按当前外观现取，见 setTint。
	c.clearColor = keep(send(objc.ID(objc.GetClass("NSColor")), selClearColor))
	c.panelDark = keep(darkPanel)
	c.panelLt = keep(lightPanel)
	c.panelBGDark = keep(send(c.panelDark, selCGColor))
	c.panelBGLt = keep(send(c.panelLt, selCGColor))
	c.clearBG = keep(send(c.clearColor, selCGColor))
	// 高亮块的投影走 NSView.shadow：直接改 backing layer 的 shadowOpacity，
	// 会在 addSubview 时被 AppKit 清零；这个对象反而留得住。
	shadow := send(send(objc.ID(objc.GetClass("NSShadow")), selAlloc), selInit)
	send(shadow, selSetShadowOffset, NSSize{X: 0, Y: -1.5})
	send(shadow, selSetShadowBlur, 3.0)
	send(shadow, selSetShadowColor, send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedWhite, 0.0, 0.22))
	// alloc/init 已经持有一份，不用再 keep。
	c.shadow = shadow
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
		// 底色和文字分成两个视图：色块负责圆角和内边距，文字视图的尺寸
		// 就等于实测文字大小，这样才能真正居中（NSTextField 的 cell 自带
		// 内边距，单靠 setAlignment: 会偏）。
		bg := send(send(objc.ID(objc.GetClass("NSView")), selAlloc), selInitWithFrame, NSRect{W: 10, H: 10})
		send(bg, selSetWantsLayer, true)
		bgLayer := send(bg, selLayer)
		send(bgLayer, selSetCornerRadius, chipRadius)
		send(bg, selSetHidden, true)
		send(content, selAddSubview, bg)
		// 投影要在 addSubview 之后挂：AppKit 会在挂进视图树时重置
		// backing layer 的投影属性，NSView.shadow 才是它认的入口。
		send(bg, selSetShadow, c.shadow)

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
		c.bg[i], c.chips[i] = bg, chip
	}

	c.panel, c.content = panel, content
	return true
}

// showCandidates 显示候选列表，selected 指定的那个填蓝色。
func (c *candWindow) showCandidates(cands []engine.Candidate, caret NSRect) {
	if !c.ensure() {
		return
	}
	c.hud = false
	c.layout(candidateItems(cands), 0, caret)
}

// candidateItems 把候选拼成「1.你好」「2.你」这样的显示文本。
func candidateItems(cands []engine.Candidate) []string {
	items := make([]string, len(cands))
	for i, c := range cands {
		items[i] = strconv.Itoa(i+1) + "." + c.Text
	}
	return items
}

// showText 显示一小段模式提示。
func (c *candWindow) showText(text string, caret NSRect) {
	if !c.ensure() {
		return
	}
	c.hud = true
	c.layout([]string{text}, -1, caret)
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

// layout 依次排好色块，再按内容调整面板大小和位置。
func (c *candWindow) layout(items []string, selected int, caret NSRect) {
	// 每次绘制都按系统当前深浅选一遍配色：面板开着时用户切深浅模式，
	// 下一次出候选就跟着变了，不用额外监听通知。
	light := c.lightAppearance()
	panelBG, dimText := c.panelBGDark, c.dim
	if light {
		panelBG, dimText = c.panelBGLt, c.dimLt
	}
	send(send(c.content, selLayer), selSetBackgroundColor, panelBG)

	x, maxH := candOuter, 0.0
	for i := range c.chips {
		bg, chip := c.bg[i], c.chips[i]
		if i >= len(items) {
			send(bg, selSetHidden, true)
			send(chip, selSetHidden, true)
			continue
		}
		send(bg, selSetHidden, false)
		send(chip, selSetHidden, false)

		ns := nsString(items[i])
		send(chip, selSetStringValue, ns)
		size := objc.Send[NSSize](ns, selSizeWithAttributes, c.attrs)
		send(ns, selRelease)
		if !(size.X > 0) || !(size.Y > 0) {
			// 量不出来就退回按字数估，绝不把 NaN 传给 setFrame。
			size = NSSize{X: float64(utf16Len(items[i])) * candFontSize * 0.9, Y: candFontSize * 1.3}
		}

		bgLayer := send(bg, selLayer)
		if i == selected {
			send(chip, selSetTextColor, c.label)
			c.setTint(bgLayer, !light)
		} else {
			send(chip, selSetTextColor, dimText)
			send(bgLayer, selSetBackgroundColor, c.clearBG)
		}

		// 色块 = 文字 + 两侧内边距；文字视图的尺寸就是实测文字大小，
		// 放在色块内边距的位置上，这样文字必然是居中的（不依赖 cell 的对齐）。
		tw, th := math.Ceil(size.X)+2, math.Ceil(size.Y)
		w, h := tw+2*candPadX, th+2*candPadY
		xr := math.Round(x)
		send(bg, selSetFrame, NSRect{X: xr, Y: candOuter, W: w, H: h})
		send(chip, selSetFrame, NSRect{X: xr + candPadX, Y: candOuter + candPadY, W: tw, H: th})
		x += w + candGap
		maxH = max(maxH, h)
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

// setTint 给选中的色块铺一层强调色淡底。强调色是动态色，它的 CGColor
// 一取就定死，所以每次绘制现取；系统换强调色或深浅外观后，下一帧就跟上。
// 和面板底色混成不透明色：半透明底会让背后的投影透出来，色块发脏。
// 深色面板上多掺一点，不然淡蓝底几乎看不出来。
func (c *candWindow) setTint(layer objc.ID, dark bool) {
	accent := send(objc.ID(objc.GetClass("NSColor")), selControlAccentColor)
	if accent == 0 {
		accent = send(objc.ID(objc.GetClass("NSColor")), selColorWithCalibratedRed, 0.20, 0.45, 0.85, 1.0)
	}
	panel, alpha := c.panelLt, 0.22
	if dark {
		panel, alpha = c.panelDark, 0.30
	}
	if cg := send(send(panel, selBlendedColor, alpha, accent), selCGColor); cg != 0 {
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
