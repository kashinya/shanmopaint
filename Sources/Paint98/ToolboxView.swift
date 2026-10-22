import AppKit
import PaintCore

/// 左側の道具箱（2 列 × 8 段のボタン）と、その下のオプション欄。
final class ToolboxView: NSView {
    static let buttonSize: CGFloat = 25
    static let width: CGFloat = 2 * buttonSize + 8

    weak var engine: PaintEngine?
    var onHover: ((String) -> Void)?
    var onToolChosen: ((Tool) -> Void)?
    var onOptionsChanged: (() -> Void)?

    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    // 他のアプリから戻った最初のクリックでも道具を選べるように
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private var gridOrigin: NSPoint { NSPoint(x: 4, y: 4) }

    private func buttonRect(_ index: Int) -> NSRect {
        let col = index % 2, row = index / 2
        return NSRect(x: gridOrigin.x + CGFloat(col) * Self.buttonSize, y: gridOrigin.y + CGFloat(row) * Self.buttonSize,
                      width: Self.buttonSize, height: Self.buttonSize)
    }

    static var rows: Int { (Tool.paintTools.count + 1) / 2 }

    var optionsRect: NSRect {
        let top = gridOrigin.y + CGFloat(Self.rows) * Self.buttonSize + 6
        return NSRect(x: (bounds.width - 44) / 2, y: top, width: 44, height: 70)
    }

    override func draw(_ dirtyRect: NSRect) {
        Win98.face.setFill()
        bounds.fill()
        guard let engine = engine else { return }
        for (i, tool) in Tool.paintTools.enumerated() {
            let r = buttonRect(i)
            if engine.tool == tool {
                Win98.dither(r)
                Win98.draw(.pressed, in: r)
            } else {
                Win98.draw(.raised, in: r)
            }
            let off: CGFloat = engine.tool == tool ? 1 : 0
            let ir = NSRect(x: r.midX - 8 + off, y: r.midY - 8 + off, width: 16, height: 16)
            Win98.drawPixelArt(Icons.image(for: tool), in: ir)
        }
        Win98.draw(.sunken, in: optionsRect)
        OptionsLayout.draw(for: engine, in: optionsRect.insetBy(dx: 2, dy: 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard let engine = engine else { return }
        let p = convert(event.locationInWindow, from: nil)
        for (i, tool) in Tool.paintTools.enumerated() where buttonRect(i).contains(p) {
            onToolChosen?(tool)
            return
        }
        if optionsRect.contains(p), OptionsLayout.click(at: p, engine: engine, in: optionsRect.insetBy(dx: 2, dy: 2)) {
            onOptionsChanged?()
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, tool) in Tool.paintTools.enumerated() where buttonRect(i).contains(p) {
            onHover?(ToolInfo.name(tool) + ": " + ToolInfo.hint(tool))
            return
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: optionsRect.maxY + 4)
    }
}

/// 道具の名前と説明。
enum ToolInfo {
    static func name(_ t: Tool) -> String {
        switch t {
        case .freeSelect: return "自由選択"
        case .select: return "範囲選択"
        case .eraser: return "消しゴム/カラー消しゴム"
        case .fill: return "塗りつぶし"
        case .picker: return "色の選択"
        case .magnifier: return "拡大"
        case .pencil: return "鉛筆"
        case .brush: return "ブラシ"
        case .airbrush: return "エアブラシ"
        case .text: return "テキスト"
        case .line: return "直線"
        case .curve: return "曲線"
        case .rectangle: return "四角形"
        case .polygon: return "多角形"
        case .ellipse: return "楕円"
        case .roundedRectangle: return "角の丸い四角形"
        case .arrow: return "矢印（Skitch）"
        case .skitchText: return "文字（Skitch）"
        case .skitchBox: return "四角（Skitch）"
        case .stamp: return "スタンプ（Skitch）"
        }
    }

    static func hint(_ t: Tool) -> String {
        switch t {
        case .freeSelect: return "自由な形で選びます。中をドラッグで移動、option+ドラッグで複製。"
        case .select: return "四角く選びます。中をドラッグで移動、option+ドラッグで複製、ハンドルで伸縮。"
        case .eraser: return "背景色で消します。右ドラッグは描画色だけを消します。"
        case .fill: return "閉じた領域を色で塗りつぶします。"
        case .picker: return "クリックした所の色を拾います。"
        case .magnifier: return "クリックで拡大・縮小します。"
        case .pencil: return "1 ピクセル幅の自由な線を描きます。"
        case .brush: return "形と大きさを選んで自由な線を描きます。"
        case .airbrush: return "霧状に色を吹き付けます。"
        case .text: return "ドラッグで枠を作って文字を入力します。枠の外をクリックで確定。"
        case .line: return "直線を描きます。shift で水平・垂直・45°。"
        case .curve: return "直線を引いてから 2 回クリック（ドラッグ）で曲げます。"
        case .rectangle: return "四角形を描きます。shift で正方形。"
        case .polygon: return "クリックで頂点を足し、ダブルクリックか始点クリックで閉じます。"
        case .ellipse: return "楕円を描きます。shift で正円。"
        case .roundedRectangle: return "角の丸い四角形を描きます。shift で正方形。"
        case .arrow: return "ドラッグで矢印。置いたあとも先端・根元・本体をつまんで直せます。色と太さは Skitch ツールバーで。外側をクリックで確定。"
        case .skitchText: return "クリックかドラッグで文字を入力（太字・白ふち・影）。大きさと色は Skitch ツールバーで。枠の外をクリックで確定。"
        case .skitchBox: return "ドラッグで角の丸い四角（shift で正方形）。角・辺のつまみで大きさ、枠線をつかんで移動。外側をクリックで確定。"
        case .stamp: return "クリックでスタンプ（ドラッグで大きさ）。角をつまんで拡大縮小、本体で移動。外側をクリックで確定。"
        }
    }
}

/// オプション欄の中身（道具ごとに違う）。
enum OptionsLayout {
    private struct Item {
        var rect: NSRect
        var selected: Bool
        var draw: (NSRect, Bool) -> Void
        var apply: (PaintEngine) -> Void
    }

    private static func items(for e: PaintEngine, in r: NSRect) -> [Item] {
        let o = e.options
        func rows(_ n: Int) -> [NSRect] {
            let h = r.height / CGFloat(n)
            return (0..<n).map { NSRect(x: r.minX, y: r.minY + CGFloat($0) * h, width: r.width, height: h) }
        }
        func ink(_ sel: Bool) -> NSColor { sel ? Win98.highlight : Win98.text }

        switch e.tool {
        case .select, .freeSelect, .text:
            return rows(2).enumerated().map { i, rr in
                let transparent = i == 1
                return Item(rect: rr, selected: o.transparentBackground == transparent, draw: { rect, sel in
                    let box = NSRect(x: rect.midX - 14, y: rect.midY - 11, width: 28, height: 22)
                    if !transparent { Win98.highlight.setFill(); box.insetBy(dx: 2, dy: 2).fill() }
                    Win98.color(0xFFFF_0000).setFill()
                    NSBezierPath(ovalIn: NSRect(x: box.minX + 4, y: box.minY + 4, width: 10, height: 10)).fill()
                    Win98.color(0xFF00_0080).setFill()
                    NSRect(x: box.minX + 12, y: box.minY + 9, width: 12, height: 9).fill()
                    Win98.color(0xFF00_8000).setFill()
                    let tri = NSBezierPath()
                    tri.move(to: NSPoint(x: box.minX + 6, y: box.maxY - 3))
                    tri.line(to: NSPoint(x: box.minX + 11, y: box.minY + 12))
                    tri.line(to: NSPoint(x: box.minX + 16, y: box.maxY - 3))
                    tri.close()
                    tri.fill()
                    _ = sel
                }, apply: { $0.options.transparentBackground = transparent })
            }
        case .eraser:
            return zip(rows(4), ToolOptions.eraserSizes).map { rr, s in
                Item(rect: rr, selected: o.eraserSize == s, draw: { rect, sel in
                    ink(sel).setFill()
                    let d = CGFloat(s)
                    NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d).fill()
                }, apply: { $0.options.eraserSize = s })
            }
        case .magnifier:
            return zip(rows(5), ToolOptions.magnifications).map { rr, z in
                Item(rect: rr, selected: e.zoom == Double(z), draw: { rect, sel in
                    let s = NSAttributedString(string: "\(z)x", attributes: [.font: Win98.smallFont, .foregroundColor: ink(sel)])
                    let sz = s.size()
                    s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
                }, apply: { $0.options.magnification = z })
            }
        case .brush:
            var out: [Item] = []
            let shapes: [BrushShape] = [.round, .square, .slash, .backslash]
            let rh = r.height / 4, cw = r.width / 3
            for (row, shape) in shapes.enumerated() {
                for (col, size) in ToolOptions.brushSizes.enumerated() {
                    let rr = NSRect(x: r.minX + CGFloat(col) * cw, y: r.minY + CGFloat(row) * rh, width: cw, height: rh)
                    out.append(Item(rect: rr, selected: o.brushShape == shape && o.brushSize == size, draw: { rect, sel in
                        ink(sel).setFill()
                        let d = CGFloat(min(size, 8))
                        let br = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
                        switch shape {
                        case .round: NSBezierPath(ovalIn: br).fill()
                        case .square: br.fill()
                        case .slash, .backslash:
                            for i in 0..<Int(d) {
                                let x = br.minX + CGFloat(i)
                                let y = shape == .slash ? br.maxY - 1 - CGFloat(i) : br.minY + CGFloat(i)
                                NSRect(x: x, y: y, width: 1, height: 1).fill()
                            }
                        }
                    }, apply: { $0.options.brushShape = shape; $0.options.brushSize = size }))
                }
            }
            return out
        case .airbrush:
            return zip(rows(3), ToolOptions.airbrushRadii).map { rr, radius in
                Item(rect: rr, selected: o.airbrushRadius == radius, draw: { rect, sel in
                    ink(sel).setFill()
                    var rng = SplitMix64(seed: UInt64(radius))
                    let rad = CGFloat(radius) * 0.75
                    for _ in 0..<(radius * 3) {
                        let dx = CGFloat(Int.random(in: -100...100, using: &rng)) / 100 * rad
                        let dy = CGFloat(Int.random(in: -100...100, using: &rng)) / 100 * rad
                        if dx * dx + dy * dy > rad * rad { continue }
                        NSRect(x: (rect.midX + dx).rounded(), y: (rect.midY + dy).rounded(), width: 1, height: 1).fill()
                    }
                }, apply: { $0.options.airbrushRadius = radius })
            }
        case .line, .curve:
            return zip(rows(5), ToolOptions.lineWidths).map { rr, w in
                Item(rect: rr, selected: o.lineWidth == w, draw: { rect, sel in
                    ink(sel).setFill()
                    NSRect(x: rect.minX + 4, y: (rect.midY - CGFloat(w) / 2).rounded(), width: rect.width - 8, height: CGFloat(w)).fill()
                }, apply: { $0.options.lineWidth = w })
            }
        case .rectangle, .ellipse, .roundedRectangle, .polygon:
            let styles: [FillStyle] = [.outline, .outlineAndFill, .fill]
            let tool = e.tool
            var out: [Item] = zip(rows(4).prefix(3), styles).map { rr, st in
                Item(rect: rr, selected: o.fillStyle == st, draw: { rect, sel in
                    let box = NSRect(x: rect.midX - 14, y: rect.midY - 6, width: 28, height: 12)
                    let path: NSBezierPath
                    switch tool {
                    case .ellipse: path = NSBezierPath(ovalIn: box)
                    case .roundedRectangle: path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                    default: path = NSBezierPath(rect: box)
                    }
                    if st != .outline {
                        (st == .fill ? ink(sel) : Win98.shadow).setFill()
                        path.fill()
                    }
                    if st != .fill {
                        ink(sel).setStroke()
                        path.lineWidth = 1
                        path.stroke()
                    }
                }, apply: { $0.options.fillStyle = st })
            }
            // 線の太さ（直線ツールと共通）を小さく表示
            let last = rows(4)[3]
            out.append(Item(rect: last, selected: false, draw: { rect, _ in
                let s = NSAttributedString(string: "線 \(o.lineWidth)", attributes: [.font: Win98.smallFont, .foregroundColor: Win98.shadow])
                let sz = s.size()
                s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            }, apply: { e in
                e.options.lineWidth = e.options.lineWidth % 5 + 1
            }))
            return out
        case .pencil, .fill, .picker:
            return []
        case .arrow, .skitchText, .skitchBox, .stamp:
            // Skitch の設定は上の Skitch ツールバーにある
            return []
        }
    }

    static func draw(for e: PaintEngine, in r: NSRect) {
        for it in items(for: e, in: r) {
            if it.selected {
                Win98.navy.setFill()
                it.rect.insetBy(dx: 1, dy: 1).fill()
            }
            it.draw(it.rect, it.selected)
        }
    }

    /// クリックを処理したら true。
    static func click(at p: NSPoint, engine e: PaintEngine, in r: NSRect) -> Bool {
        for it in items(for: e, in: r) where it.rect.contains(p) {
            it.apply(e)
            return true
        }
        return false
    }
}
