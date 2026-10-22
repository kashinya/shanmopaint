import AppKit
import PaintCore

/// ウインドウ上部の Skitch ツールバー。ペイントの道具箱とは別に、矢印・文字・四角・スタンプと、
/// Skitch 専用の色・太さ・文字の大きさ・スタンプの種類を並べる。
final class SkitchBarView: NSView {
    static let height: CGFloat = 38

    weak var engine: PaintEngine?
    var onToolChosen: ((Tool) -> Void)?
    var onChanged: (() -> Void)?
    var onHover: ((String) -> Void)?

    private var tracking: NSTrackingArea?

    private enum Kind {
        case tool(Tool)
        case color(Pixel)
        case thickness(Int)
        case textSize(Int)
        case stamp(StampKind)
    }

    private struct Item {
        var rect: NSRect
        var kind: Kind
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: - 並べ方

    private let labelWidth: CGFloat = 52

    private func layoutItems() -> (items: [Item], separators: [CGFloat]) {
        guard let e = engine else { return ([], []) }
        var items: [Item] = []
        var seps: [CGFloat] = []
        var x: CGFloat = labelWidth
        let midY = bounds.height / 2
        func add(_ k: Kind, w: CGFloat, h: CGFloat, gap: CGFloat = 2) {
            items.append(Item(rect: NSRect(x: x, y: (midY - h / 2).rounded(), width: w, height: h), kind: k))
            x += w + gap
        }
        func separator() {
            x += 6
            seps.append(x)
            x += 8
        }
        for t in Tool.skitchTools { add(.tool(t), w: 34, h: 28) }
        separator()
        for c in Annotation.skitchPalette { add(.color(c), w: 20, h: 20, gap: 3) }
        separator()
        switch e.tool {
        case .arrow, .skitchBox:
            for t in ToolOptions.skitchThicknesses { add(.thickness(t), w: 28, h: 26) }
        case .skitchText:
            for i in ToolOptions.skitchTextSizes.indices { add(.textSize(i), w: 28, h: 24) }
        case .stamp:
            for k in StampKind.allCases { add(.stamp(k), w: 26, h: 26) }
        default:
            break
        }
        return (items, seps)
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        Win98.face.setFill()
        bounds.fill()
        // 下の段との境目（Win98 のツールバー風に一段へこませる）
        Win98.shadow.setFill()
        NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 1).fill()
        Win98.highlight.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        let title = NSAttributedString(string: "Skitch", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: Win98.color(Annotation.skitchRed),
        ])
        let ts = title.size()
        title.draw(at: NSPoint(x: 8, y: (bounds.height - ts.height) / 2 - 1))

        guard let e = engine, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (items, seps) = layoutItems()
        for s in seps {
            Win98.shadow.setFill()
            NSRect(x: s, y: 6, width: 1, height: bounds.height - 13).fill()
            Win98.highlight.setFill()
            NSRect(x: s + 1, y: 6, width: 1, height: bounds.height - 13).fill()
        }
        let ink = Win98.color(e.skitchColor)
        for it in items {
            let r = it.rect
            switch it.kind {
            case .tool(let t):
                let on = e.tool == t
                if on { Win98.dither(r); Win98.draw(.pressed, in: r) } else { Win98.draw(.raised, in: r) }
                let ir = r.insetBy(dx: 7, dy: 5).offsetBy(dx: on ? 1 : 0, dy: on ? 1 : 0)
                drawToolIcon(t, in: ir, ctx: ctx, color: ink)
            case .color(let c):
                if e.skitchColor == c {
                    Win98.navy.setFill()
                    r.insetBy(dx: -2, dy: -2).fill()
                }
                Win98.color(c).setFill()
                let o = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
                o.fill()
                Win98.shadow.setStroke()
                o.lineWidth = 1
                o.stroke()
            case .thickness(let t):
                let on = e.options.skitchThickness == t
                if on { Win98.dither(r); Win98.draw(.pressed, in: r) } else { Win98.draw(.raised, in: r) }
                // 細・中・太・極太・超極太
                let w = CGFloat([0, 2, 4, 6, 10, 14][min(5, max(0, t))])
                ink.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + 6, y: r.midY - w / 2, width: r.width - 12, height: w),
                             xRadius: w / 2, yRadius: w / 2).fill()
            case .textSize(let i):
                let on = e.options.skitchTextSize == i
                if on { Win98.dither(r); Win98.draw(.pressed, in: r) } else { Win98.draw(.raised, in: r) }
                let label = ["小", "中", "大"][min(2, i)]
                let a = NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: [10, 12, 15][min(2, i)], weight: .bold), .foregroundColor: Win98.text,
                ])
                let sz = a.size()
                a.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
            case .stamp(let k):
                let on = e.options.stampKind == k
                if on { Win98.dither(r); Win98.draw(.pressed, in: r) } else { Win98.draw(.raised, in: r) }
                AnnotationRenderer.drawStamp(k, in: ctx, center: CGPoint(x: r.midX, y: r.midY), radius: 9,
                                             color: Win98.color(k.defaultColor).cgColor, shadow: false)
            }
        }
    }

    /// Skitch の道具のアイコン（色つき）。
    private func drawToolIcon(_ t: Tool, in r: NSRect, ctx: CGContext, color: NSColor) {
        switch t {
        case .arrow:
            if let p = AnnotationRenderer.arrowPath(tail: CGPoint(x: r.minX + 1, y: r.maxY - 1),
                                                     head: CGPoint(x: r.maxX - 1, y: r.minY + 1), thickness: 1) {
                ctx.addPath(p)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
        case .skitchText:
            // 白ふちを先に太く描いてから、中を塗る（Skitch の文字の見た目）
            let font = NSFont.systemFont(ofSize: 18, weight: .black)
            let outline = NSAttributedString(string: "A", attributes: [
                .font: font, .foregroundColor: NSColor.white, .strokeColor: NSColor.white, .strokeWidth: 12.0,
            ])
            let fill = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: color])
            let sz = fill.size()
            let o = NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2)
            outline.draw(at: o)
            fill.draw(at: o)
        case .skitchBox:
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 2.5), xRadius: 4, yRadius: 4)
            p.lineWidth = 2.5
            color.setStroke()
            p.stroke()
        case .stamp:
            AnnotationRenderer.drawStamp(.cross, in: ctx, center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2,
                                         color: Win98.color(StampKind.cross.defaultColor).cgColor, shadow: false)
        default:
            break
        }
    }

    // MARK: - マウス

    private func item(at p: NSPoint) -> Item? {
        layoutItems().items.first { $0.rect.insetBy(dx: -1, dy: -1).contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let e = engine, let it = item(at: convert(event.locationInWindow, from: nil)) else { return }
        switch it.kind {
        case .tool(let t): onToolChosen?(t)
        case .color(let c): e.skitchColor = c
        case .thickness(let t): e.options.skitchThickness = t
        case .textSize(let i): e.options.skitchTextSize = i
        case .stamp(let k): e.options.stampKind = k
        }
        onChanged?()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard let it = item(at: convert(event.locationInWindow, from: nil)) else { return }
        switch it.kind {
        case .tool(let t): onHover?(ToolInfo.name(t) + ": " + ToolInfo.hint(t))
        case .color(let c): onHover?("Skitch の色 \(Colors.hexString(c))（ペイントの描画色とは別）")
        case .thickness(let t): onHover?("矢印・四角の太さ：\(["", "細", "中", "太", "極太", "超極太"][min(5, max(0, t))])")
        case .textSize(let i): onHover?("文字の大きさ \(ToolOptions.skitchTextSizes[i]) ピクセル")
        case .stamp(let k): onHover?("スタンプ \(k.label)")
        }
    }
}
