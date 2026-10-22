import AppKit
import PaintCore

/// 下のカラーボックス：今の描画色・背景色と 28 色のパレット。
final class ColorBoxView: NSView {
    static let height: CGFloat = 44
    private static let swatch: CGFloat = 16

    weak var engine: PaintEngine?
    var palette: [Pixel] = Colors.win98Palette
    var onEditColor: ((Int?) -> Void)?
    var onHover: ((String) -> Void)?
    /// パレットの色をクリックで選んだ（色の編集中の対象を外すため）
    var onPick: (() -> Void)?

    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private var currentRect: NSRect { NSRect(x: 4, y: 6, width: 32, height: 32) }

    private func swatchRect(_ i: Int) -> NSRect {
        let col = i % 14, row = i / 14
        return NSRect(x: currentRect.maxX + 6 + CGFloat(col) * Self.swatch, y: 6 + CGFloat(row) * Self.swatch,
                      width: Self.swatch, height: Self.swatch)
    }

    override func draw(_ dirtyRect: NSRect) {
        Win98.face.setFill()
        bounds.fill()
        guard let engine = engine else { return }
        let c = currentRect
        Win98.dither(c)
        Win98.draw(.sunken, in: c)
        let bg = NSRect(x: c.minX + 13, y: c.minY + 13, width: 15, height: 15)
        let fg = NSRect(x: c.minX + 5, y: c.minY + 5, width: 15, height: 15)
        for (r, p) in [(bg, engine.secondary), (fg, engine.primary)] {
            Win98.face.setFill()
            r.insetBy(dx: -1, dy: -1).fill()
            Win98.color(p).setFill()
            r.fill()
            Win98.draw(.thin, in: r)
        }
        for (i, p) in palette.enumerated() {
            let r = swatchRect(i)
            Win98.color(p).setFill()
            r.fill()
            Win98.draw(.sunken, in: r)
        }
    }

    private func index(at p: NSPoint) -> Int? {
        palette.indices.first { swatchRect($0).contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let engine = engine else { return }
        let p = convert(event.locationInWindow, from: nil)
        if currentRect.contains(p) {
            engine.swapColors()
            return
        }
        guard let i = index(at: p) else { return }
        if event.clickCount >= 2 {
            onEditColor?(i)
            return
        }
        onPick?()
        if event.modifierFlags.contains(.control) {
            engine.secondary = palette[i]
        } else {
            engine.primary = palette[i]
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let engine = engine, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?()
        engine.secondary = palette[i]
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if currentRect.contains(p) {
            onHover?("クリックで描画色と背景色を入れ替えます。")
        } else if let i = index(at: p) {
            onHover?("\(Colors.hexString(palette[i]))  クリック: 描画色 ／ 右クリック: 背景色 ／ ダブルクリック: 色の編集")
        }
    }
}

/// 一番下のステータスバー。
final class StatusBarView: NSView {
    static let height: CGFloat = 22

    var hint = "ヘルプを表示するには、[ヘルプ] メニューの [ペイントのヘルプ] をクリックしてください。" { didSet { needsDisplay = true } }
    var position = "" { didSet { if position != oldValue { needsDisplay = true } } }
    var size = "" { didSet { if size != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Win98.face.setFill()
        bounds.fill()
        let h = bounds.height - 4
        let sizeW: CGFloat = 160, posW: CGFloat = 84
        let sizeR = NSRect(x: bounds.maxX - sizeW - 18, y: 2, width: sizeW, height: h)
        let posR = NSRect(x: sizeR.minX - posW - 2, y: 2, width: posW, height: h)
        let hintR = NSRect(x: 2, y: 2, width: max(10, posR.minX - 4), height: h)
        for (r, s) in [(hintR, hint), (posR, position), (sizeR, size)] {
            Win98.draw(.thin, in: r)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let a = NSAttributedString(string: s, attributes: [.font: Win98.uiFont, .foregroundColor: Win98.text, .paragraphStyle: para])
            a.draw(with: r.insetBy(dx: 4, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        // サイズ変更つまみ（斜線）
        for i in 0..<3 {
            let o = CGFloat(i) * 4
            Win98.highlight.setFill()
            for k in 0..<Int(10 - o) {
                NSRect(x: bounds.maxX - 3 - CGFloat(k), y: bounds.maxY - 12 + o + CGFloat(k), width: 1, height: 1).fill()
            }
            Win98.shadow.setFill()
            for k in 0..<Int(10 - o) {
                NSRect(x: bounds.maxX - 2 - CGFloat(k), y: bounds.maxY - 12 + o + CGFloat(k), width: 1, height: 1).fill()
            }
        }
    }
}
