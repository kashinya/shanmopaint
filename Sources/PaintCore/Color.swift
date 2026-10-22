/// 0xAARRGGBB 形式の 32bit ピクセル。
/// キャンバスは常に不透明（A = 0xFF）。テキスト合成用の一時画像だけ、乗算済みアルファで使う。
public typealias Pixel = UInt32

public enum Colors {
    public static let black: Pixel = 0xFF00_0000
    public static let white: Pixel = 0xFFFF_FFFF
    public static let clear: Pixel = 0x0000_0000

    public static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Pixel {
        0xFF00_0000 | (UInt32(clamp8(r)) << 16) | (UInt32(clamp8(g)) << 8) | UInt32(clamp8(b))
    }

    public static func alpha(_ p: Pixel) -> Int { Int((p >> 24) & 0xFF) }
    public static func red(_ p: Pixel) -> Int { Int((p >> 16) & 0xFF) }
    public static func green(_ p: Pixel) -> Int { Int((p >> 8) & 0xFF) }
    public static func blue(_ p: Pixel) -> Int { Int(p & 0xFF) }

    public static func opaque(_ p: Pixel) -> Pixel { p | 0xFF00_0000 }

    public static func inverted(_ p: Pixel) -> Pixel {
        (p & 0xFF00_0000) | (~p & 0x00FF_FFFF)
    }

    /// 乗算済みアルファの src を不透明な dst の上に重ねる。
    public static func blendPremultiplied(_ src: Pixel, over dst: Pixel) -> Pixel {
        let a = (src >> 24) & 0xFF
        if a == 0 { return dst }
        if a == 0xFF { return src | 0xFF00_0000 }
        let inv = 255 - a
        func ch(_ shift: UInt32) -> UInt32 {
            let s = (src >> shift) & 0xFF
            let d = (dst >> shift) & 0xFF
            return min(255, s + (d * inv + 127) / 255)
        }
        return 0xFF00_0000 | (ch(16) << 16) | (ch(8) << 8) | ch(0)
    }

    /// "#rrggbb"
    public static func hexString(_ p: Pixel) -> String {
        func two(_ v: Int) -> String {
            let s = String(v, radix: 16)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + two(red(p)) + two(green(p)) + two(blue(p))
    }

    public static func parseHex(_ s: String) -> Pixel? {
        var t = Substring(s)
        if t.hasPrefix("#") { t = t.dropFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return 0xFF00_0000 | v
    }

    private static func clamp8(_ v: Int) -> Int { min(255, max(0, v)) }

    /// Windows 98 版ペイントの既定パレット（上段 14 色 + 下段 14 色）。
    public static let win98Palette: [Pixel] = [
        0xFF000000, 0xFF808080, 0xFF800000, 0xFF808000, 0xFF008000, 0xFF008080, 0xFF000080,
        0xFF800080, 0xFF808040, 0xFF004040, 0xFF0080FF, 0xFF004080, 0xFF8000FF, 0xFF804000,
        0xFFFFFFFF, 0xFFC0C0C0, 0xFFFF0000, 0xFFFFFF00, 0xFF00FF00, 0xFF00FFFF, 0xFF0000FF,
        0xFFFF00FF, 0xFFFFFF80, 0xFF00FF80, 0xFF80FFFF, 0xFF8080FF, 0xFFFF0080, 0xFFFF8040,
    ]
}
