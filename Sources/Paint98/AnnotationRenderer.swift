import AppKit
import PaintCore

/// Skitch 風の注釈を CoreGraphics で描く（なめらか・白ふち・影つき）。
enum AnnotationRenderer {
    static let shadowColor = NSColor(white: 0, alpha: 0.45).cgColor
    static let shadowOffset = CGSize(width: 0, height: -2) // ビットマップの基準座標は y が上向きなので、下へずらす
    static let shadowBlur: CGFloat = 4

    /// clip（キャンバスの範囲）の外は描かない。大きな画像で矢印を引きずっても重くならないように。
    static func render(_ a: Annotation, clip: IRect) -> RenderedAnnotation? {
        switch a.shape {
        case .arrow(let t, let h):
            return renderArrow(tail: t, head: h, color: a.color, thickness: a.thickness, clip: clip)
        case .box(let r):
            return renderBox(r, color: a.color, thickness: a.thickness, clip: clip)
        case .text(let s, let f, let size, let wrap):
            return renderText(s, origin: f.origin, wrap: wrap, size: size, color: a.color)
        case .stamp(let kind, let c, let r):
            return renderStamp(kind, center: c, radius: r, color: a.color, clip: clip)
        }
    }

    // MARK: - 矢印

    /// 根元が細く先へ太くなる軸と、大きな三角の頭。寸法は当たり判定と同じ Annotation.arrowGeometry。
    static func arrowPath(tail: CGPoint, head: CGPoint, thickness: Int) -> CGPath? {
        let dx = head.x - tail.x, dy = head.y - tail.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len >= 1 else { return nil }
        let g = Annotation.arrowGeometry(length: Double(len), thickness: thickness)
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let w = CGFloat(g.width)
        let headLen = CGFloat(g.headLength)
        let headHalf = CGFloat(g.headHalfWidth)
        let tailHalf = CGFloat(g.tailHalfWidth)
        let neck = CGPoint(x: head.x - ux * headLen, y: head.y - uy * headLen)
        // 頭の付け根を少しへこませて Skitch っぽく
        let notch = CGPoint(x: neck.x + ux * headLen * 0.12, y: neck.y + uy * headLen * 0.12)
        func pt(_ base: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: base.x + nx * s, y: base.y + ny * s) }

        let p = CGMutablePath()
        p.move(to: pt(tail, tailHalf))
        p.addLine(to: pt(notch, w / 2))
        p.addLine(to: pt(neck, headHalf))
        p.addLine(to: head)
        p.addLine(to: pt(neck, -headHalf))
        p.addLine(to: pt(notch, -w / 2))
        p.addLine(to: pt(tail, -tailHalf))
        p.addArc(center: tail, radius: tailHalf, startAngle: atan2(-ny, -nx), endAngle: atan2(ny, nx), clockwise: true)
        p.closeSubpath()
        return p
    }

    static func renderArrow(tail: IPoint, head: IPoint, color: Pixel, thickness: Int, clip: IRect) -> RenderedAnnotation? {
        let t = CGPoint(x: CGFloat(tail.x) + 0.5, y: CGFloat(tail.y) + 0.5)
        let h = CGPoint(x: CGFloat(head.x) + 0.5, y: CGFloat(head.y) + 0.5)
        guard let path = arrowPath(tail: t, head: h, thickness: thickness) else { return nil }
        let dx = Double(head.x - tail.x), dy = Double(head.y - tail.y)
        let outline = CGFloat(Annotation.arrowGeometry(length: (dx * dx + dy * dy).squareRoot(), thickness: thickness).outline)
        return draw(bounds: path.boundingBox, margin: outline + shadowBlur + 4, clip: clip) { ctx in
            ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.addPath(path)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(outline * 2)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setFillColor(Win98.color(color).cgColor)
            ctx.fillPath()
            ctx.endTransparencyLayer()
        }
    }

    // MARK: - 文字

    /// Skitch の文字（太字・白ふち・影）。origin が文字の原点、wrap の幅で折り返す。
    static func renderText(_ s: String, origin: IPoint, wrap: Int, size: Int, color: Pixel) -> RenderedAnnotation? {
        guard !s.isEmpty, wrap > 0,
              let r = TextStyle.skitch(size: size).render(s, width: wrap, minHeight: 0, color: Win98.color(color))
        else { return nil }
        return RenderedAnnotation(image: r.image, origin: IPoint(origin.x - r.margin, origin.y - r.margin))
    }

    // MARK: - 四角

    /// 角の丸い太枠の四角。枠線は rect の内側に収める（つまみの位置と見た目をそろえる）。
    static func renderBox(_ rect: IRect, color: Pixel, thickness: Int, clip: IRect) -> RenderedAnnotation? {
        let w = CGFloat(Annotation.boxStrokeWidth(thickness))
        let outline = CGFloat(Annotation.boxOutline(thickness))
        let r = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).insetBy(dx: w / 2, dy: w / 2)
        guard r.width > 0, r.height > 0 else { return nil }
        let radius = max(0, CGFloat(Annotation.boxCornerRadius(rect, thickness: thickness)) - w / 2)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        return draw(bounds: r, margin: w / 2 + outline + shadowBlur + 4, clip: clip) { ctx in
            ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.setLineWidth(w + outline * 2)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setLineWidth(w)
            ctx.setStrokeColor(Win98.color(color).cgColor)
            ctx.strokePath()
            ctx.endTransparencyLayer()
        }
    }

    // MARK: - スタンプ

    static func renderStamp(_ kind: StampKind, center: IPoint, radius: Int, color: Pixel, clip: IRect) -> RenderedAnnotation? {
        let r = CGFloat(max(4, radius))
        let c = CGPoint(x: CGFloat(center.x) + 0.5, y: CGFloat(center.y) + 0.5)
        let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        return draw(bounds: box, margin: shadowBlur + 6, clip: clip) { ctx in
            drawStamp(kind, in: ctx, center: c, radius: r, color: Win98.color(color).cgColor)
        }
    }

    /// スタンプの絵（道具箱のオプション欄でも使う）。ctx は上が原点の座標系。
    static func drawStamp(_ kind: StampKind, in ctx: CGContext, center c: CGPoint, radius r: CGFloat, color: CGColor,
                          shadow: Bool = true) {
        let ring = max(1.5, r * 0.14)
        if shadow { ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // 白い丸と色の輪
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setStrokeColor(color)
        ctx.setLineWidth(ring)
        let rr = r - ring / 2
        ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
        // 中の記号
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(max(1.5, r * 0.2))
        switch kind {
        case .cross:
            let s = r * 0.36
            ctx.move(to: CGPoint(x: c.x - s, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            ctx.move(to: CGPoint(x: c.x + s, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
            ctx.strokePath()
        case .check:
            ctx.move(to: CGPoint(x: c.x - r * 0.42, y: c.y + r * 0.02))
            ctx.addLine(to: CGPoint(x: c.x - r * 0.12, y: c.y + r * 0.32))
            ctx.addLine(to: CGPoint(x: c.x + r * 0.44, y: c.y - r * 0.34))
            ctx.strokePath()
        case .question, .exclamation:
            drawGlyph(kind == .question ? "?" : "!", in: ctx, center: c, size: r * 1.25, color: color)
        case .star:
            let p = CGMutablePath()
            for i in 0..<10 {
                let ang = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let rad = i % 2 == 0 ? r * 0.58 : r * 0.24
                let q = CGPoint(x: c.x + cos(ang) * rad, y: c.y + sin(ang) * rad + r * 0.04)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
            ctx.addPath(p)
            ctx.fillPath()
        case .heart:
            let s = r * 0.5
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c.x, y: c.y + s * 0.95))
            p.addCurve(to: CGPoint(x: c.x - s, y: c.y - s * 0.25),
                       control1: CGPoint(x: c.x - s * 0.55, y: c.y + s * 0.55),
                       control2: CGPoint(x: c.x - s, y: c.y + s * 0.2))
            p.addArc(center: CGPoint(x: c.x - s * 0.5, y: c.y - s * 0.3), radius: s * 0.5,
                     startAngle: .pi, endAngle: 0, clockwise: false)
            p.addArc(center: CGPoint(x: c.x + s * 0.5, y: c.y - s * 0.3), radius: s * 0.5,
                     startAngle: .pi, endAngle: 0, clockwise: false)
            p.addCurve(to: CGPoint(x: c.x, y: c.y + s * 0.95),
                       control1: CGPoint(x: c.x + s, y: c.y + s * 0.2),
                       control2: CGPoint(x: c.x + s * 0.55, y: c.y + s * 0.55))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        if shadow { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
    }

    private static func drawGlyph(_ s: String, in ctx: CGContext, center c: CGPoint, size: CGFloat, color: CGColor) {
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .black])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        // 上が原点の座標系で文字が逆さにならないよう、ここだけ y を反転
        ctx.translateBy(x: c.x - b.midX, y: c.y + b.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - 共通

    /// bounds（キャンバス座標）を margin だけ広げた範囲のうち、clip に入る部分だけを描いて乗算済みの画像にする。
    private static func draw(bounds: CGRect, margin: CGFloat, clip: IRect, _ body: (CGContext) -> Void) -> RenderedAnnotation? {
        let clipRect = CGRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height)
        let r = bounds.insetBy(dx: -margin, dy: -margin).integral.intersection(clipRect)
        guard !r.isNull, !r.isEmpty else { return nil }
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0, w < 20000, h < 20000 else { return nil }
        guard let img = BitmapIO.renderPremultiplied(width: w, height: h, antialias: true, { ctx in
            ctx.translateBy(x: -r.minX, y: -r.minY)
            body(ctx)
        }) else { return nil }
        return RenderedAnnotation(image: img, origin: IPoint(Int(r.minX), Int(r.minY)))
    }
}
