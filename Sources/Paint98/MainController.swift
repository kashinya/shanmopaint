import AppKit
import PaintCore
import UniformTypeIdentifiers

/// ウインドウ 1 枚分のペイント。メニューの操作はここに届く。
final class MainController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let zoomLevels: [CGFloat] = [0.25, 0.5, 1, 2, 4, 6, 8]
    static let defaultCanvasSize = ISize(640, 400)

    let engine = PaintEngine(width: MainController.defaultCanvasSize.width, height: MainController.defaultCanvasSize.height)
    let window: NSWindow
    let mainView: MainView
    var canvasView: CanvasView { mainView.canvasView }
    var statusBar: StatusBarView { mainView.statusBar }

    private(set) var fileURL: URL?
    /// 上書き保存できる形式。開いたファイルが書き出せない形式（HEIC 等）なら nil にして、⌘S で保存パネルを出す。
    private var fileFormat: BitmapIO.Format? = .png
    private(set) var zoom: CGFloat = 1
    /// ウインドウを閉じた（保存の確認は済んでいる）。
    private(set) var isClosed = false
    private var editingPaletteIndex: Int?

    var textStyle = TextStyle() {
        didSet { canvasView.applyTextStyle() }
    }
    private lazy var fontPanel: FontPanelController = {
        let c = FontPanelController(style: textStyle)
        c.onChange = { [weak self] s in self?.textStyle = s }
        return c
    }()

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        mainView = MainView(engine: engine)
        super.init()
        window.contentView = mainView
        window.delegate = self
        window.minSize = NSSize(width: 600, height: 480)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.setFrameAutosaveName("Paint98Window")
        window.tabbingMode = .disallowed

        canvasView.controller = self
        mainView.toolbox.onToolChosen = { [weak self] t in self?.chooseTool(t) }
        mainView.toolbox.onHover = { [weak self] s in self?.statusBar.hint = s }
        mainView.toolbox.onOptionsChanged = { [weak self] in self?.optionsChanged() }
        mainView.colorBox.onEditColor = { [weak self] i in self?.editColor(index: i) }
        mainView.colorBox.onPick = { [weak self] in self?.editingPaletteIndex = nil }
        mainView.skitchBar.onToolChosen = { [weak self] t in self?.chooseTool(t) }
        mainView.skitchBar.onHover = { [weak self] s in self?.statusBar.hint = s }
        mainView.skitchBar.onChanged = { [weak self] in
            guard let self = self else { return }
            self.updateDefaultTextBoxSize()
            self.canvasView.applyTextStyle()
            self.canvasView.needsDisplay = true
        }
        if let saved = UserDefaults.standard.string(forKey: "skitchColor"), let p = Colors.parseHex(saved) {
            engine.skitchColor = p
        }
        mainView.colorBox.onHover = { [weak self] s in self?.statusBar.hint = s }
        engine.listener = { [weak self] e in self?.handle(e) }
        engine.annotationRenderer = { a, clip in AnnotationRenderer.render(a, clip: clip) }
        engine.fitCanvasToPasteWhenPristine = UserDefaults.standard.object(forKey: "fitCanvasToPaste") as? Bool ?? true

        updateTitle()
        canvasView.updateStatus(nil)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvasView)
    }

    // MARK: - エンジンからの通知

    private func handle(_ e: EngineEvent) {
        switch e {
        case .display:
            canvasView.invalidateImage()
        case .canvasSize:
            canvasView.invalidateImage()
            canvasView.updateFrameSize()
            canvasView.updateStatus(nil)
        case .selection:
            canvasView.needsDisplay = true
            canvasView.updateStatus(nil)
        case .tool:
            mainView.toolbox.needsDisplay = true
            mainView.skitchBar.needsDisplay = true
            // フォントパネルはペイントのテキストツール用（Skitch の文字は太字・白ふちで固定）
            if engine.tool == .text { fontPanel.show(near: window) } else { fontPanel.hide() }
            updateDefaultTextBoxSize()
            canvasView.applyTextStyle()
            canvasView.needsDisplay = true
            window.invalidateCursorRects(for: canvasView)
        case .colors:
            mainView.colorBox.needsDisplay = true
            mainView.skitchBar.needsDisplay = true
            UserDefaults.standard.set(Colors.hexString(engine.skitchColor), forKey: "skitchColor")
            canvasView.applyTextStyle()
        case .textBox:
            canvasView.syncTextView()
        case .history:
            updateTitle()
        case .magnify(let level, let center):
            setZoom(CGFloat(level), center: center)
        }
    }

    private func updateTitle() {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? "無題"
        window.title = "\(name) - ペイント"
        window.representedURL = fileURL
        window.isDocumentEdited = engine.isModified
    }

    // MARK: - 道具

    func chooseTool(_ t: Tool) {
        commitText()
        engine.setTool(t)
        if canvasView.textView == nil { window.makeFirstResponder(canvasView) }
        // 閉じたフォントパネルは、テキストツールをもう一度押せば出る
        if t == .text { fontPanel.show(near: window) }
        statusBar.hint = ToolInfo.name(t) + ": " + ToolInfo.hint(t)
    }

    /// Skitch の文字の書式（太字・白ふち・影。大きさは Skitch ツールバーで選ぶ）。
    var skitchTextStyle: TextStyle {
        var s = TextStyle()
        s.bold = true
        s.outline = true
        s.size = CGFloat(ToolOptions.skitchTextSizes[min(ToolOptions.skitchTextSizes.count - 1, max(0, engine.options.skitchTextSize))])
        return s
    }

    /// 今の道具で使う文字の書式と色。
    var activeTextStyle: TextStyle { engine.tool == .skitchText ? skitchTextStyle : textStyle }
    var activeTextColor: NSColor { Win98.color(engine.tool == .skitchText ? engine.skitchColor : engine.primary) }

    /// クリックだけで作る入力枠の大きさを、文字の大きさに合わせる。
    func updateDefaultTextBoxSize() {
        let s = activeTextStyle.size
        engine.defaultTextBoxSize = ISize(Int(max(200, s * 9)), Int((s * 1.45).rounded(.up)))
    }

    /// 入力中の ⌘B / ⌘I / ⌘U（ペイントのテキストツールだけ）。
    func toggleTextStyle(_ key: String) {
        guard engine.tool == .text else { return }
        var s = textStyle
        switch key {
        case "b": s.bold.toggle()
        case "i": s.italic.toggle()
        case "u": s.underline.toggle()
        default: return
        }
        textStyle = s
        fontPanel.setStyle(s)
    }

    private func optionsChanged() {
        if engine.tool == .magnifier {
            setZoom(CGFloat(engine.options.magnification), center: nil)
        }
        canvasView.applyTextStyle()
        canvasView.needsDisplay = true
    }

    /// テキスト入力中なら確定する。
    func commitText() {
        guard let tv = canvasView.textView, let box = engine.textBox else { return }
        let s = tv.string
        if s.isEmpty {
            engine.cancelText()
            return
        }
        if let r = activeTextStyle.render(s, width: box.width, minHeight: box.height, color: activeTextColor) {
            // ふち取り・影の分だけ外側に余白がある。不透明の背景は枠の中だけ塗る
            engine.commitText(r.image, at: IPoint(box.x - r.margin, box.y - r.margin),
                              background: IRect(x: box.x, y: box.y, width: box.width, height: r.image.height - 2 * r.margin))
        } else {
            engine.cancelText()
        }
    }

    private var isEditingText: Bool {
        guard let tv = canvasView.textView else { return false }
        return window.firstResponder === tv
    }

    // MARK: - 表示倍率

    func setZoom(_ z: CGFloat, center: IPoint?) {
        commitText()
        let c = center ?? {
            let v = canvasView.visibleRect
            return canvasView.canvasPoint(NSPoint(x: v.midX, y: v.midY)).pixel
        }()
        zoom = z
        engine.zoom = Double(z)
        canvasView.zoom = z
        canvasView.scrollToCenter(c)
        mainView.toolbox.needsDisplay = true
        statusBar.hint = "表示倍率 \(z < 1 ? "\(Int(z * 100))%" : "\(Int(z))x")"
    }

    @objc func zoomIn(_ sender: Any?) {
        if let next = Self.zoomLevels.first(where: { $0 > zoom }) { setZoom(next, center: nil) }
    }

    @objc func zoomOut(_ sender: Any?) {
        if let prev = Self.zoomLevels.last(where: { $0 < zoom }) { setZoom(prev, center: nil) }
    }

    @objc func actualSize(_ sender: Any?) { setZoom(1, center: nil) }

    @objc func toggleGrid(_ sender: Any?) { canvasView.showGrid.toggle() }
    @objc func toggleToolbox(_ sender: Any?) { mainView.showToolbox.toggle() }
    @objc func toggleColorBox(_ sender: Any?) { mainView.showColorBox.toggle() }
    @objc func toggleStatusBar(_ sender: Any?) { mainView.showStatusBar.toggle() }
    @objc func toggleSkitchBar(_ sender: Any?) { mainView.showSkitchBar.toggle() }

    // MARK: - 編集

    @objc func paintUndo(_ sender: Any?) {
        if isEditingText, let um = canvasView.textView?.undoManager, um.canUndo {
            um.undo()
            return
        }
        commitText()
        engine.undo()
    }

    @objc func paintRedo(_ sender: Any?) {
        if isEditingText, let um = canvasView.textView?.undoManager, um.canRedo {
            um.redo()
            return
        }
        commitText()
        engine.redo()
    }

    @objc func copy(_ sender: Any?) {
        commitText()
        let img = engine.copyImage()
        Clipboard.write(img)
        statusBar.hint = engine.hasSelection
            ? "選択範囲（\(img.width)×\(img.height)）をコピーしました。"
            : "選択範囲がないので、画像全体（\(img.width)×\(img.height)）をコピーしました。"
    }

    @objc func cut(_ sender: Any?) {
        commitText()
        guard let img = engine.cut() else { NSSound.beep(); return }
        Clipboard.write(img)
        statusBar.hint = "選択範囲（\(img.width)×\(img.height)）を切り取りました。"
    }

    /// ⌘V の行き先。文字入力中でクリップボードに文字があれば入力欄へ、そうでなければ画像を貼る。
    @objc func paintPaste(_ sender: Any?) {
        if isEditingText, let tv = canvasView.textView, NSPasteboard.general.availableType(from: [.string]) != nil {
            tv.paste(sender)
            return
        }
        paste(sender)
    }

    @objc func paste(_ sender: Any?) {
        commitText()
        guard let img = Clipboard.readImage() else {
            NSSound.beep()
            statusBar.hint = "クリップボードに画像がありません。"
            return
        }
        let before = engine.canvas.size
        let r = engine.paste(img, visibleOrigin: canvasView.visibleCanvasOrigin)
        afterPaste(frame: r.frame, floating: r.floating, canvasBefore: before)
    }

    @objc func pasteAsNewImage(_ sender: Any?) {
        commitText()
        guard let img = Clipboard.readImage() else {
            NSSound.beep()
            statusBar.hint = "クリップボードに画像がありません。"
            return
        }
        engine.pasteAsNewImage(img)
        // 新しい画像なので、開いていたファイルに上書きしないよう「無題」にする
        fileURL = nil
        fileFormat = .png
        updateTitle()
        canvasView.scrollToCenter(IPoint(0, 0))
        statusBar.hint = "クリップボードの画像（\(img.width)×\(img.height)）を新しいキャンバスにしました。"
    }

    @objc func pasteAtPosition(_ sender: Any?) {
        commitText()
        guard let img = Clipboard.readImage() else {
            NSSound.beep()
            statusBar.hint = "クリップボードに画像がありません。"
            return
        }
        let initial = PastePlacement.plan(image: img.size, canvas: engine.canvas.size, pristine: false,
                                          fitWhenPristine: false, visibleOrigin: canvasView.visibleCanvasOrigin).origin
        guard let pos = Dialogs.pastePosition(image: img.size, canvas: engine.canvas.size, initial: initial) else { return }
        pasteFloating(img, at: pos.origin, growCanvas: pos.growCanvas)
    }

    /// 指定位置に浮かせて貼る（位置を指定して貼り付け・option+ドロップ）。
    private func pasteFloating(_ img: Bitmap, at origin: IPoint, growCanvas: Bool) {
        let before = engine.canvas.size
        guard let frame = engine.paste(img, at: origin, growCanvas: growCanvas) else {
            Dialogs.error("キャンバスが大きくなりすぎます。",
                          info: "広げたあとのキャンバスが \(PaintEngine.maxCanvasSide) ピクセルを超えないように、位置を指定してください。",
                          window: window)
            return
        }
        afterPaste(frame: frame, floating: true, canvasBefore: before)
    }

    private func afterPaste(frame: IRect, floating: Bool, canvasBefore: ISize) {
        let after = engine.canvas.size
        if !floating {
            canvasView.scrollToCenter(IPoint(0, 0))
            statusBar.hint = after != canvasBefore
                ? "キャンバスを画像に合わせて \(after.width)×\(after.height) にしました。そのまま編集・保存できます。"
                : "貼り付けました（\(after.width)×\(after.height)）。"
        } else {
            canvasView.scrollToVisible(canvasView.viewRect(frame).insetBy(dx: -8, dy: -8))
            let grew = after != canvasBefore ? "キャンバスを \(after.width)×\(after.height) に広げました。" : ""
            statusBar.hint = grew + "ドラッグか矢印キー（shift で 10 ピクセル）で位置を決め、外側をクリックか return で確定します。"
        }
        mainView.toolbox.needsDisplay = true
        window.makeFirstResponder(canvasView)
    }

    @objc func delete(_ sender: Any?) {
        commitText()
        if engine.annotation != nil { engine.deleteAnnotation() } else { engine.deleteSelection() }
    }

    @objc func selectAll(_ sender: Any?) {
        commitText()
        engine.selectAll()
        statusBar.hint = "画像全体を選択しました。"
    }

    @objc func cropToSelection(_ sender: Any?) {
        commitText()
        engine.cropToSelection()
    }

    @objc func toggleFitPaste(_ sender: Any?) {
        engine.fitCanvasToPasteWhenPristine.toggle()
        UserDefaults.standard.set(engine.fitCanvasToPasteWhenPristine, forKey: "fitCanvasToPaste")
    }

    // MARK: - イメージ

    @objc func flipRotate(_ sender: Any?) {
        commitText()
        guard let choice = Dialogs.flipRotate() else { return }
        switch choice {
        case .horizontal: engine.flipHorizontal()
        case .vertical: engine.flipVertical()
        case .rotate90: engine.rotateClockwise()
        case .rotate180: engine.rotate180()
        case .rotate270: engine.rotateCounterClockwise()
        }
    }

    @objc func stretch(_ sender: Any?) {
        commitText()
        guard let (x, y) = Dialogs.stretch() else { return }
        engine.stretch(percentX: x, percentY: y)
    }

    @objc func invertColors(_ sender: Any?) {
        commitText()
        engine.invertColors()
    }

    @objc func canvasSize(_ sender: Any?) {
        commitText()
        guard let s = Dialogs.canvasSize(current: engine.canvas.size) else { return }
        engine.resizeCanvas(to: s)
    }

    @objc func clearImage(_ sender: Any?) {
        commitText()
        engine.clearImage()
    }

    @objc func toggleOpaque(_ sender: Any?) {
        engine.options.transparentBackground.toggle()
        canvasView.applyTextStyle()
        mainView.toolbox.needsDisplay = true
    }

    // MARK: - 色

    @objc func editColors(_ sender: Any?) { editColor(index: nil) }

    @objc func swapColors(_ sender: Any?) { engine.swapColors() }

    private func editColor(index: Int?) {
        editingPaletteIndex = index
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = Win98.color(index.map { mainView.colorBox.palette[$0] } ?? engine.primary)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        let p = Win98.pixel(sender.color)
        if let i = editingPaletteIndex {
            mainView.colorBox.palette[i] = p
        }
        engine.primary = p
        mainView.colorBox.needsDisplay = true
    }

    // MARK: - ファイル

    @objc func paintNew(_ sender: Any?) {
        commitText()
        guard confirmDiscard() else { return }
        engine.newImage(size: Self.defaultCanvasSize)
        fileURL = nil
        updateTitle()
        setZoom(1, center: IPoint(0, 0))
        statusBar.hint = "新しいキャンバスです。このまま貼り付けると、キャンバスが画像と同じ大きさになります。"
    }

    @objc func paintOpen(_ sender: Any?) {
        commitText()
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, confirmed: true)
    }

    /// Finder から開く・ドロップ・起動時の引数など。
    @discardableResult
    func open(_ url: URL, confirmed: Bool = false) -> Bool {
        commitText()
        if !confirmed && !confirmDiscard() { return false }
        do {
            let b = try BitmapIO.load(url)
            engine.load(b)
            fileURL = url
            fileFormat = BitmapIO.Format.from(url: url)
            updateTitle()
            setZoom(1, center: IPoint(0, 0))
            statusBar.hint = fileFormat == nil
                ? "\(url.lastPathComponent) は上書き保存できない形式なので、保存するときは名前を付けて保存します。"
                : "\(url.lastPathComponent)（\(b.width)×\(b.height)）を開きました。"
            return true
        } catch {
            Dialogs.error(error.localizedDescription, window: window)
            return false
        }
    }

    func handleDrop(_ url: URL, at point: IPoint, option: Bool) {
        commitText()
        if option {
            // option を押しながらドロップ：その位置に貼り付け
            do {
                pasteFloating(try BitmapIO.load(url), at: point, growCanvas: true)
            } catch {
                Dialogs.error(error.localizedDescription, window: window)
            }
        } else {
            open(url)
        }
    }

    @objc func paintSave(_ sender: Any?) {
        commitText()
        _ = save(asNew: false)
    }

    @objc func paintSaveAs(_ sender: Any?) {
        commitText()
        _ = save(asNew: true)
    }

    /// 保存できたら true。
    private func save(asNew: Bool) -> Bool {
        if !asNew, let url = fileURL, let format = fileFormat {
            return write(engine.flattened(), to: url, format: format, markSaved: true)
        }
        let defaultName = (fileURL?.deletingPathExtension().lastPathComponent ?? "無題")
        guard let (url, format) = runSavePanel(title: "名前を付けて保存", defaultName: defaultName,
                                               format: fileFormat ?? .png) else { return false }
        guard write(engine.flattened(), to: url, format: format, markSaved: true) else { return false }
        fileURL = url
        fileFormat = format
        updateTitle()
        return true
    }

    private func write(_ b: Bitmap, to url: URL, format: BitmapIO.Format, markSaved: Bool) -> Bool {
        do {
            try BitmapIO.save(b, to: url, format: format)
            if markSaved { engine.markSaved() }
            statusBar.hint = "\(url.lastPathComponent) に保存しました（\(b.width)×\(b.height)）。"
            return true
        } catch {
            Dialogs.error(error.localizedDescription, window: window)
            return false
        }
    }

    private func runSavePanel(title: String, defaultName: String, format: BitmapIO.Format) -> (URL, BitmapIO.Format)? {
        let panel = NSSavePanel()
        panel.title = title
        panel.canCreateDirectories = true
        let chooser = FormatChooser(panel: panel, format: format)
        panel.accessoryView = chooser.view
        panel.nameFieldStringValue = defaultName + "." + (format.type.preferredFilenameExtension ?? "png")
        let ok = withExtendedLifetime(chooser) { panel.runModal() == .OK }
        guard ok, let url = panel.url else { return nil }
        return (url, chooser.format)
    }

    @objc func pasteFromFile(_ sender: Any?) {
        commitText()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.title = "ファイルから貼り付け"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let b = try BitmapIO.load(url)
            let before = engine.canvas.size
            let r = engine.paste(b, visibleOrigin: canvasView.visibleCanvasOrigin)
            afterPaste(frame: r.frame, floating: r.floating, canvasBefore: before)
        } catch {
            Dialogs.error(error.localizedDescription, window: window)
        }
    }

    @objc func copyToFile(_ sender: Any?) {
        commitText()
        let img = engine.copyImage()
        guard let (url, format) = runSavePanel(title: engine.hasSelection ? "選択範囲をファイルへ保存" : "画像をファイルへ保存",
                                               defaultName: "無題", format: .png) else { return }
        _ = write(img, to: url, format: format, markSaved: false)
    }

    /// 変更を捨ててよいか確かめる。続けてよければ true。
    func confirmDiscard() -> Bool {
        // 描きかけの多角形・曲線や浮いている矢印・スタンプも、失う前に確認する
        guard engine.isModified || engine.hasPendingShape else { return true }
        let name = fileURL?.lastPathComponent ?? "無題"
        let a = NSAlert()
        a.messageText = "\(name) への変更を保存しますか?"
        a.informativeText = "保存しないと、変更は失われます。"
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "キャンセル")
        let dont = a.addButton(withTitle: "保存しない")
        dont.keyEquivalent = "d"
        dont.keyEquivalentModifierMask = [.command]
        switch a.runModal() {
        case .alertFirstButtonReturn: return save(asNew: false)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: - ヘルプ

    @objc func showHelp(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "ペイント 98 の使い方"
        a.informativeText = """
        ■ 貼り付け（⌘V）
        ・新規のまっさらなキャンバスに貼ると、キャンバスが画像とぴったり同じ大きさになります（すぐ編集・保存できます）。
        ・画像がキャンバスより大きいときは、キャンバスを広げて左上に置きます。
        ・キャンバスの方が広いときは、画像が浮いた状態で置かれます。ドラッグか矢印キー（shift で 10 ピクセル）で位置を決め、外側をクリックか return で確定します。
        ・位置を数値で決めたいときは［編集］→［位置を指定して貼り付け…］（⇧⌘V）。
        ・画像そのものを新しいキャンバスにしたいときは［新規画像として貼り付け］（⌥⌘V）。

        ■ コピー（⌘C）・切り取り（⌘X）
        範囲選択・自由選択で選んだ部分をコピーします。選択していないときは画像全体をコピーします。

        ■ 文字（テキストツール）
        ドラッグで枠を作るかクリックして入力します。日本語入力もできます。フォントは「フォント」パネルで変えられます。枠の外をクリックすると確定します。

        ■ Skitch ツールバー（上の段）
        矢印・文字・四角・スタンプ。色は Skitch 専用（ペイントのパレットとは別）。
        置いた直後はつまみで直せます。外側をクリックで確定、delete で削除。

        ■ そのほか
        左クリック: 描画色 ／ 右クリック（control+クリック）: 背景色
        option+ドラッグ: 選択範囲の複製
        画像ファイルをウインドウにドロップ: 開く（option+ドロップでその位置に貼り付け）
        """
        a.runModal()
    }

    // MARK: - ウインドウ

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitText()
        return confirmDiscard()
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        fontPanel.hide()
    }

    @objc func showFontPanel(_ sender: Any?) { fontPanel.show(near: window) }

    var fontPanelVisible: Bool { fontPanel.panel.isVisible }

    func windowDidResignKey(_ notification: Notification) {}

    // MARK: - メニューの有効・無効

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // 文字の入力中は、⌘I などで入力が確定されて画像全体が変わってしまわないよう止めておく
        let destructive: [Selector] = [#selector(invertColors(_:)), #selector(flipRotate(_:)), #selector(stretch(_:)),
                                       #selector(clearImage(_:)), #selector(canvasSize(_:)), #selector(cropToSelection(_:))]
        if isEditingText, let a = item.action, destructive.contains(a) { return false }
        switch item.action {
        case #selector(paintUndo(_:)):
            if isEditingText, canvasView.textView?.undoManager?.canUndo == true { return true }
            return engine.canUndo || canvasView.textView != nil
        case #selector(paintRedo(_:)):
            if isEditingText, canvasView.textView?.undoManager?.canRedo == true { return true }
            return engine.canRedo
        case #selector(delete(_:)):
            return engine.hasSelection || engine.annotation != nil
        case #selector(cut(_:)), #selector(cropToSelection(_:)):
            return engine.hasSelection
        case #selector(copyToFile(_:)):
            item.title = engine.hasSelection ? "選択範囲をファイルへ保存…" : "画像をファイルへ保存…"
            return true
        case #selector(paintPaste(_:)):
            if isEditingText && NSPasteboard.general.availableType(from: [.string]) != nil { return true }
            return Clipboard.hasImage
        case #selector(paste(_:)), #selector(pasteAsNewImage(_:)), #selector(pasteAtPosition(_:)):
            return Clipboard.hasImage
        case #selector(toggleFitPaste(_:)):
            item.state = engine.fitCanvasToPasteWhenPristine ? .on : .off
        case #selector(toggleGrid(_:)):
            item.state = canvasView.showGrid ? .on : .off
            return zoom >= 4
        case #selector(toggleToolbox(_:)):
            item.state = mainView.showToolbox ? .on : .off
        case #selector(toggleColorBox(_:)):
            item.state = mainView.showColorBox ? .on : .off
        case #selector(toggleStatusBar(_:)):
            item.state = mainView.showStatusBar ? .on : .off
        case #selector(toggleSkitchBar(_:)):
            item.state = mainView.showSkitchBar ? .on : .off
        case #selector(toggleOpaque(_:)):
            item.state = engine.options.transparentBackground ? .off : .on
        case #selector(zoomIn(_:)):
            return zoom < Self.zoomLevels.last!
        case #selector(zoomOut(_:)):
            return zoom > Self.zoomLevels.first!
        default:
            break
        }
        return true
    }
}

/// 保存パネルのファイル形式ポップアップ。
private final class FormatChooser: NSObject {
    let view: NSView
    private(set) var format: BitmapIO.Format
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(panel: NSSavePanel, format: BitmapIO.Format) {
        self.panel = panel
        self.format = format
        let label = NSTextField(labelWithString: "ファイルの種類:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        popup.addItems(withTitles: BitmapIO.Format.allCases.map(\.label))
        popup.selectItem(at: BitmapIO.Format.allCases.firstIndex(of: format) ?? 0)
        popup.target = self
        popup.action = #selector(changed(_:))
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        panel.allowedContentTypes = [format.type]
    }

    @objc private func changed(_ sender: NSPopUpButton) {
        format = BitmapIO.Format.allCases[sender.indexOfSelectedItem]
        guard let panel = panel else { return }
        panel.allowedContentTypes = [format.type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + (format.type.preferredFilenameExtension ?? "png")
    }
}
