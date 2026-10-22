import AppKit
import PaintCore

/// ウインドウの中身：道具箱・作業領域・カラーボックス・ステータスバーを並べる。
final class MainView: NSView {
    let toolbox = ToolboxView()
    let scrollView = NSScrollView()
    let canvasView: CanvasView
    let colorBox = ColorBoxView()
    let statusBar = StatusBarView()

    var showToolbox = true { didSet { needsLayout = true; needsDisplay = true } }
    var showColorBox = true { didSet { needsLayout = true; needsDisplay = true } }
    var showStatusBar = true { didSet { needsLayout = true; needsDisplay = true } }

    init(engine: PaintEngine) {
        canvasView = CanvasView(engine: engine)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        toolbox.engine = engine
        colorBox.engine = engine
        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Win98.workspace
        scrollView.autohidesScrollers = true
        for v in [toolbox, scrollView, colorBox, statusBar] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        var bottom = b.maxY
        statusBar.isHidden = !showStatusBar
        if showStatusBar {
            statusBar.frame = NSRect(x: 0, y: bottom - StatusBarView.height, width: b.width, height: StatusBarView.height)
            bottom -= StatusBarView.height
        }
        colorBox.isHidden = !showColorBox
        if showColorBox {
            colorBox.frame = NSRect(x: 0, y: bottom - ColorBoxView.height, width: b.width, height: ColorBoxView.height)
            bottom -= ColorBoxView.height
        }
        toolbox.isHidden = !showToolbox
        let left: CGFloat = showToolbox ? ToolboxView.width : 0
        toolbox.frame = NSRect(x: 0, y: 0, width: left, height: bottom)
        scrollView.frame = NSRect(x: left + 2, y: 2, width: max(10, b.width - left - 4), height: max(10, bottom - 4))
        canvasView.updateFrameSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        Win98.face.setFill()
        dirtyRect.fill()
        Win98.draw(.sunken, in: scrollView.frame.insetBy(dx: -2, dy: -2))
    }
}
