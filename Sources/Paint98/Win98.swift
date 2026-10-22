import AppKit
import PaintCore

/// Windows 98 風の色・立体枠・ドット絵。
enum Win98 {
    static let face = rgb(0xC0, 0xC0, 0xC0)
    static let light = rgb(0xDF, 0xDF, 0xDF)
    static let highlight = rgb(0xFF, 0xFF, 0xFF)
    static let shadow = rgb(0x80, 0x80, 0x80)
    static let darkShadow = rgb(0x0A, 0x0A, 0x0A)
    static let workspace = rgb(0x80, 0x80, 0x80)
    static let navy = rgb(0x00, 0x00, 0x80)
    static let text = rgb(0x00, 0x00, 0x00)

    static let uiFont = NSFont.systemFont(ofSize: 11)
    static let smallFont = NSFont.systemFont(ofSize: 9)

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static func color(_ p: Pixel) -> NSColor {
        rgb(Colors.red(p), Colors.green(p), Colors.blue(p))
    }

    static func pixel(_ c: NSColor) -> Pixel {
        let s = c.usingColorSpace(.sRGB) ?? c
        return Colors.rgb(Int((s.redComponent * 255).rounded()),
                          Int((s.greenComponent * 255).rounded()),
                          Int((s.blueComponent * 255).rounded()))
    }

    enum Bevel {
        /// 出っ張ったボタン
        case raised
        /// へこんだ入力欄・作業領域
        case sunken
        /// 押されたボタン
        case pressed
        /// ステータスバーの細いへこみ
        case thin
    }

    /// 立体枠を描く（反転座標系 = 上が minY の前提）。
    static func draw(_ bevel: Bevel, in r: NSRect) {
        switch bevel {
        case .raised:
            edge(r, topLeft: highlight, bottomRight: darkShadow)
            edge(r.insetBy(dx: 1, dy: 1), topLeft: light, bottomRight: shadow)
        case .sunken:
            edge(r, topLeft: shadow, bottomRight: highlight)
            edge(r.insetBy(dx: 1, dy: 1), topLeft: darkShadow, bottomRight: light)
        case .pressed:
            edge(r, topLeft: darkShadow, bottomRight: highlight)
            edge(r.insetBy(dx: 1, dy: 1), topLeft: shadow, bottomRight: light)
        case .thin:
            edge(r, topLeft: shadow, bottomRight: highlight)
        }
    }

    private static func edge(_ r: NSRect, topLeft: NSColor, bottomRight: NSColor) {
        guard r.width >= 2, r.height >= 2 else { return }
        topLeft.setFill()
        NSRect(x: r.minX, y: r.minY, width: r.width - 1, height: 1).fill()
        NSRect(x: r.minX, y: r.minY, width: 1, height: r.height - 1).fill()
        bottomRight.setFill()
        NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
        NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
    }

    /// 押されたボタンの白とグレーの市松模様。
    static func dither(_ r: NSRect) {
        face.setFill()
        r.fill()
        highlight.setFill()
        var y = r.minY
        var row = 0
        while y < r.maxY {
            var x = r.minX + CGFloat(row % 2)
            while x < r.maxX {
                NSRect(x: x, y: y, width: 1, height: 1).fill()
                x += 2
            }
            y += 1
            row += 1
        }
    }

    // MARK: - ドット絵

    private static let palette: [Character: Pixel] = [
        "k": 0xFF00_0000, "w": 0xFFFF_FFFF, "g": 0xFF80_8080, "l": 0xFFC0_C0C0, "d": 0xFF40_4040,
        "r": 0xFFFF_0000, "m": 0xFF80_0000, "y": 0xFFFF_FF00, "o": 0xFF80_8000, "b": 0xFF00_0080,
        "B": 0xFF00_00FF, "c": 0xFF00_FFFF, "p": 0xFFFF_80C0, "n": 0xFF80_4000, "G": 0xFF00_8000,
    ]

    /// 文字列のドット絵から Bitmap（透明部分は 0）。
    static func bitmap(_ rows: [String]) -> Bitmap {
        let h = rows.count, w = rows.map(\.count).max() ?? 1
        var b = Bitmap(width: w, height: h, fill: Colors.clear)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                if let p = palette[ch] { b[x, y] = p }
            }
        }
        return b
    }

    /// 乗算済み（透明は 0）の Bitmap を NSImage に。size はポイント。
    static func image(_ b: Bitmap, size: NSSize? = nil) -> NSImage {
        guard let cg = BitmapIO.cgImage(b, premultiplied: true) else { return NSImage() }
        return NSImage(cgImage: cg, size: size ?? NSSize(width: b.width, height: b.height))
    }

    /// ドット絵のまわりに白いふちを付けて、整数倍に拡大する（カーソル用）。
    static func outlined(_ b: Bitmap, scale: Int) -> Bitmap {
        var o = Bitmap(width: b.width + 2, height: b.height + 2, fill: Colors.clear)
        for y in 0..<b.height {
            for x in 0..<b.width where Colors.alpha(b[x, y]) > 0 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + 1 + dx, ny = y + 1 + dy
                        if Colors.alpha(o[nx, ny]) == 0 { o[nx, ny] = Colors.white }
                    }
                }
            }
        }
        o.draw(b, at: IPoint(1, 1), mask: b.pixels.map { Colors.alpha($0) > 0 })
        return o.scaled(to: ISize(o.width * scale, o.height * scale))
    }

    /// ドット絵をカーソルにする。hotSpot は元のドット絵の座標。
    static func cursor(_ rows: [String], hotSpot: (Int, Int)) -> NSCursor {
        let b = outlined(bitmap(rows), scale: 2)
        let img = image(b, size: NSSize(width: b.width / 2, height: b.height / 2))
        return NSCursor(image: img, hotSpot: NSPoint(x: hotSpot.0 + 1, y: hotSpot.1 + 1))
    }

    /// ドット絵をにじませずに描く。
    static func drawPixelArt(_ img: NSImage, in r: NSRect) {
        let ctx = NSGraphicsContext.current
        let old = ctx?.imageInterpolation
        ctx?.imageInterpolation = .none
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let old = old { ctx?.imageInterpolation = old }
    }
}
