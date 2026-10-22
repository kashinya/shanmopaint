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
    private var fileFormat: BitmapIO.Format = .png
    private(set) var zoom: CGFloat = 1
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
        window.minSize = NSSize(width: 520, height: 440)
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
        mainView.colorBox.onHover = { [weak self] s in self?.statusBar.hint = s }
        engine.listener = { [weak self] e in self?.handle(e) }
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
            if engine.tool == .text { fontPanel.show(near: window) } else { fontPanel.hide() }
            canvasView.applyTextStyle()
            canvasView.needsDisplay = true
            window.invalidateCursorRects(for: canvasView)
        case .colors:
            mainView.colorBox.needsDisplay = true
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
        statusBar.hint = ToolInfo.name(t) + ": " + ToolInfo.hint(t)
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
        if let bmp = textStyle.render(s, width: box.width, minHeight: box.height, color: Win98.color(engine.primary)) {
            engine.commitText(bmp, at: box.origin)
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

    @objc func paste(_ sender: Any?) {
        commitText()
        guard let img = Clipboard.readImage() else {
            NSSound.beep()
            statusBar.hint = "クリップボードに画像がありません。"
            return
        }
        let before = engine.canvas.size
        let frame = engine.paste(img, visibleOrigin: canvasView.visibleCanvasOrigin)
        afterPaste(frame: frame, canvasBefore: before)
    }

    @objc func pasteAsNewImage(_ sender: Any?) {
        commitText()
        guard let img = Clipboard.readImage() else {
            NSSound.beep()
            statusBar.hint = "クリップボードに画像がありません。"
            return
        }
        engine.pasteAsNewImage(img)
        canvasView.scrollToCenter(IPoint(0, 0))
        statusBar.hint = "クリップボードの画像（\(img.width)×\(img.height)）をそのままキャンバスにしました。"
    }

    @objc func pasteAtPosition(_ sender: Any?) {
        commitText()
        guard let img = Clipboard.readImage() else {
            NSSound.beep()
            statusBar.hint = "クリップボードに画像がありません。"
            return
        }
        guard let pos = Dialogs.pastePosition(image: img.size, canvas: engine.canvas.size,
                                              initial: canvasView.visibleCanvasOrigin) else { return }
        let before = engine.canvas.size
        engine.paste(img, at: pos.origin, growCanvas: pos.growCanvas)
        afterPaste(frame: IRect(origin: pos.origin, size: img.size), canvasBefore: before)
    }

    private func afterPaste(frame: IRect, canvasBefore: ISize) {
        let after = engine.canvas.size
        if after != canvasBefore {
            canvasView.scrollToCenter(IPoint(0, 0))
            statusBar.hint = "キャンバスを画像に合わせて \(after.width)×\(after.height) にしました。そのまま編集・保存できます。"
        } else {
            canvasView.scrollToVisible(canvasView.viewRect(frame))
            statusBar.hint = "ドラッグか矢印キー（shift で 10 ピクセル）で位置を決め、外側をクリックで確定します。"
        }
        window.makeFirstResponder(canvasView)
    }

    @objc func delete(_ sender: Any?) {
        commitText()
        engine.deleteSelection()
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
            statusBar.hint = "\(url.lastPathComponent)（\(b.width)×\(b.height)）を開きました。"
            return true
        } catch {
            Dialogs.error(error.localizedDescription, window: window)
            return false
        }
    }

    func handleDrop(_ url: URL, at point: IPoint, option: Bool) {
        if option {
            // option を押しながらドロップ：その位置に貼り付け
            do {
                let b = try BitmapIO.load(url)
                let before = engine.canvas.size
                engine.paste(b, at: point, growCanvas: true)
                afterPaste(frame: IRect(origin: point, size: b.size), canvasBefore: before)
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
        if !asNew, let url = fileURL {
            return write(engine.flattened(), to: url, format: fileFormat, markSaved: true)
        }
        let defaultName = (fileURL?.deletingPathExtension().lastPathComponent ?? "無題")
        guard let (url, format) = runSavePanel(title: "名前を付けて保存", defaultName: defaultName, format: fileFormat) else { return false }
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
            let frame = engine.paste(b, visibleOrigin: canvasView.visibleCanvasOrigin)
            afterPaste(frame: frame, canvasBefore: before)
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
        guard engine.isModified else { return true }
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
        fontPanel.hide()
    }

    func windowDidResignKey(_ notification: Notification) {}

    // MARK: - メニューの有効・無効

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(paintUndo(_:)):
            if isEditingText, canvasView.textView?.undoManager?.canUndo == true { return true }
            return engine.canUndo || canvasView.textView != nil
        case #selector(paintRedo(_:)):
            if isEditingText, canvasView.textView?.undoManager?.canRedo == true { return true }
            return engine.canRedo
        case #selector(cut(_:)), #selector(delete(_:)), #selector(cropToSelection(_:)):
            return engine.hasSelection
        case #selector(copyToFile(_:)):
            item.title = engine.hasSelection ? "選択範囲をファイルへ保存…" : "画像をファイルへ保存…"
            return true
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
