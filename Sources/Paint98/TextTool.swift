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
        var a: [NSAttributedString.Key: Any] = [.font: font(scale: scale), .foregroundColor: color]
        if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    /// 文字列を幅 width で折り返して、乗算済みアルファの Bitmap に描く。
    func render(_ text: String, width: Int, minHeight: Int, color: NSColor) -> Bitmap? {
        let storage = NSTextStorage(string: text, attributes: attributes(scale: 1, color: color))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat(width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = max(minHeight, Int(used.maxY.rounded(.up)))
        return BitmapIO.renderPremultiplied(width: width, height: height, antialias: smooth) { ctx in
            let g = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
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

    init(style: TextStyle) {
        self.style = style
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 44),
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

        let stack = NSStackView(views: [familyPopup, sizeBox, boldButton, italicButton, underlineButton, smoothBox])
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
    }

    @objc private func changed(_ sender: Any?) {
        var s = style
        if let f = familyPopup.titleOfSelectedItem { s.family = f }
        if let v = Double(sizeBox.stringValue.trimmingCharacters(in: .whitespaces)), v >= 1, v <= 500 { s.size = CGFloat(v) }
        s.bold = boldButton.state == .on
        s.italic = italicButton.state == .on
        s.underline = underlineButton.state == .on
        s.smooth = smoothBox.state == .on
        style = s
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
