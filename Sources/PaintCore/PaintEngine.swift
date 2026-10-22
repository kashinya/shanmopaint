public enum Tool: String, CaseIterable {
    case freeSelect, select
    case eraser, fill
    case picker, magnifier
    case pencil, brush
    case airbrush, text
    case line, curve
    case rectangle, polygon
    case ellipse, roundedRectangle
    /// Skitch 風の矢印・スタンプ
    case arrow, stamp
}

public enum MouseButton {
    case primary, secondary
}

public struct Modifiers: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// 水平・垂直・45° / 正方形・正円
    public static let shift = Modifiers(rawValue: 1)
    /// 選択範囲をドラッグで複製（Win98 の Ctrl ドラッグ）
    public static let option = Modifiers(rawValue: 2)
}

public enum EngineEvent: Equatable {
    /// 表示の更新が必要
    case display
    /// キャンバスの大きさが変わった
    case canvasSize
    /// 選択範囲・ドラッグ中の枠が変わった
    case selection
    case tool
    case colors
    /// テキスト入力枠ができた・消えた
    case textBox
    case history
    /// 虫めがね：倍率 level で center を中心に表示してほしい
    case magnify(level: Int, center: IPoint)
}

public struct ToolOptions: Equatable {
    public var eraserSize = 8
    public var brushShape: BrushShape = .round
    public var brushSize = 5
    public var lineWidth = 1
    public var fillStyle: FillStyle = .outline
    public var airbrushRadius = 8
    public var magnification = 4
    /// 選択範囲・テキストの背景を透明にする（背景色の画素を描かない）
    public var transparentBackground = false
    /// Skitch 風の矢印の太さ（1〜3）
    public var arrowThickness = 2
    public var stampKind: StampKind = .cross

    public init() {}

    public static let eraserSizes = [4, 6, 8, 10]
    public static let brushSizes = [8, 5, 2]
    public static let lineWidths = [1, 2, 3, 4, 5]
    public static let airbrushRadii = [4, 8, 12]
    public static let magnifications = [1, 2, 4, 6, 8]
    public static let arrowThicknesses = [1, 2, 3]
}

/// ペイントの中身（キャンバス・道具・選択範囲・履歴）。UI に依存しない。
/// UI はマウスとキー操作を渡し、`renderDisplay()` を表示し、`listener` で変化を受け取る。
public final class PaintEngine {
    public private(set) var canvas: Bitmap
    public var primary: Pixel = Colors.black {
        didSet {
            emit(.colors)
            if selection != nil && options.transparentBackground { emit(.display) }
            if annotation != nil && primary != oldValue { annotation!.color = primary; emit(.display) }
        }
    }
    public var secondary: Pixel = Colors.white {
        didSet { emit(.colors); if selection != nil && options.transparentBackground { emit(.display) } }
    }
    public private(set) var tool: Tool = .pencil
    public private(set) var previousTool: Tool = .pencil
    public var options = ToolOptions() {
        didSet {
            if oldValue.transparentBackground != options.transparentBackground { emit(.display) }
            if var a = annotation {
                switch a.shape {
                case .arrow:
                    a.thickness = options.arrowThickness
                case .stamp(_, let c, let r):
                    if oldValue.stampKind != options.stampKind {
                        a.shape = .stamp(options.stampKind, center: c, radius: r)
                        a.color = options.stampKind.defaultColor
                    }
                }
                if a != annotation { annotation = a; emit(.display); emit(.selection) }
            }
            emit(.tool)
        }
    }
    /// 表示倍率（ハンドルの当たり判定に使う）。
    public var zoom: Double = 1
    /// まっさらなキャンバスに貼り付けたら、キャンバスを画像とぴったり同じ大きさにする。
    public var fitCanvasToPasteWhenPristine = true
    /// テキストツールでクリックだけしたときの入力枠の大きさ。
    public var defaultTextBoxSize = ISize(200, 24)

    public private(set) var selection: FloatingSelection?
    /// 範囲選択・テキスト枠をドラッグ中の枠。
    public private(set) var marquee: IRect?
    /// テキスト入力中の枠。
    public private(set) var textBox: IRect?
    /// 保存後に変更があったか。
    public private(set) var isModified = false
    /// 新規作成から一度も手を加えていないか。
    public private(set) var isPristine = true
    /// 履歴のいちばん底（新規作成直後）がまっさらだったか。元に戻しきったら isPristine に戻す。
    private var basePristine = true
    /// キャンバスを広げるときの上限（指定位置貼り付けの打ち間違いで巨大な画像を作らないため）。
    public static let maxCanvasSide = 10_000
    /// ドラッグ中の図形・枠の大きさ（ステータスバー用）。
    public private(set) var liveSize: ISize?
    /// 浮いている注釈（矢印・スタンプ）。
    public private(set) var annotation: Annotation? {
        didSet { if annotation != oldValue { renderedAnnotation = nil } }
    }
    /// 注釈を画像にする関数（UI が CoreGraphics で描く）。nil なら注釈は表示も確定もされない。
    public var annotationRenderer: ((Annotation) -> RenderedAnnotation?)? {
        didSet { renderedAnnotation = nil }
    }

    public var listener: ((EngineEvent) -> Void)?
    public var rng = SplitMix64(seed: UInt64.random(in: 0...UInt64.max))

    private var history = History()
    private var drag: Drag?
    private var overlay: ((inout Bitmap) -> Void)?
    private var polygon: PolygonState?
    private var curve: CurveState?
    private var renderedAnnotation: RenderedAnnotation?

    private enum Drag {
        case stroke(button: MouseButton, last: IPoint)
        case colorErase(last: IPoint)
        case airbrush(button: MouseButton, at: IPoint)
        case shape(button: MouseButton, start: IPoint, end: IPoint)
        case marquee(start: IPoint)
        case lasso(points: [IPoint])
        case move(grab: IPoint)
        case resize(handle: SelectionHandle, startFrame: IRect, start: CanvasPoint)
        case text(start: IPoint)
        case polygonSegment
        case curvePoint
        case annotation(part: Annotation.Part, start: CanvasPoint, original: Annotation)
        case stampPlace(center: IPoint)
    }

    private struct PolygonState {
        var button: MouseButton
        var points: [IPoint]
        var current: IPoint
    }

    private struct CurveState {
        var button: MouseButton
        var p0: IPoint
        var p3: IPoint
        var c1: IPoint?
        var c2: IPoint?
        /// 0: 直線を引いている 1: 1 回目の曲げ 2: 2 回目の曲げ
        var stage: Int
    }

    public init(width: Int = 560, height: Int = 360) {
        canvas = Bitmap(width: width, height: height, fill: Colors.white)
    }

    // MARK: - 状態

    public var canUndo: Bool { history.canUndo || selection?.recorded == true || annotation != nil }
    public var canRedo: Bool { history.canRedo }
    public var hasSelection: Bool { selection != nil }
    public var isAirbrushing: Bool {
        if case .airbrush? = drag { return true }
        return false
    }
    public var isDragging: Bool { drag != nil }
    /// 多角形・曲線を描いている途中か。
    public var hasPendingShape: Bool { polygon != nil || curve != nil || annotation != nil }

    /// 保存・印刷用：浮いている選択範囲や注釈を重ねた画像（状態は変えない）。
    public func flattened() -> Bitmap {
        let ann = annotation.flatMap { renderAnnotation($0) }
        if !(selection?.lifted ?? false) && ann == nil { return canvas }
        var out = canvas
        if let sel = selection, sel.lifted { composite(sel, onto: &out) }
        if let r = ann { out.drawPremultiplied(r.image, at: r.origin) }
        return out
    }

    /// 描きかけの多角形・曲線や浮いている選択範囲を確定する。
    public func finishPending() {
        finalizePending()
        emit(.selection)
        emit(.display)
    }

    /// 画面に出す画像（浮いている選択範囲やドラッグ中の図形を重ねたもの）。
    public func renderDisplay() -> Bitmap {
        let ann = annotation.flatMap { renderAnnotation($0) }
        if overlay == nil && !(selection?.lifted ?? false) && ann == nil { return canvas }
        var out = canvas
        if let sel = selection, sel.lifted { composite(sel, onto: &out) }
        if let r = ann { out.drawPremultiplied(r.image, at: r.origin) }
        overlay?(&out)
        return out
    }

    // MARK: - 道具と色

    public func setTool(_ t: Tool) {
        guard t != tool else { return }
        finalizePending()
        if t == .picker { previousTool = tool }
        if textBox != nil { textBox = nil; emit(.textBox) }
        tool = t
        emit(.tool)
        emit(.display)
    }

    public func swapColors() {
        let p = primary
        primary = secondary
        secondary = p
    }

    // MARK: - マウス

    public func mouseDown(at cp: CanvasPoint, button: MouseButton, modifiers: Modifiers = [], clickCount: Int = 1) {
        guard drag == nil else { return }
        let p = cp.pixel
        let (fg, _) = colors(for: button)
        switch tool {
        case .select, .freeSelect:
            if let sel = selection {
                if let h = handle(at: cp) {
                    lift(copy: false)
                    drag = .resize(handle: h, startFrame: sel.frame, start: cp)
                    return
                }
                if sel.frame.contains(p) {
                    lift(copy: modifiers.contains(.option))
                    drag = .move(grab: IPoint(p.x - sel.frame.x, p.y - sel.frame.y))
                    emit(.selection)
                    return
                }
                commitSelection()
            }
            let s = clampToCanvas(p)
            if tool == .select {
                drag = .marquee(start: s)
                marquee = IRect.spanning(s, s)
                emit(.selection)
            } else {
                drag = .lasso(points: [s])
                setLassoOverlay([s])
            }
        case .eraser:
            history.push(canvas)
            if button == .primary {
                strokeSegment(from: p, to: p, color: secondary)
                drag = .stroke(button: .primary, last: p)
            } else {
                colorErase(at: p)
                drag = .colorErase(last: p)
            }
            changed()
        case .fill:
            let before = canvas
            if Raster.floodFill(&canvas, x: p.x, y: p.y, color: fg) != nil {
                history.push(before)
                changed()
            }
        case .picker:
            guard let c = canvas.pixel(p.x, p.y) else { return }
            if button == .primary { primary = c } else { secondary = c }
            setTool(previousTool)
        case .magnifier:
            let target = options.magnification > 1 ? options.magnification : 4
            emit(.magnify(level: zoom > 1 ? 1 : target, center: p))
        case .pencil, .brush:
            history.push(canvas)
            strokeSegment(from: p, to: p, color: fg)
            drag = .stroke(button: button, last: p)
            changed()
        case .airbrush:
            history.push(canvas)
            spray(at: p, color: fg)
            drag = .airbrush(button: button, at: p)
            changed()
        case .text:
            guard textBox == nil else { return }
            drag = .text(start: p)
            marquee = IRect.spanning(p, p)
            emit(.selection)
        case .line, .rectangle, .ellipse, .roundedRectangle:
            drag = .shape(button: button, start: p, end: p)
            updateShapeOverlay()
        case .polygon:
            if var poly = polygon {
                if clickCount >= 2 { closePolygon(); return }
                let anchor = poly.points[poly.points.count - 1]
                poly.current = modifiers.contains(.shift) ? Raster.constrainLine(from: anchor, to: p) : p
                polygon = poly
            } else {
                polygon = PolygonState(button: button, points: [p], current: p)
            }
            drag = .polygonSegment
            updatePolygonOverlay()
        case .curve:
            if var c = curve {
                if c.stage == 1 { c.c1 = p; c.c2 = p } else { c.c2 = p }
                curve = c
            } else {
                curve = CurveState(button: button, p0: p, p3: p, c1: nil, c2: nil, stage: 0)
            }
            drag = .curvePoint
            updateCurveOverlay()
        case .arrow, .stamp:
            if let a = annotation {
                if let part = annotationPart(at: cp) {
                    drag = .annotation(part: part, start: cp, original: a)
                    emit(.selection)
                    return
                }
                commitAnnotation()
            }
            if tool == .arrow {
                let a = Annotation(shape: .arrow(tail: p, head: p), color: fg, thickness: options.arrowThickness)
                annotation = a
                drag = .annotation(part: .head, start: cp, original: a)
            } else {
                let k = options.stampKind
                annotation = Annotation(shape: .stamp(k, center: p, radius: Annotation.defaultStampRadius),
                                        color: button == .primary ? k.defaultColor : secondary, thickness: 0)
                drag = .stampPlace(center: p)
            }
            emit(.selection)
            emit(.display)
        }
    }

    public func mouseDragged(to cp: CanvasPoint, modifiers: Modifiers = []) {
        guard let d = drag else { return }
        let p = cp.pixel
        let shift = modifiers.contains(.shift)
        switch d {
        case .stroke(let button, let last):
            let c = tool == .eraser ? secondary : colors(for: button).0
            strokeSegment(from: last, to: p, color: c)
            drag = .stroke(button: button, last: p)
            changed()
        case .colorErase(let last):
            Raster.line(last.x, last.y, p.x, p.y) { x, y in colorErase(at: IPoint(x, y)) }
            drag = .colorErase(last: p)
            changed()
        case .airbrush(let button, _):
            drag = .airbrush(button: button, at: p)
            spray(at: p, color: colors(for: button).0)
            changed()
        case .shape(let button, let s, _):
            let e: IPoint
            if shift {
                e = tool == .line ? Raster.constrainLine(from: s, to: p) : Raster.constrainSquare(from: s, to: p)
            } else {
                e = p
            }
            drag = .shape(button: button, start: s, end: e)
            updateShapeOverlay()
        case .marquee(let s):
            let m = IRect.spanning(s, clampToCanvas(p))
            marquee = m
            liveSize = m.size
            emit(.selection)
        case .lasso(var pts):
            let q = clampToCanvas(p)
            if pts.last != q { pts.append(q) }
            drag = .lasso(points: pts)
            setLassoOverlay(pts)
        case .move(let grab):
            guard var sel = selection else { return }
            let o = IPoint(p.x - grab.x, p.y - grab.y)
            if o != sel.frame.origin { isModified = true }
            sel.frame.origin = o
            selection = sel
            emit(.selection)
            emit(.display)
        case .resize(let h, let f0, let start):
            guard var sel = selection else { return }
            let dx = Int((cp.x - start.x).rounded()), dy = Int((cp.y - start.y).rounded())
            sel.frame = h.resize(f0, dx: dx, dy: dy)
            if sel.frame != f0 { isModified = true }
            selection = sel
            liveSize = sel.frame.size
            emit(.selection)
            emit(.display)
        case .text(let s):
            let m = IRect.spanning(s, p)
            marquee = m
            liveSize = m.size
            emit(.selection)
        case .polygonSegment:
            guard var poly = polygon else { return }
            let anchor = poly.points[poly.points.count - 1]
            poly.current = shift ? Raster.constrainLine(from: anchor, to: p) : p
            polygon = poly
            updatePolygonOverlay()
        case .curvePoint:
            guard var c = curve else { return }
            switch c.stage {
            case 0: c.p3 = shift ? Raster.constrainLine(from: c.p0, to: p) : p
            case 1: c.c1 = p; c.c2 = p
            default: c.c2 = p
            }
            curve = c
            updateCurveOverlay()
        case .annotation(let part, let start, let original):
            let dx = Int((cp.x - start.x).rounded()), dy = Int((cp.y - start.y).rounded())
            annotation = original.adjusted(part, dx: dx, dy: dy, pointer: p, constrain: shift)
            emit(.selection)
            emit(.display)
        case .stampPlace(let c):
            guard var a = annotation, case .stamp(let k, _, _) = a.shape else { return }
            let d = max(abs(p.x - c.x), abs(p.y - c.y))
            if d > 6 {
                a.shape = .stamp(k, center: c, radius: max(Annotation.minStampRadius, d))
                annotation = a
                emit(.selection)
                emit(.display)
            }
        }
    }

    public func mouseUp(at cp: CanvasPoint, modifiers: Modifiers = []) {
        guard drag != nil else { return }
        if case .stroke? = drag {} else if case .colorErase? = drag {} else if case .airbrush? = drag {} else {
            mouseDragged(to: cp, modifiers: modifiers)
        }
        guard let d = drag else { return }
        drag = nil
        liveSize = nil
        switch d {
        case .stroke, .colorErase, .airbrush:
            break
        case .shape(let button, let s, let e):
            overlay = nil
            history.push(canvas)
            PaintEngine.drawShapeTool(&canvas, tool: tool, options: options, colors: colors(for: button), from: s, to: e)
            changed()
        case .marquee:
            let m = marquee
            marquee = nil
            if let m = m, m.width > 1 || m.height > 1 {
                selection = FloatingSelection(image: canvas.cropped(to: m), frame: m, lifted: false, recorded: false)
            }
            emit(.selection)
            emit(.display)
        case .lasso(let pts):
            overlay = nil
            makeLassoSelection(pts)
            emit(.selection)
            emit(.display)
        case .move:
            emit(.selection)
        case .resize:
            if var sel = selection {
                sel.mask = sel.renderedMask
                sel.image = sel.rendered
                selection = sel
            }
            emit(.selection)
        case .text(let s):
            var r = marquee ?? IRect.spanning(s, s)
            marquee = nil
            if r.width < 6 && r.height < 6 {
                r = IRect(origin: s, size: defaultTextBoxSize)
            }
            r.width = max(r.width, 24)
            r.height = max(r.height, defaultTextBoxSize.height)
            textBox = r
            emit(.selection)
            emit(.textBox)
        case .polygonSegment:
            guard var poly = polygon else { return }
            let last = poly.points[poly.points.count - 1]
            if poly.current != last { poly.points.append(poly.current) }
            polygon = poly
            if poly.points.count >= 4 && isNear(poly.current, poly.points[0]) {
                closePolygon()
            } else {
                updatePolygonOverlay()
            }
        case .curvePoint:
            guard var c = curve else { return }
            switch c.stage {
            case 0:
                if c.p3 == c.p0 {
                    curve = nil
                    overlay = nil
                    emit(.display)
                } else {
                    c.stage = 1
                    curve = c
                }
            case 1:
                c.stage = 2
                curve = c
            default:
                commitCurve()
            }
        case .annotation, .stampPlace:
            // ドラッグせずにクリックしただけの矢印は置かない
            if let a = annotation, case .arrow = a.shape, a.arrowLength < 4 {
                annotation = nil
                emit(.display)
            }
            emit(.selection)
        }
    }

    /// エアブラシ中に UI のタイマーから呼ぶ。
    public func airbrushTick() {
        guard case .airbrush(let button, let p)? = drag else { return }
        spray(at: p, color: colors(for: button).0)
        changed()
    }

    /// 選択範囲のハンドルに当たっているか（cp はキャンバス座標）。
    public func handle(at cp: CanvasPoint) -> SelectionHandle? {
        guard let f = selection?.frame, tool == .select || tool == .freeSelect else { return nil }
        let tol = max(4.0 / zoom, 0.6)
        let small = Double(min(f.width, f.height)) < 3 * tol
        if small && f.contains(cp.pixel) { return nil }
        for h in SelectionHandle.allCases {
            if small && [.top, .bottom, .left, .right].contains(h) { continue }
            let c = h.position(in: f)
            if abs(cp.x - c.x) <= tol && abs(cp.y - c.y) <= tol { return h }
        }
        return nil
    }

    /// 浮いている注釈のどこに当たるか（cp はキャンバス座標）。
    public func annotationPart(at cp: CanvasPoint) -> Annotation.Part? {
        guard let a = annotation, tool == .arrow || tool == .stamp else { return nil }
        return a.part(at: cp, tolerance: max(5.0 / zoom, 1.0))
    }

    /// 浮いている注釈をキャンバスに焼き込む。
    public func commitAnnotation() {
        guard let a = annotation else { return }
        annotation = nil
        if let r = renderAnnotation(a) {
            history.push(canvas)
            canvas.drawPremultiplied(r.image, at: r.origin)
            changed()
        }
        emit(.selection)
        emit(.display)
    }

    /// 浮いている注釈を消す（delete キー）。
    public func deleteAnnotation() {
        guard annotation != nil else { return }
        annotation = nil
        emit(.selection)
        emit(.display)
    }

    public func nudgeAnnotation(dx: Int, dy: Int) {
        guard let a = annotation else { return }
        annotation = a.moved(dx: dx, dy: dy)
        emit(.selection)
        emit(.display)
    }

    private func renderAnnotation(_ a: Annotation) -> RenderedAnnotation? {
        if a == annotation, let r = renderedAnnotation { return r }
        let r = annotationRenderer?(a)
        if a == annotation { renderedAnnotation = r }
        return r
    }

    // MARK: - 選択範囲とクリップボード

    public func selectAll() {
        if tool != .select { setTool(.select) }
        finalizePending()
        selection = FloatingSelection(image: canvas, frame: canvas.bounds, lifted: false, recorded: false)
        emit(.selection)
        emit(.display)
    }

    /// 浮いている選択範囲をキャンバスに確定する。
    public func commitSelection() {
        guard let sel = selection else { return }
        selection = nil
        if sel.lifted {
            // 変更済みの印は、貼り付け・移動・伸縮の時点で付けている（保存直後の確定で「変更あり」にしない）
            composite(sel, onto: &canvas)
            isPristine = false
        }
        emit(.selection)
        emit(.display)
        emit(.history)
    }

    /// コピーする画像。選択範囲があればその中身、なければキャンバス全体。
    public func copyImage() -> Bitmap {
        if let sel = selection { return clipboardImage(sel) }
        return flattened()
    }

    /// 切り取り。選択範囲がなければ何もしない。
    public func cut() -> Bitmap? {
        guard let sel = selection else { return nil }
        let img = clipboardImage(sel)
        deleteSelection()
        return img
    }

    /// 選択範囲を消す（背景色で塗る）。
    public func deleteSelection() {
        guard let sel = selection else { return }
        if !sel.lifted {
            if !sel.recorded { history.push(canvas) }
            erase(sel.frame, mask: sel.mask)
        } else {
            // 浮いている画像を消す：消す直前の見た目に戻れるようにする
            var before = canvas
            composite(sel, onto: &before)
            history.push(before)
        }
        selection = nil
        changed()
        emit(.selection)
    }

    public func nudgeSelection(dx: Int, dy: Int) {
        guard let f = selection?.frame else { return }
        moveSelection(to: IPoint(f.x + dx, f.y + dy))
    }

    public func moveSelection(to origin: IPoint) {
        guard selection != nil else { return }
        lift(copy: false)
        if selection!.frame.origin != origin { isModified = true }
        selection!.frame.origin = origin
        emit(.selection)
        emit(.display)
    }

    /// 選択範囲の大きさにキャンバスを切り抜く。
    public func cropToSelection() {
        guard let sel = selection else { return }
        let img = clipboardImage(sel)
        commitSelection()
        history.push(canvas)
        canvas = img
        changed()
        emit(.canvasSize)
    }

    /// 貼り付け。
    /// - まっさらなキャンバスなら、キャンバスを画像と同じ大きさにして、そのまま描き込む（すぐ編集・保存できる）
    /// - 画像の方が大きければキャンバスを広げて左上に置く（ぴったり覆うならそのまま描き込む）
    /// - キャンバスの方が広ければ、見えている左上に浮かせて置く（ドラッグや矢印キーで位置を決める）
    /// - Returns: 画像を置いた範囲と、浮かせたかどうか
    @discardableResult
    public func paste(_ image: Bitmap, visibleOrigin: IPoint = IPoint(0, 0)) -> (frame: IRect, floating: Bool) {
        finalizePending()
        let plan = PastePlacement.plan(image: image.size, canvas: canvas.size, pristine: isPristine,
                                       fitWhenPristine: fitCanvasToPasteWhenPristine, visibleOrigin: visibleOrigin)
        let frame = IRect(origin: plan.origin, size: image.size)
        if plan.origin == IPoint(0, 0) && plan.canvas == image.size {
            // キャンバス全体を覆う：浮かせるとドラッグで画像ごと動いてしまうので、すぐ確定する
            history.push(canvas)
            var img = image
            img.makeOpaque()
            let resized = img.size != canvas.size
            canvas = img
            changed()
            if resized { emit(.canvasSize) }
            return (frame, false)
        }
        placePaste(image, canvasSize: plan.canvas, origin: plan.origin)
        return (frame, true)
    }

    /// 位置を指定して貼り付け。growCanvas が true なら、はみ出す分だけキャンバスを広げる
    /// （左や上にはみ出すときは、今の絵を右下へずらして広げる）。
    /// - Returns: 画像を置いた範囲（ずらした後の座標）。大きすぎて置けないときは nil。
    @discardableResult
    public func paste(_ image: Bitmap, at origin: IPoint, growCanvas: Bool) -> IRect? {
        var frame = IRect(origin: origin, size: image.size)
        var size = canvas.size
        var shift = IPoint(0, 0)
        if growCanvas {
            let minX = min(0, frame.minX), minY = min(0, frame.minY)
            let maxX = max(canvas.width, frame.maxX), maxY = max(canvas.height, frame.maxY)
            size = ISize(maxX - minX, maxY - minY)
            shift = IPoint(-minX, -minY)
            let limit = max(Self.maxCanvasSide, image.width, image.height)
            if size.width > limit || size.height > limit { return nil }
        }
        finalizePending()
        if shift != IPoint(0, 0) {
            history.push(canvas)
            var grown = Bitmap(width: size.width, height: size.height, fill: secondary)
            grown.draw(canvas, at: shift)
            canvas = grown
            frame = frame.offsetBy(dx: shift.x, dy: shift.y)
            placePaste(image, canvasSize: size, origin: frame.origin, pushHistory: false)
        } else {
            placePaste(image, canvasSize: size, origin: frame.origin)
        }
        return frame
    }

    /// 画像そのものを新しいキャンバスにする（キャンバスは画像と同じ大きさ）。
    public func pasteAsNewImage(_ image: Bitmap) {
        finalizePending()
        history.push(canvas)
        var img = image
        img.makeOpaque()
        let resized = img.size != canvas.size
        canvas = img
        changed()
        if resized { emit(.canvasSize) }
    }

    private func placePaste(_ image: Bitmap, canvasSize: ISize, origin: IPoint, pushHistory: Bool = true) {
        if pushHistory { history.push(canvas) }
        if canvasSize != canvas.size {
            canvas = canvas.resizingCanvas(to: canvasSize, fill: secondary)
            emit(.canvasSize)
        }
        if tool != .select && tool != .freeSelect {
            tool = .select
            emit(.tool)
        }
        var img = image
        img.makeOpaque()
        selection = FloatingSelection(image: img, frame: IRect(origin: origin, size: img.size), lifted: true, recorded: true)
        isPristine = false
        isModified = true
        emit(.selection)
        emit(.display)
        emit(.history)
    }

    // MARK: - イメージ

    public func flipHorizontal() { transform(geometric: true) { $0.flippedHorizontally() } }
    public func flipVertical() { transform(geometric: true) { $0.flippedVertically() } }
    public func rotateClockwise() { transform(geometric: true) { $0.rotatedClockwise() } }
    public func rotateCounterClockwise() { transform(geometric: true) { $0.rotatedCounterClockwise() } }
    public func rotate180() { transform(geometric: true) { $0.rotated180() } }
    public func invertColors() {
        transform(geometric: false) { b in
            var c = b
            c.invertColors()
            return c
        }
    }

    /// 伸縮（パーセント）。
    public func stretch(percentX: Int, percentY: Int) {
        transform(geometric: true) { b in
            b.scaled(to: ISize(max(1, b.width * percentX / 100), max(1, b.height * percentY / 100)))
        }
    }

    public func resizeCanvas(to s: ISize) {
        guard s.width > 0, s.height > 0 else { return }
        finalizePending()
        guard s != canvas.size else { return }
        history.push(canvas)
        canvas = canvas.resizingCanvas(to: s, fill: secondary)
        changed()
        emit(.canvasSize)
    }

    public func clearImage() {
        finalizePending()
        history.push(canvas)
        canvas.fill(canvas.bounds, with: secondary)
        changed()
    }

    /// 新規作成。履歴も消す。
    public func newImage(size: ISize) {
        drag = nil
        overlay = nil
        polygon = nil
        curve = nil
        selection = nil
        annotation = nil
        marquee = nil
        textBox = nil
        history.reset()
        canvas = Bitmap(width: size.width, height: size.height, fill: Colors.white)
        isModified = false
        isPristine = true
        basePristine = true
        emitAll()
    }

    /// ファイルから読み込んだ画像を開く。履歴も消す。
    public func load(_ bitmap: Bitmap) {
        newImage(size: bitmap.size)
        var b = bitmap
        b.makeOpaque()
        canvas = b
        isPristine = false
        basePristine = false
        emitAll()
    }

    public func markSaved() {
        isModified = false
        emit(.history)
    }

    // MARK: - テキスト

    /// UI が描いたテキスト画像（乗算済みアルファ）を確定する。
    /// background は不透明モードで背景色に塗る範囲（省略時は画像の範囲）。
    public func commitText(_ rendered: Bitmap, at origin: IPoint, background: IRect? = nil) {
        textBox = nil
        history.push(canvas)
        if !options.transparentBackground {
            canvas.fill(background ?? IRect(origin: origin, size: rendered.size), with: secondary)
        }
        canvas.drawPremultiplied(rendered, at: origin)
        changed()
        emit(.textBox)
    }

    public func cancelText() {
        guard textBox != nil else { return }
        textBox = nil
        emit(.textBox)
    }

    /// 入力に合わせて枠を広げたいときなど。
    public func updateTextBox(_ r: IRect) {
        guard textBox != nil else { return }
        textBox = r
        emit(.selection)
    }

    // MARK: - 元に戻す

    public func undo() {
        if annotation != nil {
            // 置いたばかりの注釈を取り消す
            annotation = nil
            drag = nil
            emit(.selection)
            emit(.display)
            return
        }
        polygon = nil
        curve = nil
        overlay = nil
        drag = nil
        marquee = nil
        if textBox != nil { textBox = nil; emit(.textBox) }
        var current = canvas
        if let sel = selection {
            selection = nil
            if sel.lifted { composite(sel, onto: &current) }
            emit(.selection)
        }
        guard let prev = history.undo(current: current) else {
            emit(.display)
            emit(.history)
            return
        }
        apply(historyState: prev)
        // 新規作成直後まで戻しきったら、また「まっさら」扱い（貼り付けでキャンバスが画像サイズになる）
        isPristine = basePristine && !history.canUndo && !history.droppedOldest
    }

    public func redo() {
        commitAnnotation()
        commitSelection()
        polygon = nil
        curve = nil
        overlay = nil
        guard let next = history.redo(current: canvas) else { return }
        apply(historyState: next)
    }

    private func apply(historyState b: Bitmap) {
        let resized = b.size != canvas.size
        canvas = b
        isModified = true
        isPristine = false
        if resized { emit(.canvasSize) }
        emit(.display)
        emit(.history)
    }

    // MARK: - 内部

    private func emit(_ e: EngineEvent) { listener?(e) }

    private func emitAll() {
        for e in [EngineEvent.canvasSize, .display, .selection, .textBox, .history, .tool, .colors] { emit(e) }
    }

    private func changed() {
        isModified = true
        isPristine = false
        emit(.display)
        emit(.history)
    }

    private func colors(for b: MouseButton) -> (Pixel, Pixel) {
        b == .primary ? (primary, secondary) : (secondary, primary)
    }

    private func clampToCanvas(_ p: IPoint) -> IPoint {
        IPoint(min(max(p.x, 0), canvas.width - 1), min(max(p.y, 0), canvas.height - 1))
    }

    private func isNear(_ a: IPoint, _ b: IPoint) -> Bool {
        let tol = max(2, Int((4.0 / zoom).rounded(.up)))
        return abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
    }

    /// 道具を替える・貼り付ける等の前に、描きかけのものを確定する。
    private func finalizePending() {
        drag = nil
        marquee = nil
        liveSize = nil
        commitAnnotation()
        commitSelection()
        if polygon != nil { closePolygon() }
        if curve != nil { commitCurve() }
        overlay = nil
    }

    private func strokeSegment(from a: IPoint, to b: IPoint, color: Pixel) {
        switch tool {
        case .pencil:
            Raster.strokeLine(&canvas, from: a, to: b, size: 1, shape: .square, color: color)
        case .brush:
            Raster.strokeLine(&canvas, from: a, to: b, size: options.brushSize, shape: options.brushShape, color: color)
        case .eraser:
            Raster.strokeLine(&canvas, from: a, to: b, size: options.eraserSize, shape: .square, color: color)
        default:
            break
        }
    }

    /// 右ドラッグの消しゴム：描画色の画素だけ背景色に置き換える。
    private func colorErase(at p: IPoint) {
        let s = options.eraserSize, o = s / 2
        canvas.replace(primary, with: secondary, in: IRect(x: p.x - o, y: p.y - o, width: s, height: s))
    }

    private func spray(at p: IPoint, color: Pixel) {
        let r = options.airbrushRadius
        Raster.spray(&canvas, center: p, radius: r, count: r * 3 / 2 + 2, color: color, rng: &rng)
    }

    private func lift(copy: Bool) {
        guard var sel = selection else { return }
        if !sel.recorded {
            history.push(canvas)
            sel.recorded = true
            emit(.history)
        }
        if !sel.lifted {
            selection = sel
            if !copy { erase(sel.frame, mask: sel.mask) }
            sel.lifted = true
            isModified = true
            isPristine = false
        } else if copy {
            composite(sel, onto: &canvas)
        }
        selection = sel
        emit(.display)
    }

    private func erase(_ frame: IRect, mask: [Bool]?) {
        guard let mask = mask else {
            canvas.fill(frame, with: secondary)
            return
        }
        for y in 0..<frame.height {
            for x in 0..<frame.width where mask[y * frame.width + x] {
                canvas.plot(frame.x + x, frame.y + y, secondary)
            }
        }
    }

    private func composite(_ sel: FloatingSelection, onto bmp: inout Bitmap) {
        let key: Pixel? = options.transparentBackground ? secondary : nil
        bmp.draw(sel.rendered, at: sel.frame.origin, transparentKey: key, mask: sel.renderedMask)
    }

    private func clipboardImage(_ sel: FloatingSelection) -> Bitmap {
        var img = sel.rendered
        if let m = sel.renderedMask {
            for i in img.pixels.indices where !m[i] { img.pixels[i] = secondary }
        }
        return img
    }

    private func transform(geometric: Bool, _ f: (Bitmap) -> Bitmap) {
        if polygon != nil { closePolygon() }
        if curve != nil { commitCurve() }
        if selection != nil {
            lift(copy: false)
            var sel = selection!
            let img = f(sel.rendered)
            if let m = sel.renderedMask {
                if geometric {
                    let mb = Bitmap(width: sel.frame.width, height: sel.frame.height,
                                    pixels: m.map { $0 ? Colors.white : Colors.black })
                    sel.mask = f(mb).pixels.map { $0 == Colors.white }
                } else {
                    sel.mask = m
                }
            }
            sel.image = img
            sel.frame.size = img.size
            selection = sel
            isModified = true
            emit(.selection)
            emit(.display)
        } else {
            history.push(canvas)
            let n = f(canvas)
            let resized = n.size != canvas.size
            canvas = n
            changed()
            if resized { emit(.canvasSize) }
        }
    }

    private func makeLassoSelection(_ pts: [IPoint]) {
        guard pts.count >= 3 else { return }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let rect = IRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1)
            .intersection(canvas.bounds)
        guard !rect.isEmpty, rect.width > 1 || rect.height > 1 else { return }
        var mb = Bitmap(width: rect.width, height: rect.height, fill: Colors.black)
        let local = pts.map { IPoint($0.x - rect.x, $0.y - rect.y) }
        Raster.fillPolygon(&mb, local, color: Colors.white)
        Raster.polyline(&mb, local, closed: true, width: 1, color: Colors.white)
        let mask = mb.pixels.map { $0 == Colors.white }
        selection = FloatingSelection(image: canvas.cropped(to: rect), frame: rect, lifted: false, recorded: false, mask: mask)
    }

    private func setLassoOverlay(_ pts: [IPoint]) {
        overlay = { bmp in
            var seen = Set<IPoint>()
            var last = pts[0]
            for p in pts {
                Raster.line(last.x, last.y, p.x, p.y) { x, y in seen.insert(IPoint(x, y)) }
                last = p
            }
            for q in seen {
                if let c = bmp.pixel(q.x, q.y) { bmp[q.x, q.y] = Colors.inverted(c) }
            }
        }
        emit(.display)
    }

    static func drawShapeTool(_ bmp: inout Bitmap, tool: Tool, options: ToolOptions, colors: (Pixel, Pixel),
                              from s: IPoint, to e: IPoint) {
        let (fg, bg) = colors
        let kind: ShapeKind
        switch tool {
        case .line:
            Raster.strokeLine(&bmp, from: s, to: e, size: options.lineWidth, shape: .square, color: fg)
            return
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .roundedRectangle: kind = .roundedRectangle
        default: return
        }
        Raster.drawShape(&bmp, kind, in: IRect.spanning(s, e), style: options.fillStyle,
                         lineWidth: options.lineWidth, outline: fg, fill: bg)
    }

    private func updateShapeOverlay() {
        guard case .shape(let button, let s, let e)? = drag else { return }
        let t = tool, o = options, c = colors(for: button)
        overlay = { bmp in PaintEngine.drawShapeTool(&bmp, tool: t, options: o, colors: c, from: s, to: e) }
        liveSize = ISize(abs(e.x - s.x) + 1, abs(e.y - s.y) + 1)
        emit(.display)
    }

    static func drawPolygon(_ bmp: inout Bitmap, _ pts: [IPoint], closed: Bool, options: ToolOptions,
                            colors: (Pixel, Pixel)) {
        let (fg, bg) = colors
        let style = options.fillStyle
        if closed && pts.count >= 3 && style != .outline {
            Raster.fillPolygon(&bmp, pts, color: style == .fill ? fg : bg)
        }
        if style != .fill || !closed || pts.count < 3 {
            Raster.polyline(&bmp, pts, closed: closed, width: options.lineWidth, color: fg)
        }
    }

    private func updatePolygonOverlay() {
        guard let poly = polygon else { return }
        var pts = poly.points
        if poly.current != pts[pts.count - 1] { pts.append(poly.current) }
        let o = options, c = colors(for: poly.button)
        overlay = { bmp in
            Raster.polyline(&bmp, pts, closed: false, width: o.lineWidth, color: c.0)
        }
        emit(.display)
    }

    private func closePolygon() {
        guard let poly = polygon else { return }
        polygon = nil
        overlay = nil
        var pts = poly.points
        if pts.count >= 4, isNear(pts[pts.count - 1], pts[0]) { pts.removeLast() }
        guard pts.count >= 2 else { emit(.display); return }
        history.push(canvas)
        PaintEngine.drawPolygon(&canvas, pts, closed: true, options: options, colors: colors(for: poly.button))
        changed()
    }

    private static func curvePoints(p0: IPoint, p3: IPoint, c1: IPoint?, c2: IPoint?, stage: Int) -> [IPoint] {
        if stage == 0 { return [p0, p3] }
        let a = c1 ?? p0
        let b = c2 ?? a
        return Raster.cubicBezier(p0, a, b, p3)
    }

    private func updateCurveOverlay() {
        guard let c = curve else { return }
        let pts = PaintEngine.curvePoints(p0: c.p0, p3: c.p3, c1: c.c1, c2: c.c2, stage: c.stage)
        let o = options, color = colors(for: c.button).0
        overlay = { bmp in Raster.polyline(&bmp, pts, closed: false, width: o.lineWidth, color: color) }
        emit(.display)
    }

    private func commitCurve() {
        guard let c = curve else { return }
        curve = nil
        overlay = nil
        if c.p0 == c.p3 && c.stage == 0 { emit(.display); return }
        let pts = PaintEngine.curvePoints(p0: c.p0, p3: c.p3, c1: c.c1, c2: c.c2, stage: c.stage)
        history.push(canvas)
        Raster.polyline(&canvas, pts, closed: false, width: options.lineWidth, color: colors(for: c.button).0)
        changed()
    }
}
