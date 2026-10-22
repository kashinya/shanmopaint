import AppKit
import PaintCore

/// テキストツールの書式（Win98 のフォントツールバー相当）。
struct TextStyle: Equatable {
    var family = TextStyle.defaultFamily
    var size: CGFloat = 16
    var bold = false
    var italic = false
    var underline = false
    /// なめらか（アンチエイリアス）。オフにすると Win98 っぽいギザギザ文字。
    var smooth = true
    /// Skitch 風：白いふち取りと影
    var outline = false

    /// ふち取りの太さ（ピクセル）
    var outlineWidth: CGFloat { max(2, (size * 0.12).rounded()) }

    static var defaultFamily: String {
        let families = NSFontManager.shared.availableFontFamilies
        for f in ["Hiragino Sans", "Hiragino Kaku Gothic ProN", "Osaka"] where families.contains(f) { return f }
        return NSFont.systemFont(ofSize: 12).familyName ?? "Helvetica"
    }

    func font(scale: CGFloat) -> NSFont {
        let fm = NSFontManager.shared
        let pt = max(1, size * scale)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let f = fm.font(withFamily: family, traits: traits, weight: 5, size: pt) { return f }
        // 指定の太字・斜体がないフォントは、ある範囲で変換する
        var f = fm.font(withFamily: family, traits: [], weight: 5, size: pt) ?? NSFont.systemFont(ofSize: pt)
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    func attributes(scale: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        // タブ位置も表示倍率に合わせる（入力中と確定後で位置がずれないように）
        let para = NSMutableParagraphStyle()
        para.tabStops = []
        para.defaultTabInterval = 28 * scale
        var a: [NSAttributedString.Key: Any] = [.font: font(scale: scale), .foregroundColor: color, .paragraphStyle: para]
        if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    /// 入力中の見た目（ふち取りは近似：塗り＋細い白ふち＋影）。
    func previewAttributes(scale: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        var a = attributes(scale: scale, color: color)
        if outline {
            a[.strokeColor] = NSColor.white
            a[.strokeWidth] = -4.0
            let sh = NSShadow()
            sh.shadowOffset = NSSize(width: 0, height: -2 * scale)
            sh.shadowBlurRadius = 3 * scale
            sh.shadowColor = NSColor(white: 0, alpha: 0.45)
            a[.shadow] = sh
        }
        return a
    }

    /// 文字列を幅 width で折り返して、乗算済みアルファの Bitmap に描く。
    /// ふち取り・影の分、四方に margin ピクセルの余白を付けて返す（文字の原点は (margin, margin)）。
    func render(_ text: String, width: Int, minHeight: Int, color: NSColor) -> (image: Bitmap, margin: Int)? {
        let attrs = attributes(scale: 1, color: color)
        let storage = NSTextStorage(string: text, attributes: attrs)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat(width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = max(minHeight, Int(used.maxY.rounded(.up)))
        let margin = outline ? Int(outlineWidth) + 8 : 0
        let glyphs = layout.glyphRange(for: container)
        let ow = outlineWidth
        let outlined = outline
        let image = BitmapIO.renderPremultiplied(width: width + 2 * margin, height: height + 2 * margin, antialias: smooth) { ctx in
            let g = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            let origin = NSPoint(x: margin, y: margin)
            if outlined {
                // 1 回目：影つきの太い白ふち（strokeWidth は文字サイズに対する % で、正の値は線だけ）
                let full = NSRange(location: 0, length: storage.length)
                storage.addAttributes([.strokeColor: NSColor.white, .strokeWidth: (ow * 2) / max(1, self.size) * 100], range: full)
                ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: NSColor(white: 0, alpha: 0.45).cgColor)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                // 2 回目：本体の塗り
                storage.removeAttribute(.strokeWidth, range: full)
                storage.removeAttribute(.strokeColor, range: full)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                ctx.endTransparencyLayer()
            } else {
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return image.map { ($0, margin) }
    }
}

/// テキストツールの入力欄。画像しかないクリップボードの ⌘V と、⌘B / ⌘I / ⌘U を受け持つ。
final class PaintTextView: NSTextView {
    var onPasteImage: (() -> Void)?
    var onStyleShortcut: ((String) -> Void)?

    private var clipboardHasOnlyImage: Bool {
        NSPasteboard.general.availableType(from: [.string]) == nil && Clipboard.hasImage
    }

    override func paste(_ sender: Any?) {
        if clipboardHasOnlyImage, let f = onPasteImage {
            f()
            return
        }
        super.paste(sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) && clipboardHasOnlyImage { return true }
        return super.validateMenuItem(menuItem)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let ch = event.charactersIgnoringModifiers?.lowercased(),
           ["b", "i", "u"].contains(ch), let f = onStyleShortcut {
            f(ch)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 縦書きにすると確定後の見た目と食い違うので、切り替えさせない
    override func changeLayoutOrientation(_ sender: Any?) {}
}

/// 浮かんでいる「フォント」パネル。テキストツールを選ぶと出てくる。
final class FontPanelController: NSObject {
    let panel: NSPanel
    var style: TextStyle { didSet { if style != oldValue { onChange?(style) } } }
    var onChange: ((TextStyle) -> Void)?

    private let familyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeBox = NSComboBox()
    private let boldButton = NSButton()
    private let italicButton = NSButton()
    private let underlineButton = NSButton()
    private let smoothBox = NSButton(checkboxWithTitle: "なめらか", target: nil, action: nil)
    private let outlineBox = NSButton(checkboxWithTitle: "ふち取り＋影（Skitch 風）", target: nil, action: nil)

    init(style: TextStyle) {
        self.style = style
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 44),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.title = "フォント"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        familyPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        familyPopup.selectItem(withTitle: style.family)
        familyPopup.target = self
        familyPopup.action = #selector(changed(_:))

        sizeBox.addItems(withObjectValues: [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72].map { "\($0)" })
        sizeBox.stringValue = "\(Int(style.size))"
        sizeBox.numberOfVisibleItems = 12
        sizeBox.target = self
        sizeBox.action = #selector(changed(_:))

        for (b, title, font) in [(boldButton, "B", NSFont.boldSystemFont(ofSize: 13)),
                                 (italicButton, "I", NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)),
                                 (underlineButton, "U", NSFont.systemFont(ofSize: 13))] {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .regularSquare
            b.title = title
            b.font = font
            b.target = self
            b.action = #selector(changed(_:))
        }
        underlineButton.attributedTitle = NSAttributedString(string: "U", attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: 13),
        ])
        smoothBox.target = self
        smoothBox.action = #selector(changed(_:))
        smoothBox.toolTip = "オフにすると、アンチエイリアスなしのドット文字になります"
        outlineBox.target = self
        outlineBox.action = #selector(changed(_:))
        outlineBox.toolTip = "白いふちと影を付けます。オンにすると太字・背景透明になります"

        let stack = NSStackView(views: [familyPopup, sizeBox, boldButton, italicButton, underlineButton, smoothBox, outlineBox])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        familyPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        sizeBox.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for b in [boldButton, italicButton, underlineButton] { b.widthAnchor.constraint(equalToConstant: 30).isActive = true }
        panel.contentView = stack
        sync()
    }

    private func sync() {
        familyPopup.selectItem(withTitle: style.family)
        sizeBox.stringValue = "\(Int(style.size))"
        boldButton.state = style.bold ? .on : .off
        italicButton.state = style.italic ? .on : .off
        underlineButton.state = style.underline ? .on : .off
        smoothBox.state = style.smooth ? .on : .off
        outlineBox.state = style.outline ? .on : .off
    }

    /// 外から書式を変えたとき（パネルの表示も合わせる）。
    func setStyle(_ s: TextStyle) {
        style = s
        sync()
    }

    @objc private func changed(_ sender: Any?) {
        var s = style
        if let f = familyPopup.titleOfSelectedItem { s.family = f }
        // 日本語入力のまま打った全角数字も受け付ける
        let raw = sizeBox.stringValue.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? sizeBox.stringValue
        if let v = Double(raw.trimmingCharacters(in: .whitespaces)), v >= 1, v <= 500 {
            s.size = CGFloat(v)
        } else {
            sizeBox.stringValue = "\(Int(style.size))"
        }
        s.bold = boldButton.state == .on
        s.italic = italicButton.state == .on
        s.underline = underlineButton.state == .on
        s.smooth = smoothBox.state == .on
        let wasOutline = s.outline
        s.outline = outlineBox.state == .on
        if s.outline && !wasOutline {
            // Skitch 風は太字が似合う
            s.bold = true
            boldButton.state = .on
        }
        style = s
        if (sender as AnyObject?) === sizeBox {
            // サイズを決めたら、続けて打つ文字がキャンバスの入力欄に入るよう戻す
            panel.makeFirstResponder(nil)
            NSApp.mainWindow?.makeKey()
        }
    }

    func show(near window: NSWindow) {
        if !panel.isVisible {
            let f = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 20, y: f.maxY - 60))
        }
        panel.orderFront(nil)
    }

    func hide() { panel.orderOut(nil) }
}
