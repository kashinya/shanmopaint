import AppKit
import ImageIO
import PaintCore
import UniformTypeIdentifiers

/// Bitmap ⇄ CGImage・ファイル・クリップボード。
enum BitmapIO {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 0xAARRGGBB（リトルエンディアンで B,G,R,A の並び）として解釈する。
    static func bitmapInfo(premultiplied: Bool) -> UInt32 {
        let alpha = premultiplied ? CGImageAlphaInfo.premultipliedFirst : CGImageAlphaInfo.noneSkipFirst
        return alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    }

    static func cgImage(_ b: Bitmap, premultiplied: Bool = false) -> CGImage? {
        let data = b.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: b.width, height: b.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: b.width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo(premultiplied: premultiplied)),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// CGImage を不透明な Bitmap に（半透明は background の上に合成）。
    static func bitmap(from cg: CGImage, background: Pixel = Colors.white) -> Bitmap? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt32](repeating: background | 0xFF00_0000, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: colorSpace,
                                      bitmapInfo: bitmapInfo(premultiplied: true)) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var b = Bitmap(width: w, height: h, pixels: px)
        b.makeOpaque()
        return b
    }

    /// 乗算済みアルファのまま書き込める描画先を用意して、描画後に Bitmap にする（テキスト用）。
    static func renderPremultiplied(width: Int, height: Int, antialias: Bool,
                                    _ draw: (CGContext) -> Void) -> Bitmap? {
        guard width > 0, height > 0 else { return nil }
        var px = [UInt32](repeating: 0, count: width * height)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: bitmapInfo(premultiplied: true)) else { return false }
            ctx.setShouldAntialias(antialias)
            ctx.setAllowsAntialiasing(antialias)
            ctx.setShouldSmoothFonts(false)
            ctx.interpolationQuality = .none
            // 上を原点にする
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
            return true
        }
        return ok ? Bitmap(width: width, height: height, pixels: px) : nil
    }

    // MARK: - ファイル

    enum IOError: LocalizedError {
        case unreadable(URL)
        case unwritable(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let u): return "「\(u.lastPathComponent)」は画像として開けませんでした。"
            case .unwritable(let u): return "「\(u.lastPathComponent)」に保存できませんでした。"
            }
        }
    }

    static func load(_ url: URL) throws -> Bitmap {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = orientedImage(src),
              let b = bitmap(from: img) else { throw IOError.unreadable(url) }
        return b
    }

    static func load(data: Data) -> Bitmap? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = orientedImage(src) else { return nil }
        return bitmap(from: img)
    }

    /// 写真の向き（EXIF の Orientation）を反映した画像。ImageIO はそのままだと向きを無視する。
    private static func orientedImage(_ src: CGImageSource) -> CGImage? {
        let idx = CGImageSourceGetPrimaryImageIndex(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if orientation != 1 && w > 0 && h > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, idx, opts as CFDictionary) { return img }
        }
        return CGImageSourceCreateImageAtIndex(src, idx, nil)
    }

    /// 保存できる形式。
    enum Format: String, CaseIterable {
        case png, jpeg, bmp, gif, tiff

        var type: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .bmp: return .bmp
            case .gif: return .gif
            case .tiff: return .tiff
            }
        }

        var label: String {
            switch self {
            case .png: return "PNG (*.png)"
            case .jpeg: return "JPEG (*.jpg)"
            case .bmp: return "ビットマップ (*.bmp)"
            case .gif: return "GIF (*.gif)"
            case .tiff: return "TIFF (*.tiff)"
            }
        }

        /// 拡張子から上書き保存の形式を決める。書き出せない形式（HEIC・PSD 等）なら nil。
        static func from(url: URL) -> Format? {
            switch url.pathExtension.lowercased() {
            case "png": return .png
            case "jpg", "jpeg": return .jpeg
            case "bmp": return .bmp
            case "gif": return .gif
            case "tif", "tiff": return .tiff
            default: return nil
            }
        }
    }

    static func save(_ b: Bitmap, to url: URL, format: Format) throws {
        guard let img = cgImage(b),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw IOError.unwritable(url) }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw IOError.unwritable(url) }
    }

    static func pngData(_ b: Bitmap) -> Data? {
        guard let img = cgImage(b) else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

/// システムのクリップボード。
enum Clipboard {
    static var pasteboard: NSPasteboard { .general }

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.bmp.identifier),
    ]

    /// クリップボードに貼り付けられそうな画像があるか（メニューの有効・無効用。型だけ見て中身は読まない）。
    static var hasImage: Bool {
        let pb = pasteboard
        if pb.availableType(from: [.fileURL]) != nil { return true }
        if pb.availableType(from: imageTypes) != nil { return true }
        return NSImage.canInit(with: pb)
    }

    /// クリップボードの画像を読む（ピクセル寸法そのまま）。
    static func readImage() -> Bitmap? {
        let pb = pasteboard
        // Finder でコピーしたファイル：ファイルの中身だけを使う
        // （画像でないファイルのときに、一緒に入っている Finder のアイコン画像を貼らないため）
        if pb.availableType(from: [.fileURL]) != nil {
            guard let url = imageFileURL(pb) else { return nil }
            return try? BitmapIO.load(url)
        }
        // スクリーンショット・ブラウザ等の画像データ
        for t in imageTypes {
            if let d = pb.data(forType: t), let b = BitmapIO.load(data: d) { return b }
        }
        // それ以外（PDF 等）は NSImage 経由で、いちばん細かい表現の大きさで
        if let img = NSImage(pasteboard: pb) {
            var size = img.size
            for rep in img.representations where rep.pixelsWide > 0 {
                size = NSSize(width: max(size.width, CGFloat(rep.pixelsWide)), height: max(size.height, CGFloat(rep.pixelsHigh)))
            }
            var rect = NSRect(origin: .zero, size: size)
            if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return BitmapIO.bitmap(from: cg)
            }
        }
        return nil
    }

    static func write(_ b: Bitmap) {
        guard let img = BitmapIO.cgImage(b) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        let pb = pasteboard
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    private static func imageFileURL(_ pb: NSPasteboard) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return (pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?.first
    }
}
