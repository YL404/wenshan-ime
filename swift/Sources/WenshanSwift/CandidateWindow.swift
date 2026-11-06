import AppKit
import WenshanCore

/// 候选窗是一个「永远不会成为焦点」的浮动面板：NSPanel 带
/// .nonactivatingPanel，所以点它不会抢走当前 App 的焦点。
///
/// 外观：面板底是 .regular 样式的液态玻璃（NSGlassEffectView），每个候选是一个
/// 独立的圆角色块，选中的那个铺实心强调色、文字转白。文字用系统标签色，
/// 玻璃会按背后的内容和深浅模式调对比度。同一个面板也用来显示模式提示
/// （中文/英文/全角/半角）。
@MainActor
final class CandidateWindow {
    private struct Chip {
        let bg: NSView
        let label: NSTextField
        let text: NSTextField
    }

    private let panel: NSPanel
    private let glass: NSGlassEffectView
    private let content: NSView
    private let moreHint: NSImageView
    private var chips: [Chip] = []

    private let font = NSFont.systemFont(ofSize: 14)
    private let labelFont = NSFont.systemFont(ofSize: 10)
    private var shown = false
    private var isHUD = false

    private let candPadX = 7.0  // 色块内左右留白
    private let candPadY = 3.0  // 色块内上下留白
    private let candGap = 6.0  // 候选之间的间隔
    private let candOuter = 6.0  // 面板四周留白
    private let chipRadius = 5.0  // 候选色块圆角
    /// 面板圆角取色块圆角加四周留白，内外圆角同心，液态玻璃的边缘才和色块平行。
    private var candRadius: Double { chipRadius + candOuter }
    private let candLabelSlot = 11.0  // 序号固定槽位
    private let candLabelGap = 4.0  // 序号与候选之间的间隔
    private let maxChips = 9

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false)
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let hint = NSImageView(frame: .zero)
        hint.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: "还有下一页")
        hint.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        hint.contentTintColor = .secondaryLabelColor
        self.panel = panel
        self.glass = glass
        self.content = content
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

        glass.style = .regular
        glass.cornerRadius = candRadius
        glass.contentView = content
        panel.contentView = glass

        for _ in 0..<maxChips {
            // 底色、序号、候选分成三个视图：色块负责圆角和内边距，两个文字
            // 视图的尺寸都等于实测文字大小，这样才能真正居中。
            let bg = NSView(frame: .zero)
            bg.wantsLayer = true
            bg.layer?.cornerRadius = chipRadius
            bg.isHidden = true
            content.addSubview(bg)

            let label = makeField(font: labelFont, alignment: .center)
            label.isHidden = true
            content.addSubview(label)

            let text = makeField(font: font, alignment: .left)
            text.isHidden = true
            content.addSubview(text)

            chips.append(Chip(bg: bg, label: label, text: text))
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
        // 文字用动态的系统标签色，切深浅模式会自己跟着变；色块是 CGColor，
        // 要在面板当前的外观下取值，所以整段布局放在这个外观里做。
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            layoutInAppearance(items: items, selected: selected, caret: caret, hasNext: hasNext)
        }
    }

    private func layoutInAppearance(
        items: [(label: String, text: String)], selected: Int, caret: NSRect, hasNext: Bool
    ) {
        let dimText = NSColor.labelColor
        let labelDim = NSColor.secondaryLabelColor
        var x = candOuter
        var maxH = 0.0
        for i in 0..<maxChips {
            let chip = chips[i]
            guard i < items.count else {
                chip.bg.isHidden = true
                chip.label.isHidden = true
                chip.text.isHidden = true
                continue
            }
            chip.bg.isHidden = false
            chip.text.isHidden = false

            let item = items[i]
            let hasLabel = !item.label.isEmpty
            chip.label.isHidden = !hasLabel

            chip.text.stringValue = item.text
            var size = (item.text as NSString).size(withAttributes: [.font: font])
            if !(size.width > 0) || !(size.height > 0) {
                // 量不出来就退回按字数估，绝不把 NaN 传给 setFrame。
                size = NSSize(width: Double(item.text.count) * 14 * 0.9, height: 14 * 1.3)
            }

            // 序号单独量高度，然后在固定槽位里垂直居中；槽宽不随数字变化。
            var labelHeight = 10.0 * 1.3
            if hasLabel {
                chip.label.stringValue = item.label
                let ls = (item.label as NSString).size(withAttributes: [.font: labelFont])
                if ls.height > 0 { labelHeight = ceil(ls.height) }
            }

            if i == selected {
                setSelected(chip, hasLabel: hasLabel)
            } else {
                chip.text.textColor = dimText
                if hasLabel { chip.label.textColor = labelDim }
                chip.bg.layer?.backgroundColor = NSColor.clear.cgColor
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
            chip.bg.frame = NSRect(x: xr, y: candOuter, width: w, height: h)
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

    /// 选中的色块铺成实心强调色、文字换成白色。用一对系统选中态语义色：
    /// 强调色改成黄、灰时这对色会一起变，白字始终压得住底。
    private func setSelected(_ chip: Chip, hasLabel: Bool) {
        let fill = NSColor.selectedContentBackgroundColor
        let text = NSColor.alternateSelectedControlTextColor
        chip.text.textColor = text
        if hasLabel { chip.label.textColor = text }
        chip.bg.layer?.backgroundColor = fill.cgColor
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
