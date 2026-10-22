import AppKit
import PaintCore

/// キャンバス（スクロールビューの中身）。描画・マウス・キー・テキスト入力枠を受け持つ。
final class CanvasView: NSView, NSTextViewDelegate {
    static let inset: CGFloat = 4

    /// キャンバスの右・下・右下にある大きさ変更つまみ。
    enum CanvasHandle { case right, bottom, corner }

    let engine: PaintEngine
    weak var controller: MainController?

    var zoom: CGFloat = 1 { didSet { updateFrameSize() } }
    var showGrid = false { didSet { needsDisplay = true } }
    private(set) var textView: NSTextView?

    private var cachedImage: CGImage?
    private var hover: NSPoint?
    private var airbrushTimer: Timer?
    private var dragging = false
    private var canvasResize: (handle: CanvasHandle, start: NSPoint, original: ISize, current: ISize)?
    private var tracking: NSTrackingArea?

    init(engine: PaintEngine) {
        self.engine = engine
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - 座標

    var canvasRect: NSRect {
        NSRect(x: Self.inset, y: Self.inset,
               width: CGFloat(engine.canvas.width) * zoom, height: CGFloat(engine.canvas.height) * zoom)
    }

    func canvasPoint(_ p: NSPoint) -> CanvasPoint {
        CanvasPoint(Double((p.x - Self.inset) / zoom), Double((p.y - Self.inset) / zoom))
    }

    func viewRect(_ r: IRect) -> NSRect {
        NSRect(x: Self.inset + CGFloat(r.x) * zoom, y: Self.inset + CGFloat(r.y) * zoom,
               width: CGFloat(r.width) * zoom, height: CGFloat(r.height) * zoom)
    }

    /// 見えている範囲の左上（キャンバスのピクセル座標）。
    var visibleCanvasOrigin: IPoint {
        let v = visibleRect
        let p = canvasPoint(v.origin).pixel
        return IPoint(max(0, p.x), max(0, p.y))
    }

    func updateFrameSize() {
        let r = canvasRect
        var size = NSSize(width: r.maxX + 16, height: r.maxY + 16)
        if let clip = enclosingScrollView?.contentSize {
            size.width = max(size.width, clip.width)
            size.height = max(size.height, clip.height)
        }
        if frame.size != size { setFrameSize(size) }
        positionTextView()
        needsDisplay = true
    }

    func invalidateImage() {
        cachedImage = nil
        needsDisplay = true
    }

    /// center（キャンバス座標）が見える範囲の真ん中に来るようにスクロール。
    func scrollToCenter(_ center: IPoint) {
        let vis = visibleRect.size
        let p = NSPoint(x: Self.inset + (CGFloat(center.x) + 0.5) * zoom - vis.width / 2,
                        y: Self.inset + (CGFloat(center.y) + 0.5) * zoom - vis.height / 2)
        scroll(NSPoint(x: max(0, p.x), y: max(0, p.y)))
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        Win98.workspace.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cr = canvasRect
        if cachedImage == nil { cachedImage = BitmapIO.cgImage(engine.renderDisplay()) }
        if let img = cachedImage {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.clip(to: cr)
            ctx.translateBy(x: cr.minX, y: cr.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: cr.width, height: cr.height))
            ctx.restoreGState()
        }
        if showGrid && zoom >= 4 { drawGrid(in: cr.intersection(dirtyRect)) }

        if let m = engine.marquee { dotted(viewRect(m)) }
        if let sel = engine.selection {
            let r = viewRect(sel.frame)
            dotted(r)
            Win98.navy.setFill()
            for h in SelectionHandle.allCases {
                let c = h.position(in: sel.frame)
                let p = NSPoint(x: Self.inset + CGFloat(c.x) * zoom, y: Self.inset + CGFloat(c.y) * zoom)
                NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4).fill()
            }
        }
        if let tb = engine.textBox { dotted(viewRect(tb).insetBy(dx: -1, dy: -1)) }
        if let a = engine.annotation, engine.tool == .arrow || engine.tool == .stamp {
            if case .stamp(_, let c, let r) = a.shape {
                dotted(viewRect(IRect(x: c.x - r, y: c.y - r, width: 2 * r + 1, height: 2 * r + 1)))
            }
            for hp in a.handles {
                let p = NSPoint(x: Self.inset + CGFloat(hp.x) * zoom, y: Self.inset + CGFloat(hp.y) * zoom)
                let r = NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                NSColor.white.setFill()
                r.fill()
                Win98.navy.setStroke()
                let b = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                b.lineWidth = 1
                b.stroke()
            }
        }

        if engine.tool == .eraser, let h = hover, !(textView != nil) {
            let cp = canvasPoint(h).pixel
            let s = engine.options.eraserSize, o = s / 2
            let r = viewRect(IRect(x: cp.x - o, y: cp.y - o, width: s, height: s))
            NSColor.black.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }

        if engine.selection == nil && textView == nil && engine.annotation == nil {
            Win98.navy.setFill()
            for h in [CanvasHandle.right, .bottom, .corner] { handleRect(h).fill() }
        }
        if let cz = canvasResize {
            dotted(NSRect(x: Self.inset, y: Self.inset, width: CGFloat(cz.current.width) * zoom,
                          height: CGFloat(cz.current.height) * zoom))
        }
    }

    private func drawGrid(in r: NSRect) {
        guard !r.isEmpty else { return }
        Win98.shadow.withAlphaComponent(0.6).setFill()
        let cr = canvasRect
        var x = cr.minX + (((r.minX - cr.minX) / zoom).rounded(.down)) * zoom
        while x <= r.maxX {
            NSRect(x: x, y: r.minY, width: 1, height: r.height).fill()
            x += zoom
        }
        var y = cr.minY + (((r.minY - cr.minY) / zoom).rounded(.down)) * zoom
        while y <= r.maxY {
            NSRect(x: r.minX, y: y, width: r.width, height: 1).fill()
            y += zoom
        }
    }

    /// 白と黒の点線の枠（Win98 の選択枠）。
    private func dotted(_ r: NSRect) {
        let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        NSColor.white.setStroke()
        p.stroke()
        p.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.black.setStroke()
        p.stroke()
    }

    private func handleRect(_ h: CanvasHandle) -> NSRect {
        let cr = canvasRect
        switch h {
        case .right: return NSRect(x: cr.maxX, y: cr.midY - 2, width: 4, height: 4)
        case .bottom: return NSRect(x: cr.midX - 2, y: cr.maxY, width: 4, height: 4)
        case .corner: return NSRect(x: cr.maxX, y: cr.maxY, width: 4, height: 4)
        }
    }

    private func canvasHandle(at p: NSPoint) -> CanvasHandle? {
        guard engine.selection == nil, textView == nil, engine.annotation == nil else { return nil }
        for h in [CanvasHandle.corner, .right, .bottom] where handleRect(h).insetBy(dx: -4, dy: -4).contains(p) {
            return h
        }
        return nil
    }

    // MARK: - マウス

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                      .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func modifiers(_ e: NSEvent) -> Modifiers {
        var m: Modifiers = []
        if e.modifierFlags.contains(.shift) { m.insert(.shift) }
        if e.modifierFlags.contains(.option) { m.insert(.option) }
        return m
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if textView != nil {
            // 入力枠の外をクリック：文字を確定（このクリックでは新しい枠を作らない）
            controller?.commitText()
            window?.makeFirstResponder(self)
            if engine.tool == .text { return }
        }
        window?.makeFirstResponder(self)
        if let h = canvasHandle(at: p) {
            canvasResize = (h, p, engine.canvas.size, engine.canvas.size)
            return
        }
        begin(event.modifierFlags.contains(.control) ? .secondary : .primary, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if textView != nil {
            controller?.commitText()
            window?.makeFirstResponder(self)
            if engine.tool == .text { return }
        }
        begin(.secondary, event)
    }

    private func begin(_ button: MouseButton, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragging = true
        engine.mouseDown(at: canvasPoint(p), button: button, modifiers: modifiers(event), clickCount: event.clickCount)
        if engine.isAirbrushing { startAirbrush() }
        if !engine.isDragging { dragging = false }
        updateStatus(p)
        cursor(at: p).set()
    }

    override func mouseDragged(with event: NSEvent) { drag(event) }
    override func rightMouseDragged(with event: NSEvent) { drag(event) }

    private func drag(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        if var cz = canvasResize {
            let dx = (p.x - cz.start.x) / zoom, dy = (p.y - cz.start.y) / zoom
            var w = cz.original.width, h = cz.original.height
            if cz.handle != .bottom { w = max(1, min(10000, cz.original.width + Int(dx.rounded()))) }
            if cz.handle != .right { h = max(1, min(10000, cz.original.height + Int(dy.rounded()))) }
            cz.current = ISize(w, h)
            canvasResize = cz
            controller?.statusBar.size = "\(w)×\(h)"
            autoscroll(with: event)
            needsDisplay = true
            return
        }
        guard dragging else { return }
        autoscroll(with: event)
        engine.mouseDragged(to: canvasPoint(p), modifiers: modifiers(event))
        updateStatus(p)
    }

    override func mouseUp(with event: NSEvent) { end(event) }
    override func rightMouseUp(with event: NSEvent) { end(event) }

    private func end(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let cz = canvasResize {
            canvasResize = nil
            if cz.current != cz.original { engine.resizeCanvas(to: cz.current) }
            needsDisplay = true
            updateStatus(p)
            return
        }
        guard dragging else { return }
        dragging = false
        stopAirbrush()
        engine.mouseUp(at: canvasPoint(p), modifiers: modifiers(event))
        updateStatus(p)
        cursor(at: p).set()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        updateStatus(p)
        cursor(at: p).set()
        if engine.tool == .eraser { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        controller?.statusBar.position = ""
        if engine.tool == .eraser { needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    func cursor(at p: NSPoint) -> NSCursor {
        if let h = canvasHandle(at: p) {
            switch h {
            case .right: return .resizeLeftRight
            case .bottom: return .resizeUpDown
            case .corner: return .crosshair
            }
        }
        let cp = canvasPoint(p)
        if engine.tool == .select || engine.tool == .freeSelect, let sel = engine.selection {
            if let h = engine.handle(at: cp) {
                switch h {
                case .left, .right: return .resizeLeftRight
                case .top, .bottom: return .resizeUpDown
                default: return .crosshair
                }
            }
            if sel.frame.contains(cp.pixel) { return dragging ? .closedHand : .openHand }
        }
        if let part = engine.annotationPart(at: cp) {
            switch part {
            case .body: return dragging ? .closedHand : .openHand
            default: return .crosshair
            }
        }
        return Icons.cursor(for: engine.tool)
    }

    private func startAirbrush() {
        stopAirbrush()
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.engine.isAirbrushing { self.engine.airbrushTick() } else { self.stopAirbrush() }
        }
        RunLoop.main.add(t, forMode: .common)
        airbrushTimer = t
    }

    private func stopAirbrush() {
        airbrushTimer?.invalidate()
        airbrushTimer = nil
    }

    func updateStatus(_ p: NSPoint?) {
        guard let sb = controller?.statusBar else { return }
        if let p = p {
            let cp = canvasPoint(p).pixel
            sb.position = engine.canvas.contains(cp.x, cp.y) ? "\(cp.x), \(cp.y)" : ""
        }
        if let s = engine.liveSize {
            sb.size = "\(s.width)×\(s.height)"
        } else if let sel = engine.selection {
            sb.size = "\(sel.frame.width)×\(sel.frame.height) @\(sel.frame.x),\(sel.frame.y)"
        } else {
            sb.size = "\(engine.canvas.width)×\(engine.canvas.height)"
        }
    }

    // MARK: - キー

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123 where engine.annotation != nil: engine.nudgeAnnotation(dx: -step, dy: 0)
        case 124 where engine.annotation != nil: engine.nudgeAnnotation(dx: step, dy: 0)
        case 125 where engine.annotation != nil: engine.nudgeAnnotation(dx: 0, dy: step)
        case 126 where engine.annotation != nil: engine.nudgeAnnotation(dx: 0, dy: -step)
        case 123 where engine.hasSelection: engine.nudgeSelection(dx: -step, dy: 0)
        case 124 where engine.hasSelection: engine.nudgeSelection(dx: step, dy: 0)
        case 125 where engine.hasSelection: engine.nudgeSelection(dx: 0, dy: step)
        case 126 where engine.hasSelection: engine.nudgeSelection(dx: 0, dy: -step)
        case 51, 117: // delete / forward delete
            if engine.annotation != nil {
                engine.deleteAnnotation()
            } else if engine.hasSelection {
                engine.deleteSelection()
            } else {
                NSSound.beep()
            }
        case 53, 36, 76: // esc / return / enter
            engine.finishPending()
        default:
            super.keyDown(with: event)
        }
        updateStatus(nil)
    }

    // MARK: - テキスト入力枠

    /// エンジンのテキスト枠に合わせて入力欄を作る・消す。
    func syncTextView() {
        if let box = engine.textBox {
            if textView == nil { createTextView(box) }
            positionTextView()
        } else if let tv = textView {
            textView = nil
            tv.delegate = nil
            tv.removeFromSuperview()
            window?.makeFirstResponder(self)
            needsDisplay = true
        }
    }

    private func createTextView(_ box: IRect) {
        let tv = NSTextView(frame: viewRect(box))
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.delegate = self
        addSubview(tv)
        textView = tv
        applyTextStyle()
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    func positionTextView() {
        guard let tv = textView, let box = engine.textBox else { return }
        let r = viewRect(box)
        tv.minSize = r.size
        tv.maxSize = NSSize(width: r.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.containerSize = NSSize(width: r.width, height: CGFloat.greatestFiniteMagnitude)
        tv.frame = NSRect(origin: r.origin, size: NSSize(width: r.width, height: max(r.height, tv.frame.height)))
        tv.sizeToFit()
    }

    /// フォント・色・背景を入力欄に反映（表示倍率に合わせて拡大）。
    func applyTextStyle() {
        guard let tv = textView, let controller = controller else { return }
        let style = controller.textStyle
        let attrs = style.previewAttributes(scale: zoom, color: Win98.color(engine.primary))
        tv.font = attrs[.font] as? NSFont
        tv.textColor = Win98.color(engine.primary)
        tv.insertionPointColor = Win98.color(engine.primary)
        tv.typingAttributes = attrs
        if let storage = tv.textStorage, storage.length > 0 {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
        tv.drawsBackground = !engine.options.transparentBackground
        tv.backgroundColor = Win98.color(engine.secondary)
        positionTextView()
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, var box = engine.textBox else { return }
        tv.sizeToFit()
        let needed = Int((tv.frame.height / zoom).rounded(.up))
        if needed > box.height {
            box.height = needed
            engine.updateTextBox(box)
        }
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            controller?.commitText()
            return true
        }
        return false
    }

    // MARK: - ファイルのドロップ

    private func droppedImageURL(_ info: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"],
        ]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImageURL(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedImageURL(sender) else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        controller?.handleDrop(url, at: canvasPoint(p).pixel, option: NSEvent.modifierFlags.contains(.option))
        return true
    }
}
