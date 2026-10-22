// アプリアイコン（32×32 のドット絵）を描いて、各サイズの PNG を iconset に書き出す。
//   swift scripts/make-icon.swift dist/AppIcon.iconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let n = 32
var px = [UInt32](repeating: 0, count: n * n) // 0xAARRGGBB（0 は透明）

func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt32) {
    for yy in max(0, y)..<min(n, y + h) {
        for xx in max(0, x)..<min(n, x + w) { px[yy * n + xx] = c }
    }
}

func disc(_ cx: Double, _ cy: Double, _ r: Double, _ c: UInt32) {
    for y in 0..<n {
        for x in 0..<n {
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            if dx * dx + dy * dy <= r * r { px[y * n + x] = c }
        }
    }
}

let black: UInt32 = 0xFF00_0000, white: UInt32 = 0xFFFF_FFFF, face: UInt32 = 0xFFC0_C0C0
let gray: UInt32 = 0xFF80_8080, navy: UInt32 = 0xFF00_0080, sky: UInt32 = 0xFF80_FFFF
let red: UInt32 = 0xFFFF_0000, yellow: UInt32 = 0xFFFF_FF00, green: UInt32 = 0xFF00_8000
let lime: UInt32 = 0xFF00_FF00, blue: UInt32 = 0xFF00_00FF, brown: UInt32 = 0xFF80_4000, olive: UInt32 = 0xFF80_8000

// 額縁（Win98 の立体枠）
rect(1, 3, 26, 24, face)
rect(1, 3, 26, 1, white); rect(1, 3, 1, 24, white)
rect(1, 26, 26, 1, black); rect(26, 3, 1, 24, black)
rect(2, 25, 24, 1, gray); rect(25, 4, 1, 22, gray)
// キャンバス
rect(4, 6, 20, 17, sky)
rect(4, 6, 20, 1, gray); rect(4, 6, 1, 17, gray)
disc(18.5, 11.5, 3.2, yellow)
disc(17.5, 11.5, 2.2, red)
for x in 5..<24 {
    let h = Int(4.5 + 2.5 * sin(Double(x) / 3.0))
    rect(x, 22 - h, 1, h + 1, x % 2 == 0 ? green : lime)
}
rect(5, 21, 19, 2, blue)
// ブラシ（右上から左下へ）
for i in 0..<11 {
    let x = 30 - i, y = 1 + i
    rect(x - 1, y, 3, 1, i < 6 ? olive : (i < 8 ? face : black))
}
rect(18, 12, 3, 2, black)
rect(17, 14, 2, 2, red)
rect(16, 15, 2, 1, red)

/// 32×32 のドット絵を size×size に最近傍で拡大・縮小して PNG にする。
func png(size s: Int) -> Data? {
    var out = [UInt32](repeating: 0, count: s * s)
    for y in 0..<s { for x in 0..<s { out[y * s + x] = px[(y * n / s) * n + (x * n / s)] } }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData),
          let cg = CGImage(width: s, height: s, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s * 4, space: cs,
                           bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    guard let data = png(size: size) else { fatalError("icon \(name) failed") }
    try data.write(to: outDir.appendingPathComponent(name + ".png"))
}
print("icon written to \(outDir.path)")
