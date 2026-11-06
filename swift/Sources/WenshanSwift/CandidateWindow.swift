import AppKit
import WenshanCore

/// 候选窗是一个「永远不会成为焦点」的浮动面板：NSPanel 带
/// .nonactivatingPanel，所以点它不会抢走当前 App 的焦点。
///
/// 外观：面板底是 .clear 样式的液态玻璃（NSGlassEffectView），每个候选是一个
/// 独立的圆角色块，选中的那个是一块强调色 tint 的玻璃。文字统一用白色，序号
/// 和箭头用半透明白；玻璃再压一层 30% 的黑，文字再带一点阴影，白字落在白色
/// 页面上也有对比度。
/// 同一个面板也用来显示模式提示（中文/英文/全角/半角）。
@MainActor
final class CandidateWindow {
    private struct Chip {
        let label: NSTextField
        let text: NSTextField
    }

    private let panel: NSPanel
    private let glass: NSGlassEffectView
    private let content: NSView
    private let selectionGlass: NSGlassEffectView
    private let moreHint: NSImageView
    private var chips: [Chip] = []

    private let font = NSFont.systemFont(ofSize: 14)
    private let labelFont = NSFont.systemFont(ofSize: 10)
    private var shown = false
    private var isHUD = false

    private let candPadX = 5.0  // 色块内左右留白
    private let candPadY = 3.0  // 色块内上下留白
    private let candGap = 2.0  // 候选之间的间隔
    private let candOuter = 6.0  // 面板四周留白
    private let chipRadius = 5.0  // 候选色块圆角
    /// 面板圆角取色块圆角加四周留白，内外圆角同心，液态玻璃的边缘才和色块平行。
    private var candRadius: Double { chipRadius + candOuter }
    private let candLabelSlot = 11.0  // 序号固定槽位
    private let candLabelGap = 4.0  // 序号与候选之间的间隔
    private let maxChips = 9

    /// 文字阴影只求在白底上多一层轮廓，颜色和模糊都压得很轻。
    private let textShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1.5
        return shadow
    }()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false)
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let selection = NSGlassEffectView(frame: .zero)
        // .regular 会把 tint 洗成灰色，只有 .clear 能真正带出强调色。
        selection.style = .clear
        selection.cornerRadius = chipRadius
        selection.isHidden = true
        let hint = NSImageView(frame: .zero)
        hint.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: "还有下一页")
        hint.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        hint.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        self.panel = panel
        self.glass = glass
        self.content = content
        self.selectionGlass = selection
        self.moreHint = hint

        panel.level = .popUpMenu
        panel.isOpaque = false
        // 玻璃自己画边缘高光和投影，窗口阴影再叠一层会发灰。
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 窗口默认背景接近白色，会从玻璃的圆角缺口露出来，必须设成透明。
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        glass.style = .clear
        // .clear 几乎全透，白字落到白色页面上就没了。压一层 30% 的黑兜底，
        // 深浅背景都能看清，玻璃仍保持透明。
        glass.tintColor = NSColor.black.withAlphaComponent(0.3)
        glass.cornerRadius = candRadius
        glass.contentView = content
        panel.contentView = glass

        // 选中玻璃放在所有文字下面，随选中的候选移动；未选中时不显示。
        content.addSubview(selection)

        for _ in 0..<maxChips {
            // 序号、候选两个文字视图的尺寸都等于实测文字大小，这样才能真正居中。
            let label = makeField(font: labelFont, alignment: .center)
            label.isHidden = true
            content.addSubview(label)

            let text = makeField(font: font, alignment: .left)
            text.isHidden = true
            content.addSubview(text)

            chips.append(Chip(label: label, text: text))
        }

        // 「还有下一页」箭头是一个独立的图标视图，放在候选条右端，不占候选槽。
        hint.isHidden = true
        content.addSubview(hint)
    }

    /// 显示候选列表，第 1 个填强调色。hasNext 为真时在右端画一个箭头，
    /// 表示还有下一页；末页不画。
    func show(_ cands: [Candidate], caret: NSRect, hasNext: Bool) {
        isHUD = false
        let items = cands.enumerated().map { (label: "\($0.offset + 1).", text: $0.element.text) }
        layout(items: items, selected: 0, caret: caret, hasNext: hasNext)
    }

    /// 显示一小段模式提示。
    func showText(_ text: String, caret: NSRect) {
        isHUD = true
        layout(items: [(label: "", text: text)], selected: -1, caret: caret, hasNext: false)
    }

    func hide() {
        guard shown else { return }
        panel.orderOut(nil)
        shown = false
        isHUD = false
    }

    /// 只收模式提示；候选列表正显示时不动它。
    func hideHUD() {
        if isHUD { hide() }
    }

    private func layout(
        items: [(label: String, text: String)], selected: Int, caret: NSRect, hasNext: Bool
    ) {
        // 选中色块用的系统强调色是 CGColor，要在面板当前的外观下取值，
        // 所以整段布局放在这个外观里做。
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            layoutInAppearance(items: items, selected: selected, caret: caret, hasNext: hasNext)
        }
    }

    private func layoutInAppearance(
        items: [(label: String, text: String)], selected: Int, caret: NSRect, hasNext: Bool
    ) {
        let dimText = NSColor.white
        let labelDim = NSColor.white.withAlphaComponent(0.6)
        var x = candOuter
        var maxH = 0.0
        selectionGlass.isHidden = true
        for i in 0..<maxChips {
            let chip = chips[i]
            guard i < items.count else {
                chip.label.isHidden = true
                chip.text.isHidden = true
                continue
            }
            chip.text.isHidden = false

            let item = items[i]
            let hasLabel = !item.label.isEmpty
            chip.label.isHidden = !hasLabel

            setText(chip.text, item.text, font: font, color: dimText)
            var size = (item.text as NSString).size(withAttributes: [.font: font])
            if !(size.width > 0) || !(size.height > 0) {
                // 量不出来就退回按字数估，绝不把 NaN 传给 setFrame。
                size = NSSize(width: Double(item.text.count) * 14 * 0.9, height: 14 * 1.3)
            }

            // 序号单独量高度，然后在固定槽位里垂直居中；槽宽不随数字变化。
            var labelHeight = 10.0 * 1.3
            if hasLabel {
                setText(chip.label, item.label, font: labelFont, color: labelDim)
                let ls = (item.label as NSString).size(withAttributes: [.font: labelFont])
                if ls.height > 0 { labelHeight = ceil(ls.height) }
            }

            if i == selected {
                setSelected(chip, hasLabel: hasLabel)
            }

            // 色块 = 序号槽 + 间距 + 正文 + 两侧内边距；两个文字视图的尺寸
            // 都是实测大小，放在色块内计算好的位置上。
            let tw = ceil(size.width) + 2
            let th = ceil(size.height)
            let innerH = max(th, labelHeight)
            var w = tw + 2 * candPadX
            if hasLabel { w += candLabelSlot + candLabelGap }
            let h = innerH + 2 * candPadY
            let xr = x.rounded()
            var textX = xr + candPadX
            let chipFrame = NSRect(x: xr, y: candOuter, width: w, height: h)
            if i == selected {
                selectionGlass.frame = chipFrame
                selectionGlass.tintColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.8)
                selectionGlass.isHidden = false
            }
            if hasLabel {
                chip.label.frame = NSRect(
                    x: textX,
                    y: candOuter + candPadY + (innerH - labelHeight) / 2,
                    width: candLabelSlot,
                    height: labelHeight)
                textX += candLabelSlot + candLabelGap
            }
            chip.text.frame = NSRect(
                x: textX,
                y: candOuter + candPadY + (innerH - th) / 2,
                width: tw,
                height: th)
            x += w + candGap
            maxH = max(maxH, h)
        }

        // 「还有下一页」箭头单独一个视图，接在最后一个候选右侧。
        let hintSize = moreHint.intrinsicContentSize
        if hasNext, hintSize.width > 0, hintSize.height > 0 {
            moreHint.isHidden = false
            let hw = ceil(hintSize.width)
            let hh = ceil(hintSize.height)
            moreHint.frame = NSRect(
                x: x.rounded(), y: candOuter + ((maxH - hh) / 2).rounded(), width: hw, height: hh)
            x += hw + candGap
        } else {
            moreHint.isHidden = true
        }

        let width = x - candGap + candOuter
        let height = maxH + 2 * candOuter
        panel.setContentSize(NSSize(width: width, height: height))

        // 光标下方放不下就翻到上方。「放不下」按光标所在屏幕的可用区域算：
        // Dock 在底部或副屏不从 0 开始时，和 0 比会判成放得下，再被下面的
        // 边界修正推回来盖住正在输入的那一行。
        let screen = screenFrame(at: NSPoint(x: caret.minX, y: caret.minY))
        var top = caret.minY - 4
        if top - height < (screen?.minY ?? 0) {
            top = caret.minY + caret.height + height + 4
        }
        // 贴着屏幕边缘时收回来，别让候选条跑到屏幕外面。
        var point = NSPoint(x: caret.minX, y: top)
        if let screen {
            if point.x + width > screen.maxX { point.x = screen.maxX - width }
            if point.x < screen.minX { point.x = screen.minX }
            if point.y > screen.maxY { point.y = screen.maxY }
            if point.y - height < screen.minY { point.y = screen.minY + height }
        }
        panel.setFrameTopLeftPoint(point)
        if !shown {
            panel.orderFrontRegardless()
            shown = true
        }
    }

    /// 选中项的文字换成白色。选中玻璃的 tint 在布局时按同一个强调色设置。
    private func setSelected(_ chip: Chip, hasLabel: Bool) {
        let text = NSColor.alternateSelectedControlTextColor
        setText(chip.text, chip.text.stringValue, font: font, color: text)
        if hasLabel { setText(chip.label, chip.label.stringValue, font: labelFont, color: text) }
    }

    /// 用属性文本设置文字；颜色和字体都走这一处，阴影不会在切选中态时丢掉。
    private func setText(_ field: NSTextField, _ string: String, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = field.alignment
        field.attributedStringValue = NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .shadow: textShadow,
            ])
    }

    /// 返回包含指定点的屏幕的可用区域（已扣掉菜单栏和 Dock）。
    /// 不能直接用 mainScreen：多屏时它可能是另一块屏。
    private func screenFrame(at point: NSPoint) -> NSRect? {
        for screen in NSScreen.screens where screen.frame.contains(point) {
            return screen.visibleFrame
        }
        return nil
    }
}

@MainActor
private func makeField(font: NSFont, alignment: NSTextAlignment) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = font
    field.alignment = alignment
    field.isBezeled = false
    field.drawsBackground = false
    field.isEditable = false
    field.isSelectable = false
    field.usesSingleLineMode = true
    field.lineBreakMode = .byClipping
    return field
}
