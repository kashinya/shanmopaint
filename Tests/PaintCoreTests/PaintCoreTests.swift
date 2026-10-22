import XCTest
@testable import PaintCore

private let red = Colors.rgb(255, 0, 0)
private let blue = Colors.rgb(0, 0, 255)
private let green = Colors.rgb(0, 255, 0)

private func solid(_ w: Int, _ h: Int, _ c: Pixel) -> Bitmap { Bitmap(width: w, height: h, fill: c) }
private func cp(_ x: Int, _ y: Int) -> CanvasPoint { CanvasPoint(IPoint(x, y)) }

/// 4 隅の色が違う画像（向きのテスト用）
private func corners(_ w: Int, _ h: Int) -> Bitmap {
    var b = solid(w, h, Colors.white)
    b[0, 0] = red
    b[w - 1, 0] = green
    b[0, h - 1] = blue
    b[w - 1, h - 1] = Colors.black
    return b
}

final class GeometryAndBitmapTests: XCTestCase {
    func testRectSpanningAndIntersection() {
        let r = IRect.spanning(IPoint(5, 7), IPoint(2, 3))
        XCTAssertEqual(r, IRect(x: 2, y: 3, width: 4, height: 5))
        XCTAssertTrue(r.contains(IPoint(5, 7)))
        XCTAssertFalse(r.contains(IPoint(6, 7)))
        XCTAssertTrue(r.intersection(IRect(x: 100, y: 100, width: 5, height: 5)).isEmpty)
        XCTAssertEqual(r.intersection(IRect(x: 4, y: 0, width: 10, height: 4)), IRect(x: 4, y: 3, width: 2, height: 1))
    }

    func testCanvasPointFloorsNegative() {
        XCTAssertEqual(CanvasPoint(-0.2, 3.9).pixel, IPoint(-1, 3))
    }

    func testHexRoundTrip() {
        XCTAssertEqual(Colors.hexString(Colors.rgb(1, 171, 255)), "#01abff")
        XCTAssertEqual(Colors.parseHex("#01abff"), Colors.rgb(1, 171, 255))
        XCTAssertNil(Colors.parseHex("12345"))
    }

    func testCropOutsideFillsAndDrawClips() {
        let b = solid(4, 4, red)
        let c = b.cropped(to: IRect(x: 2, y: 2, width: 4, height: 4), outside: blue)
        XCTAssertEqual(c[0, 0], red)
        XCTAssertEqual(c[1, 1], red)
        XCTAssertEqual(c[2, 2], blue)
        var d = solid(4, 4, Colors.white)
        d.draw(solid(3, 3, green), at: IPoint(-1, 2))
        XCTAssertEqual(d[0, 3], green)
        XCTAssertEqual(d[1, 3], green)
        XCTAssertEqual(d[2, 3], Colors.white)
        XCTAssertEqual(d[0, 1], Colors.white)
    }

    func testTransparentKeyAndMask() {
        var d = solid(3, 1, blue)
        var s = solid(3, 1, Colors.white)
        s[1, 0] = red
        d.draw(s, at: IPoint(0, 0), transparentKey: Colors.white)
        XCTAssertEqual(d.pixels, [blue, red, blue])
        var e = solid(3, 1, blue)
        e.draw(solid(3, 1, green), at: IPoint(0, 0), mask: [true, false, true])
        XCTAssertEqual(e.pixels, [green, blue, green])
    }

    func testRotationsAndFlips() {
        let b = corners(3, 2)
        let cw = b.rotatedClockwise()
        XCTAssertEqual(cw.size, ISize(2, 3))
        XCTAssertEqual(cw[1, 0], red)      // 左上 → 右上
        XCTAssertEqual(cw[0, 0], blue)     // 左下 → 左上
        XCTAssertEqual(cw.rotatedCounterClockwise(), b)
        XCTAssertEqual(b.rotated180(), cw.rotatedClockwise())
        XCTAssertEqual(b.flippedHorizontally()[2, 0], red)
        XCTAssertEqual(b.flippedVertically()[0, 1], red)
    }

    func testScaledNearest() {
        let b = corners(2, 2)
        let s = b.scaled(to: ISize(4, 4))
        XCTAssertEqual(s[0, 0], red)
        XCTAssertEqual(s[1, 1], red)
        XCTAssertEqual(s[3, 0], green)
        XCTAssertEqual(s[3, 3], Colors.black)
        XCTAssertEqual(s.scaled(to: ISize(2, 2)), b)
    }

    func testPremultipliedBlend() {
        // 50% の黒（乗算済み）を白に重ねる → 灰色
        let half: Pixel = 0x8000_0000
        let out = Colors.blendPremultiplied(half, over: Colors.white)
        XCTAssertEqual(Colors.red(out), 127, accuracy: 1)
        XCTAssertEqual(Colors.alpha(out), 255)
    }
}

final class RasterTests: XCTestCase {
    func testLineEndpointsIncluded() {
        var pts: [IPoint] = []
        Raster.line(0, 0, 3, 1) { pts.append(IPoint($0, $1)) }
        XCTAssertEqual(pts.first, IPoint(0, 0))
        XCTAssertEqual(pts.last, IPoint(3, 1))
        XCTAssertEqual(pts.count, 4)
    }

    func testFloodFillStopsAtBorder() {
        var b = solid(10, 10, Colors.white)
        Raster.drawShape(&b, .rectangle, in: IRect(x: 2, y: 2, width: 6, height: 6), style: .outline,
                         lineWidth: 1, outline: Colors.black, fill: Colors.white)
        let r = Raster.floodFill(&b, x: 4, y: 4, color: red)
        XCTAssertEqual(r, IRect(x: 3, y: 3, width: 4, height: 4))
        XCTAssertEqual(b[0, 0], Colors.white)
        XCTAssertEqual(b[2, 2], Colors.black)
        XCTAssertNil(Raster.floodFill(&b, x: 4, y: 4, color: red), "同じ色なら何もしない")
    }

    func testFloodFillLargeAreaDoesNotOverflow() {
        var b = solid(1500, 1500, Colors.white)
        XCTAssertNotNil(Raster.floodFill(&b, x: 0, y: 0, color: red))
        XCTAssertEqual(b[1499, 1499], red)
    }

    func testEllipseIsSymmetricAndInsideRect() {
        var b = solid(40, 30, Colors.white)
        let r = IRect(x: 5, y: 5, width: 21, height: 15)
        Raster.drawShape(&b, .ellipse, in: r, style: .fill, lineWidth: 1, outline: Colors.black, fill: Colors.black)
        for y in 0..<30 {
            for x in 0..<40 where b[x, y] == Colors.black {
                XCTAssertTrue(r.contains(IPoint(x, y)), "(\(x),\(y)) はみ出し")
                XCTAssertEqual(b[r.minX + r.maxX - 1 - x, y], Colors.black, "左右対称でない")
            }
        }
        XCTAssertEqual(b[15, 12], Colors.black)
    }

    func testOutlineAndFillColors() {
        var b = solid(20, 20, Colors.white)
        Raster.drawShape(&b, .rectangle, in: IRect(x: 0, y: 0, width: 10, height: 10), style: .outlineAndFill,
                         lineWidth: 2, outline: Colors.black, fill: red)
        XCTAssertEqual(b[0, 0], Colors.black)
        XCTAssertEqual(b[1, 1], Colors.black)
        XCTAssertEqual(b[2, 2], red)
        XCTAssertEqual(b[9, 9], Colors.black)
        XCTAssertEqual(b[10, 10], Colors.white)
    }

    func testPolygonFill() {
        var b = solid(20, 20, Colors.white)
        Raster.fillPolygon(&b, [IPoint(2, 2), IPoint(17, 2), IPoint(17, 17), IPoint(2, 17)], color: red)
        XCTAssertEqual(b[10, 10], red)
        XCTAssertEqual(b[1, 10], Colors.white)
        XCTAssertEqual(b[18, 10], Colors.white)
    }

    func testBezierEndpoints() {
        let pts = Raster.cubicBezier(IPoint(0, 0), IPoint(10, 20), IPoint(20, 20), IPoint(30, 0))
        XCTAssertEqual(pts.first, IPoint(0, 0))
        XCTAssertEqual(pts.last, IPoint(30, 0))
        XCTAssertTrue(pts.contains { $0.y > 10 })
    }

    func testSprayStaysInRadius() {
        var b = solid(50, 50, Colors.white)
        var rng = SplitMix64(seed: 42)
        Raster.spray(&b, center: IPoint(25, 25), radius: 6, count: 200, color: red, rng: &rng)
        var n = 0
        for y in 0..<50 {
            for x in 0..<50 where b[x, y] == red {
                n += 1
                XCTAssertLessThanOrEqual((x - 25) * (x - 25) + (y - 25) * (y - 25), 36)
            }
        }
        XCTAssertGreaterThan(n, 20)
    }

    func testConstrain() {
        XCTAssertEqual(Raster.constrainLine(from: IPoint(0, 0), to: IPoint(10, 1)), IPoint(10, 0))
        XCTAssertEqual(Raster.constrainLine(from: IPoint(0, 0), to: IPoint(1, -10)), IPoint(0, -10))
        XCTAssertEqual(Raster.constrainLine(from: IPoint(0, 0), to: IPoint(9, 7)), IPoint(9, 9))
        XCTAssertEqual(Raster.constrainSquare(from: IPoint(5, 5), to: IPoint(0, 8)), IPoint(0, 10))
    }

    func testBrushShapes() {
        for shape in BrushShape.allCases {
            var b = solid(20, 20, Colors.white)
            Raster.stamp(&b, x: 10, y: 10, size: 5, shape: shape, color: red)
            XCTAssertTrue(b.pixels.contains(red), "\(shape)")
        }
    }
}

final class PastePlacementTests: XCTestCase {
    func testPristineCanvasBecomesImageSize() {
        let p = PastePlacement.plan(image: ISize(300, 200), canvas: ISize(560, 360), pristine: true,
                                    fitWhenPristine: true, visibleOrigin: IPoint(40, 40))
        XCTAssertEqual(p.canvas, ISize(300, 200))
        XCTAssertEqual(p.origin, IPoint(0, 0))
    }

    func testLargerImageGrowsCanvas() {
        let p = PastePlacement.plan(image: ISize(800, 100), canvas: ISize(560, 360), pristine: false,
                                    fitWhenPristine: true, visibleOrigin: IPoint(40, 40))
        XCTAssertEqual(p.canvas, ISize(800, 360))
        XCTAssertEqual(p.origin, IPoint(0, 0))
    }

    func testSmallerImageGoesToVisibleOriginClamped() {
        let p = PastePlacement.plan(image: ISize(100, 100), canvas: ISize(560, 360), pristine: false,
                                    fitWhenPristine: true, visibleOrigin: IPoint(500, 20))
        XCTAssertEqual(p.canvas, ISize(560, 360))
        XCTAssertEqual(p.origin, IPoint(460, 20))
    }

    func testPristineFitCanBeDisabled() {
        let p = PastePlacement.plan(image: ISize(100, 100), canvas: ISize(560, 360), pristine: true,
                                    fitWhenPristine: false, visibleOrigin: IPoint(0, 0))
        XCTAssertEqual(p.canvas, ISize(560, 360))
    }

    func testAnchors() {
        let img = ISize(100, 50), canvas = ISize(500, 300)
        XCTAssertEqual(PastePlacement.origin(anchor: .center, image: img, canvas: canvas), IPoint(200, 125))
        XCTAssertEqual(PastePlacement.origin(anchor: .bottomRight, image: img, canvas: canvas), IPoint(400, 250))
        XCTAssertEqual(PastePlacement.origin(anchor: .topLeft, image: img, canvas: canvas, offset: IPoint(5, 6)), IPoint(5, 6))
    }
}

final class EngineTests: XCTestCase {
    func makeEngine(_ w: Int = 100, _ h: Int = 80) -> PaintEngine {
        let e = PaintEngine(width: w, height: h)
        e.rng = SplitMix64(seed: 1)
        return e
    }

    // MARK: 貼り付け

    func testPasteIntoPristineCanvasResizesToImage() {
        let e = makeEngine()
        let r = e.paste(solid(30, 20, red))
        XCTAssertFalse(r.floating, "キャンバス全体を覆うので浮かせずにすぐ描き込む")
        XCTAssertEqual(e.canvas, solid(30, 20, red))
        XCTAssertNil(e.selection)
        XCTAssertEqual(e.tool, .pencil, "道具はそのまま（ドラッグで画像ごと動かない）")
        XCTAssertTrue(e.isModified)
    }

    func testUndoBackToPristineFitsNextPaste() {
        let e = makeEngine(100, 80)
        e.paste(solid(30, 20, red))
        e.undo()
        XCTAssertEqual(e.canvas.size, ISize(100, 80))
        XCTAssertTrue(e.isPristine, "元に戻しきったらまっさら扱い")
        e.paste(solid(40, 10, blue))
        XCTAssertEqual(e.canvas, solid(40, 10, blue))
    }

    func testOpenedImageNeverBecomesPristineByUndo() {
        let e = makeEngine(10, 10)
        e.load(solid(50, 40, red))
        e.setTool(.pencil)
        e.mouseDown(at: cp(1, 1), button: .primary)
        e.mouseUp(at: cp(1, 1))
        e.undo()
        XCTAssertFalse(e.isPristine)
    }

    func testLargerImageOnUsedCanvasStillFloats() {
        let e = makeEngine(50, 50)
        e.resizeCanvas(to: ISize(50, 51))
        let r = e.paste(solid(60, 60, red))
        XCTAssertTrue(r.floating, "まっさらでないキャンバスでは浮かせる（透明モードも効く）")
        XCTAssertEqual(e.canvas.size, ISize(60, 60))
        e.commitSelection()
        XCTAssertEqual(e.canvas, solid(60, 60, red))
    }

    func testPasteAtNegativeOriginGrowsLeftAndUp() {
        let e = makeEngine(20, 20)
        e.resizeCanvas(to: ISize(20, 21))
        e.setTool(.pencil)
        e.mouseDown(at: cp(0, 0), button: .primary)
        e.mouseUp(at: cp(0, 0))
        let f = e.paste(solid(10, 10, red), at: IPoint(-5, -3), growCanvas: true)
        XCTAssertEqual(f, IRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(e.canvas.size, ISize(25, 24))
        e.commitSelection()
        XCTAssertEqual(e.canvas[9, 9], red)
        XCTAssertEqual(e.canvas[24, 23], Colors.white)
        // 元の絵は右下へずれている（元の (0,0) の黒い点 → (5,3)。ただし貼った画像の下）
        e.undo()
        XCTAssertEqual(e.canvas.size, ISize(20, 21))
        XCTAssertEqual(e.canvas[0, 0], Colors.black)
    }

    func testPasteAtRejectsHugeGrowth() {
        let e = makeEngine(20, 20)
        XCTAssertNil(e.paste(solid(10, 10, red), at: IPoint(50_000, 50_000), growCanvas: true))
        XCTAssertEqual(e.canvas.size, ISize(20, 20))
        XCTAssertFalse(e.canUndo)
    }

    func testDeletingFloatingPasteIsUndoable() {
        let e = makeEngine(50, 50)
        e.resizeCanvas(to: ISize(50, 51))
        e.paste(solid(10, 10, red), at: IPoint(5, 5), growCanvas: true)
        e.deleteSelection()
        XCTAssertEqual(e.canvas[6, 6], Colors.white)
        e.undo()
        XCTAssertEqual(e.canvas[6, 6], red, "消す直前の見た目に戻る")
    }

    func testCommitAfterSaveIsNotAModification() {
        let e = makeEngine(50, 50)
        e.resizeCanvas(to: ISize(50, 51))
        e.paste(solid(10, 10, red), at: IPoint(5, 5), growCanvas: true)
        e.markSaved()
        e.commitSelection()
        XCTAssertFalse(e.isModified)
        e.paste(solid(10, 10, red), at: IPoint(5, 5), growCanvas: true)
        e.markSaved()
        e.nudgeSelection(dx: 1, dy: 0)
        XCTAssertTrue(e.isModified, "動かしたら変更あり")
    }

    func testPasteLargerImageGrowsCanvasAndFillsWithBackground() {
        let e = makeEngine(50, 50)
        e.mouseDown(at: cp(1, 1), button: .primary)
        e.mouseUp(at: cp(1, 1))
        XCTAssertFalse(e.isPristine)
        e.secondary = blue
        e.paste(solid(80, 30, red))
        XCTAssertEqual(e.canvas.size, ISize(80, 50))
        e.commitSelection()
        XCTAssertEqual(e.canvas[79, 0], red)
        XCTAssertEqual(e.canvas[79, 49], blue, "広げた部分は背景色")
        XCTAssertEqual(e.canvas[1, 1], red, "画像は左上")
    }

    func testPasteSmallerImageFloatsAndCanBePositioned() {
        let e = makeEngine(100, 80)
        e.resizeCanvas(to: ISize(120, 90))
        e.paste(solid(10, 10, red), visibleOrigin: IPoint(20, 30))
        XCTAssertEqual(e.canvas.size, ISize(120, 90))
        XCTAssertEqual(e.selection?.frame, IRect(x: 20, y: 30, width: 10, height: 10))
        // ドラッグで移動
        e.mouseDown(at: cp(25, 35), button: .primary)
        e.mouseDragged(to: cp(65, 45))
        e.mouseUp(at: cp(65, 45))
        XCTAssertEqual(e.selection?.frame.origin, IPoint(60, 40))
        // 矢印キーで微調整
        e.nudgeSelection(dx: 1, dy: -2)
        XCTAssertEqual(e.selection?.frame.origin, IPoint(61, 38))
        XCTAssertEqual(e.canvas[25, 35], Colors.white, "確定前はキャンバスに描かれていない")
        // 外側をクリックで確定
        e.mouseDown(at: cp(2, 2), button: .primary)
        e.mouseUp(at: cp(2, 2))
        XCTAssertNil(e.selection)
        XCTAssertEqual(e.canvas[61, 38], red)
        XCTAssertEqual(e.canvas[70, 47], red)
        XCTAssertEqual(e.canvas[71, 48], Colors.white)
        XCTAssertEqual(e.canvas[25, 35], Colors.white)
    }

    func testPasteAtSpecifiedPosition() {
        let e = makeEngine(100, 80)
        e.resizeCanvas(to: ISize(100, 81))
        e.paste(solid(10, 10, red), at: IPoint(85, 5), growCanvas: true)
        XCTAssertEqual(e.canvas.size, ISize(100, 81), "収まるなら広げない")
        XCTAssertEqual(e.selection?.frame.origin, IPoint(85, 5))
        e.commitSelection()
        XCTAssertEqual(e.canvas[94, 5], red)
        e.paste(solid(10, 10, blue), at: IPoint(95, 75), growCanvas: true)
        XCTAssertEqual(e.canvas.size, ISize(105, 85), "はみ出す分だけ広げる")
    }

    func testPasteAsNewImage() {
        let e = makeEngine(100, 80)
        e.mouseDown(at: cp(1, 1), button: .primary)
        e.mouseUp(at: cp(1, 1))
        e.pasteAsNewImage(solid(7, 9, red))
        XCTAssertEqual(e.canvas, solid(7, 9, red))
        XCTAssertNil(e.selection)
        e.undo()
        XCTAssertEqual(e.canvas.size, ISize(100, 80))
    }

    func testUndoFloatingPasteRestoresCanvasAndSize() {
        let e = makeEngine(50, 50)
        e.resizeCanvas(to: ISize(60, 60))
        let before = e.canvas
        e.paste(solid(100, 10, red))
        XCTAssertEqual(e.canvas.size, ISize(100, 60))
        e.undo()
        XCTAssertNil(e.selection)
        XCTAssertEqual(e.canvas, before)
        e.redo()
        XCTAssertEqual(e.canvas.size, ISize(100, 60))
        XCTAssertEqual(e.canvas[99, 0], red)
    }

    func testPasteCommitsPreviousSelection() {
        let e = makeEngine(50, 50)
        e.resizeCanvas(to: ISize(60, 60))
        e.paste(solid(5, 5, red), at: IPoint(10, 10), growCanvas: true)
        e.paste(solid(5, 5, blue), at: IPoint(30, 30), growCanvas: true)
        XCTAssertEqual(e.canvas[10, 10], red)
        XCTAssertEqual(e.selection?.frame.origin, IPoint(30, 30))
    }

    func testTransparentPasteSkipsBackgroundColor() {
        let e = makeEngine(20, 20)
        e.resizeCanvas(to: ISize(20, 21))
        e.clearImage()
        var fill = solid(20, 21, blue)
        fill[0, 0] = blue
        e.paste(fill, at: IPoint(0, 0), growCanvas: true)
        e.commitSelection()
        var img = solid(4, 4, Colors.white)
        img[1, 1] = red
        e.options.transparentBackground = true
        e.paste(img, at: IPoint(0, 0), growCanvas: true)
        e.commitSelection()
        XCTAssertEqual(e.canvas[0, 0], blue, "背景色（白）は透ける")
        XCTAssertEqual(e.canvas[1, 1], red)
    }

    // MARK: 選択・コピー

    func testSelectCopyCutAndMove() {
        let e = makeEngine(40, 40)
        e.setTool(.rectangle)
        e.options.fillStyle = .fill
        e.mouseDown(at: cp(10, 10), button: .primary)
        e.mouseDragged(to: cp(19, 19))
        e.mouseUp(at: cp(19, 19))
        e.setTool(.select)
        e.mouseDown(at: cp(10, 10), button: .primary)
        e.mouseDragged(to: cp(14, 14))
        e.mouseUp(at: cp(14, 14))
        XCTAssertEqual(e.selection?.frame, IRect(x: 10, y: 10, width: 5, height: 5))
        let copied = e.copyImage()
        XCTAssertEqual(copied, solid(5, 5, Colors.black))
        // 移動すると元の場所は背景色
        e.mouseDown(at: cp(12, 12), button: .primary)
        e.mouseDragged(to: cp(32, 12))
        e.mouseUp(at: cp(32, 12))
        e.commitSelection()
        XCTAssertEqual(e.canvas[10, 10], Colors.white)
        XCTAssertEqual(e.canvas[30, 10], Colors.black)
        XCTAssertEqual(e.canvas[15, 15], Colors.black)
        // 移動はまとめて 1 回で元に戻る
        e.undo()
        XCTAssertEqual(e.canvas[10, 10], Colors.black)
        XCTAssertEqual(e.canvas[30, 10], Colors.white)
    }

    func testOptionDragDuplicates() {
        let e = makeEngine(40, 40)
        e.paste(solid(5, 5, red), at: IPoint(0, 0), growCanvas: true)
        e.commitSelection()
        e.setTool(.select)
        e.mouseDown(at: cp(0, 0), button: .primary)
        e.mouseDragged(to: cp(4, 4))
        e.mouseUp(at: cp(4, 4))
        e.mouseDown(at: cp(2, 2), button: .primary, modifiers: .option)
        e.mouseDragged(to: cp(22, 2), modifiers: .option)
        e.mouseUp(at: cp(22, 2), modifiers: .option)
        e.commitSelection()
        XCTAssertEqual(e.canvas[0, 0], red, "元の場所に残る")
        XCTAssertEqual(e.canvas[20, 0], red)
    }

    func testCutLeavesBackgroundAndReturnsImage() {
        let e = makeEngine(20, 20)
        e.paste(solid(20, 20, red))
        e.commitSelection()
        e.secondary = blue
        e.setTool(.select)
        e.mouseDown(at: cp(5, 5), button: .primary)
        e.mouseDragged(to: cp(9, 9))
        e.mouseUp(at: cp(9, 9))
        let img = e.cut()
        XCTAssertEqual(img, solid(5, 5, red))
        XCTAssertEqual(e.canvas[5, 5], blue)
        XCTAssertNil(e.selection)
        e.undo()
        XCTAssertEqual(e.canvas[5, 5], red)
    }

    func testCopyWithoutSelectionCopiesWholeCanvas() {
        let e = makeEngine(10, 10)
        XCTAssertEqual(e.copyImage().size, ISize(10, 10))
        XCTAssertNil(e.cut())
    }

    func testCropToSelection() {
        let e = makeEngine(50, 50)
        e.paste(corners(50, 50))
        e.commitSelection()
        e.setTool(.select)
        e.mouseDown(at: cp(0, 0), button: .primary)
        e.mouseDragged(to: cp(9, 4))
        e.mouseUp(at: cp(9, 4))
        e.cropToSelection()
        XCTAssertEqual(e.canvas.size, ISize(10, 5))
        XCTAssertEqual(e.canvas[0, 0], red)
        e.undo()
        XCTAssertEqual(e.canvas.size, ISize(50, 50))
    }

    func testResizeSelectionWithHandle() {
        let e = makeEngine(100, 100)
        e.resizeCanvas(to: ISize(100, 101))
        e.paste(corners(10, 10), at: IPoint(10, 10), growCanvas: true)
        // 右下のハンドル（キャンバス座標 20,20）を 10 ピクセル引っ張る
        XCTAssertEqual(e.handle(at: CanvasPoint(20, 20)), .bottomRight)
        e.mouseDown(at: CanvasPoint(20, 20), button: .primary)
        e.mouseDragged(to: CanvasPoint(30, 30))
        e.mouseUp(at: CanvasPoint(30, 30))
        XCTAssertEqual(e.selection?.frame, IRect(x: 10, y: 10, width: 20, height: 20))
        XCTAssertEqual(e.selection?.image.size, ISize(20, 20))
        e.commitSelection()
        XCTAssertEqual(e.canvas[29, 29], Colors.black)
        XCTAssertEqual(e.canvas[28, 28], Colors.black)
        XCTAssertEqual(e.canvas[10, 10], red)
    }

    func testSelectAllAndDelete() {
        let e = makeEngine(10, 10)
        e.paste(solid(10, 10, red))
        e.commitSelection()
        e.selectAll()
        XCTAssertEqual(e.selection?.frame, IRect(x: 0, y: 0, width: 10, height: 10))
        e.deleteSelection()
        XCTAssertEqual(e.canvas, solid(10, 10, Colors.white))
    }

    func testFreeSelectMask() {
        let e = makeEngine(40, 40)
        e.paste(solid(40, 40, red))
        e.commitSelection()
        e.setTool(.freeSelect)
        // 三角形
        e.mouseDown(at: cp(0, 0), button: .primary)
        e.mouseDragged(to: cp(20, 0))
        e.mouseDragged(to: cp(0, 20))
        e.mouseUp(at: cp(0, 0))
        XCTAssertEqual(e.selection?.frame, IRect(x: 0, y: 0, width: 21, height: 21))
        e.mouseDown(at: cp(2, 2), button: .primary)
        e.mouseDragged(to: cp(22, 2))
        e.mouseUp(at: cp(22, 2))
        e.commitSelection()
        XCTAssertEqual(e.canvas[1, 1], Colors.white, "三角の中は抜ける")
        XCTAssertEqual(e.canvas[19, 19], red, "三角の外は残る")
        XCTAssertEqual(e.canvas[21, 1], red, "移動先に描かれる")
        XCTAssertEqual(e.canvas[39, 19], red, "移動先でも三角の外は元のまま")
    }

    func testRotateSelectionOnly() {
        let e = makeEngine(40, 40)
        e.paste(solid(40, 40, Colors.white))
        e.commitSelection()
        e.paste(corners(4, 2), at: IPoint(10, 10), growCanvas: true)
        e.rotateClockwise()
        XCTAssertEqual(e.selection?.frame, IRect(x: 10, y: 10, width: 2, height: 4))
        XCTAssertEqual(e.canvas.size, ISize(40, 40))
        e.commitSelection()
        XCTAssertEqual(e.canvas[11, 10], red)
    }

    // MARK: 描画ツール

    func testPencilStrokeAndUndoRedo() {
        let e = makeEngine(20, 20)
        e.setTool(.pencil)
        e.mouseDown(at: cp(0, 0), button: .primary)
        e.mouseDragged(to: cp(9, 0))
        e.mouseUp(at: cp(9, 0))
        XCTAssertEqual(e.canvas[5, 0], Colors.black)
        e.mouseDown(at: cp(0, 5), button: .secondary)
        e.mouseUp(at: cp(0, 5))
        XCTAssertEqual(e.canvas[0, 5], Colors.white, "右クリックは背景色")
        e.undo()
        e.undo()
        XCTAssertEqual(e.canvas[5, 0], Colors.white)
        e.redo()
        XCTAssertEqual(e.canvas[5, 0], Colors.black)
    }

    func testShapePreviewDoesNotTouchCanvasUntilMouseUp() {
        let e = makeEngine(30, 30)
        e.setTool(.line)
        e.mouseDown(at: cp(0, 0), button: .primary)
        e.mouseDragged(to: cp(29, 29))
        XCTAssertEqual(e.canvas[15, 15], Colors.white)
        XCTAssertEqual(e.renderDisplay()[15, 15], Colors.black)
        XCTAssertEqual(e.liveSize, ISize(30, 30))
        e.mouseUp(at: cp(29, 29))
        XCTAssertEqual(e.canvas[15, 15], Colors.black)
        XCTAssertNil(e.liveSize)
    }

    func testFillAndPicker() {
        let e = makeEngine(10, 10)
        e.primary = red
        e.setTool(.fill)
        e.mouseDown(at: cp(3, 3), button: .primary)
        e.mouseUp(at: cp(3, 3))
        XCTAssertEqual(e.canvas[9, 9], red)
        e.setTool(.picker)
        e.mouseDown(at: cp(1, 1), button: .secondary)
        e.mouseUp(at: cp(1, 1))
        XCTAssertEqual(e.secondary, red)
        XCTAssertEqual(e.tool, .fill, "色を拾ったら前の道具に戻る")
    }

    func testColorEraserOnlyReplacesPrimary() {
        let e = makeEngine(20, 20)
        e.paste(solid(20, 20, blue))
        e.commitSelection()
        e.setTool(.pencil)
        e.mouseDown(at: cp(5, 5), button: .primary)
        e.mouseUp(at: cp(5, 5))
        e.setTool(.eraser)
        e.mouseDown(at: cp(5, 5), button: .secondary)
        e.mouseUp(at: cp(5, 5))
        XCTAssertEqual(e.canvas[5, 5], Colors.white)
        XCTAssertEqual(e.canvas[6, 6], blue)
    }

    func testPolygonClosesOnDoubleClick() {
        let e = makeEngine(40, 40)
        e.setTool(.polygon)
        e.options.fillStyle = .fill
        e.mouseDown(at: cp(5, 5), button: .primary)
        e.mouseDragged(to: cp(30, 5))
        e.mouseUp(at: cp(30, 5))
        e.mouseDown(at: cp(30, 30), button: .primary)
        e.mouseUp(at: cp(30, 30))
        XCTAssertEqual(e.canvas[20, 10], Colors.white, "閉じるまでは描かれない")
        e.mouseDown(at: cp(30, 30), button: .primary, clickCount: 2)
        XCTAssertEqual(e.canvas[25, 10], Colors.black)
        XCTAssertFalse(e.hasPendingShape)
    }

    func testCurveThreeSteps() {
        let e = makeEngine(40, 40)
        e.setTool(.curve)
        e.mouseDown(at: cp(0, 20), button: .primary)
        e.mouseDragged(to: cp(39, 20))
        e.mouseUp(at: cp(39, 20))
        e.mouseDown(at: cp(20, 0), button: .primary)
        e.mouseUp(at: cp(20, 0))
        XCTAssertEqual(e.canvas[0, 20], Colors.white)
        e.mouseDown(at: cp(20, 0), button: .primary)
        e.mouseUp(at: cp(20, 0))
        XCTAssertEqual(e.canvas[0, 20], Colors.black)
        XCTAssertEqual(e.canvas[20, 20], Colors.white, "曲がっている")
    }

    func testSwitchingToolCommitsPendingPolygon() {
        let e = makeEngine(40, 40)
        e.setTool(.polygon)
        e.mouseDown(at: cp(5, 5), button: .primary)
        e.mouseDragged(to: cp(30, 5))
        e.mouseUp(at: cp(30, 5))
        e.setTool(.pencil)
        XCTAssertEqual(e.canvas[20, 5], Colors.black)
    }

    func testAirbrushTicks() {
        let e = makeEngine(40, 40)
        e.setTool(.airbrush)
        e.mouseDown(at: cp(20, 20), button: .primary)
        XCTAssertTrue(e.isAirbrushing)
        for _ in 0..<20 { e.airbrushTick() }
        e.mouseUp(at: cp(20, 20))
        XCTAssertFalse(e.isAirbrushing)
        XCTAssertGreaterThan(e.canvas.pixels.filter { $0 == Colors.black }.count, 30)
    }

    func testMagnifierEmitsEvent() {
        let e = makeEngine(40, 40)
        var events: [EngineEvent] = []
        e.listener = { events.append($0) }
        e.setTool(.magnifier)
        e.mouseDown(at: cp(10, 12), button: .primary)
        XCTAssertTrue(events.contains(.magnify(level: 4, center: IPoint(10, 12))))
        e.zoom = 4
        e.mouseDown(at: cp(10, 12), button: .primary)
        XCTAssertTrue(events.contains(.magnify(level: 1, center: IPoint(10, 12))))
    }

    // MARK: テキスト

    func testTextBoxAndCommit() {
        let e = makeEngine(100, 60)
        e.setTool(.text)
        e.mouseDown(at: cp(10, 10), button: .primary)
        e.mouseUp(at: cp(10, 10))
        XCTAssertEqual(e.textBox, IRect(x: 10, y: 10, width: 90, height: e.defaultTextBoxSize.height), "既定の枠をキャンバス内に収める")
        var glyphs = Bitmap(width: 20, height: 10, fill: Colors.clear)
        glyphs.fill(IRect(x: 0, y: 0, width: 3, height: 3), with: red)
        e.secondary = blue
        e.commitText(glyphs, at: IPoint(10, 10))
        XCTAssertNil(e.textBox)
        XCTAssertEqual(e.canvas[10, 10], red)
        XCTAssertEqual(e.canvas[20, 15], blue, "不透明モードは背景色で塗る")
        e.undo()
        XCTAssertEqual(e.canvas[20, 15], Colors.white)
        e.options.transparentBackground = true
        e.mouseDown(at: cp(10, 10), button: .primary)
        e.mouseDragged(to: cp(60, 40))
        e.mouseUp(at: cp(60, 40))
        XCTAssertEqual(e.textBox, IRect(x: 10, y: 10, width: 51, height: 31))
        e.commitText(glyphs, at: IPoint(10, 10))
        XCTAssertEqual(e.canvas[20, 15], Colors.white, "透明モードは背景を塗らない")
    }

    func testSwitchingToolDropsTextBox() {
        let e = makeEngine(100, 60)
        e.setTool(.text)
        e.mouseDown(at: cp(10, 10), button: .primary)
        e.mouseUp(at: cp(10, 10))
        e.setTool(.pencil)
        XCTAssertNil(e.textBox)
    }

    // MARK: キャンバス

    func testNewImageResetsState() {
        let e = makeEngine(10, 10)
        e.paste(solid(5, 5, red))
        e.newImage(size: ISize(30, 20))
        XCTAssertTrue(e.isPristine)
        XCTAssertFalse(e.isModified)
        XCTAssertFalse(e.canUndo)
        XCTAssertNil(e.selection)
        XCTAssertEqual(e.canvas, solid(30, 20, Colors.white))
    }

    func testLoadIsNotPristine() {
        let e = makeEngine(10, 10)
        e.load(solid(50, 40, red))
        XCTAssertFalse(e.isPristine)
        XCTAssertFalse(e.isModified)
        e.paste(solid(5, 5, blue))
        XCTAssertEqual(e.canvas.size, ISize(50, 40), "開いた画像には普通に浮かせて貼る")
    }

    func testStretchAndInvertWholeCanvas() {
        let e = makeEngine(10, 10)
        e.stretch(percentX: 200, percentY: 50)
        XCTAssertEqual(e.canvas.size, ISize(20, 5))
        e.invertColors()
        XCTAssertEqual(e.canvas[0, 0], Colors.black)
        e.undo()
        e.undo()
        XCTAssertEqual(e.canvas.size, ISize(10, 10))
    }

    func testFlattenedIncludesFloatingSelectionWithoutCommitting() {
        let e = makeEngine(20, 20)
        e.resizeCanvas(to: ISize(20, 21))
        e.paste(solid(5, 5, red), at: IPoint(2, 2), growCanvas: true)
        let flat = e.flattened()
        XCTAssertEqual(flat[3, 3], red)
        XCTAssertEqual(e.canvas[3, 3], Colors.white, "flattened は状態を変えない")
        XCTAssertNotNil(e.selection)
    }

    func testFinishPendingClosesPolygonAndCommitsSelection() {
        let e = makeEngine(40, 40)
        e.setTool(.polygon)
        e.mouseDown(at: cp(5, 5), button: .primary)
        e.mouseDragged(to: cp(30, 5))
        e.mouseUp(at: cp(30, 5))
        e.finishPending()
        XCTAssertFalse(e.hasPendingShape)
        XCTAssertEqual(e.canvas[20, 5], Colors.black)
        e.resizeCanvas(to: ISize(40, 41))
        e.paste(solid(3, 3, blue), at: IPoint(30, 30), growCanvas: true)
        e.finishPending()
        XCTAssertNil(e.selection)
        XCTAssertEqual(e.canvas[31, 31], blue)
    }

    func testRightButtonShapeSwapsColors() {
        let e = makeEngine(20, 20)
        e.primary = red
        e.secondary = blue
        e.setTool(.rectangle)
        e.options.fillStyle = .outlineAndFill
        e.mouseDown(at: cp(0, 0), button: .secondary)
        e.mouseDragged(to: cp(9, 9))
        e.mouseUp(at: cp(9, 9))
        XCTAssertEqual(e.canvas[0, 0], blue, "右ボタンは輪郭が背景色")
        XCTAssertEqual(e.canvas[5, 5], red, "塗りは描画色")
    }

    func testTextBackgroundRect() {
        let e = makeEngine(100, 60)
        e.setTool(.text)
        e.mouseDown(at: cp(10, 10), button: .primary)
        e.mouseDragged(to: cp(50, 40))
        e.mouseUp(at: cp(50, 40))
        e.secondary = blue
        let glyphs = Bitmap(width: 61, height: 51, fill: Colors.clear)
        e.commitText(glyphs, at: IPoint(0, 0), background: IRect(x: 10, y: 10, width: 41, height: 31))
        XCTAssertEqual(e.canvas[10, 10], blue)
        XCTAssertEqual(e.canvas[5, 5], Colors.white, "余白は塗らない")
    }

    func testTextBoxStaysInsideCanvas() {
        let e = makeEngine(100, 60)
        e.setTool(.text)
        e.mouseDown(at: cp(120, 10), button: .primary)
        e.mouseUp(at: cp(120, 10))
        XCTAssertNil(e.textBox, "キャンバスの外には枠を作らない")
        e.mouseDown(at: cp(90, 50), button: .primary)
        e.mouseUp(at: cp(90, 50))
        XCTAssertEqual(e.textBox, IRect(x: 52, y: 36, width: 48, height: 24), "端では中へずらす（最低限の幅は残す）")
        e.updateTextBox(IRect(x: 52, y: 36, width: 48, height: 40))
        XCTAssertEqual(e.textBox, IRect(x: 52, y: 20, width: 48, height: 40), "文字が増えて下にはみ出す分は上へずらす")
    }

    // MARK: レビュー指摘の再発防止

    func testTransparencyChangeUnderFloatingPasteMarksModified() {
        let e = makeEngine(50, 50)
        e.resizeCanvas(to: ISize(50, 51))
        e.paste(solid(10, 10, red), at: IPoint(5, 5), growCanvas: true)
        e.markSaved()
        e.options.transparentBackground = true
        XCTAssertTrue(e.isModified)
    }

    func testPasteAtNegativeOriginEmitsCanvasSize() {
        let e = makeEngine(20, 20)
        e.resizeCanvas(to: ISize(20, 21))
        var events: [EngineEvent] = []
        e.listener = { events.append($0) }
        e.paste(solid(10, 10, red), at: IPoint(-5, 0), growCanvas: true)
        XCTAssertTrue(events.contains(.canvasSize))
    }

    func testPasteAtOnHugeCanvasThatFits() {
        let e = makeEngine(10, 10)
        e.load(Bitmap(width: 12_000, height: 20))
        XCTAssertNotNil(e.paste(solid(5, 5, red), at: IPoint(100, 2), growCanvas: true))
    }

}


/// Skitch の部品（絵の上に乗っていて、あとから選び直せる）
final class SkitchTests: XCTestCase {
    /// テスト用：部品の範囲を色で塗るだけの描画関数
    private func fakeRenderer(_ a: Annotation, _ clip: IRect) -> RenderedAnnotation? {
        switch a.shape {
        case .arrow(let t, let h):
            let r = IRect.spanning(t, h)
            return RenderedAnnotation(image: Bitmap(width: r.width, height: r.height, fill: a.color), origin: r.origin)
        case .box(let r):
            return RenderedAnnotation(image: Bitmap(width: r.width, height: r.height, fill: a.color), origin: r.origin)
        case .stamp(_, let c, let rad):
            return RenderedAnnotation(image: Bitmap(width: rad * 2, height: rad * 2, fill: a.color),
                                      origin: IPoint(c.x - rad, c.y - rad))
        case .text(_, let f, _):
            return RenderedAnnotation(image: Bitmap(width: f.width, height: f.height, fill: a.color), origin: f.origin)
        }
    }

    private func makeEngine(_ w: Int = 200, _ h: Int = 200) -> PaintEngine {
        let e = PaintEngine(width: w, height: h)
        e.annotationRenderer = fakeRenderer
        e.textMeasurer = { s, w, size in ISize(w, size + 4) }
        return e
    }

    private func drag(_ e: PaintEngine, _ a: IPoint, _ b: IPoint, clickCount: Int = 1, modifiers: Modifiers = []) {
        e.mouseDown(at: cp(a.x, a.y), button: .primary, modifiers: modifiers, clickCount: clickCount)
        e.mouseDragged(to: cp(b.x, b.y), modifiers: modifiers)
        e.mouseUp(at: cp(b.x, b.y), modifiers: modifiers)
    }

    private func click(_ e: PaintEngine, _ p: IPoint, clickCount: Int = 1) {
        e.mouseDown(at: cp(p.x, p.y), button: .primary, clickCount: clickCount)
        e.mouseUp(at: cp(p.x, p.y))
    }

    func testToolGroups() {
        XCTAssertEqual(Tool.paintTools.count, 16)
        XCTAssertEqual(Set(Tool.paintTools + Tool.skitchTools).count, Tool.allCases.count)
        XCTAssertTrue(Tool.skitchText.isText && Tool.skitchText.isSkitch)
        XCTAssertFalse(Tool.text.isSkitch)
        XCTAssertEqual(ToolOptions.skitchThicknesses, [1, 2, 3, 4, 5], "極太・超極太まで")
        XCTAssertGreaterThan(Annotation.arrowWidth(5), Annotation.arrowWidth(3) * 2)
    }

    func testPartsStayAboveThePaintingAndAreNotBaked() {
        let e = makeEngine()
        e.setTool(.arrow)
        drag(e, IPoint(10, 10), IPoint(60, 40))
        XCTAssertEqual(e.annotations.count, 1)
        XCTAssertEqual(e.canvas[30, 25], Colors.white, "絵には焼き込まない")
        XCTAssertEqual(e.renderDisplay()[30, 25], Annotation.skitchRed)
        XCTAssertEqual(e.flattened()[30, 25], Annotation.skitchRed, "保存には重ねる")
        XCTAssertEqual(e.copyImage()[30, 25], Annotation.skitchRed, "コピーにも重ねる")
        // ペイントの道具に替えても部品は残る
        e.setTool(.pencil)
        XCTAssertEqual(e.annotations.count, 1)
        XCTAssertNil(e.selectedAnnotation)
        XCTAssertNil(e.annotationPart(at: cp(30, 25)), "ペイントの道具では部品をつかめない")
    }

    func testReselectAndAdjustLaterWithAnySkitchTool() {
        let e = makeEngine()
        e.setTool(.arrow)
        drag(e, IPoint(10, 10), IPoint(80, 10))
        drag(e, IPoint(10, 100), IPoint(80, 100))
        XCTAssertEqual(e.annotations.count, 2)
        // 別の道具を使ってから戻っても、1 本目の先端をつまんで直せる
        e.setTool(.pencil)
        e.setTool(.skitchBox)
        XCTAssertEqual(e.annotationPart(at: cp(80, 10)), .head)
        drag(e, IPoint(80, 10), IPoint(90, 30))
        XCTAssertEqual(e.annotations[0].shape, .arrow(tail: IPoint(10, 10), head: IPoint(90, 30)))
        XCTAssertEqual(e.selectedAnnotation, 0)
        // 本体をつかんで移動
        drag(e, IPoint(40, 100), IPoint(40, 120))
        XCTAssertEqual(e.annotations[1].shape, .arrow(tail: IPoint(10, 120), head: IPoint(80, 120)))
        // 元に戻すは 1 操作ずつ
        e.undo()
        XCTAssertEqual(e.annotations[1].shape, .arrow(tail: IPoint(10, 100), head: IPoint(80, 100)))
        e.undo()
        XCTAssertEqual(e.annotations[0].shape, .arrow(tail: IPoint(10, 10), head: IPoint(80, 10)))
        e.redo()
        XCTAssertEqual(e.annotations[0].shape, .arrow(tail: IPoint(10, 10), head: IPoint(90, 30)))
    }

    func testSelectingSyncsToolbarAndToolbarEditsSelection() {
        let e = makeEngine()
        e.setTool(.arrow)
        e.options.skitchThickness = 4
        e.skitchColor = Colors.rgb(40, 130, 230)
        drag(e, IPoint(10, 10), IPoint(80, 10))
        e.options.skitchThickness = 1
        e.skitchColor = Annotation.skitchRed
        // 選択を外してから新しい矢印（細い赤）
        click(e, IPoint(150, 150))
        drag(e, IPoint(10, 100), IPoint(80, 100))
        XCTAssertEqual(e.annotations[1].thickness, 1)
        // 1 本目を選ぶとツールバーが 1 本目の色・太さになる
        click(e, IPoint(40, 10))
        XCTAssertEqual(e.selectedAnnotation, 0)
        XCTAssertEqual(e.options.skitchThickness, 1, "あとから変えた太さが選択中の部品に効いている")
        XCTAssertEqual(e.skitchColor, Annotation.skitchRed)
        // 太さを超極太に
        e.options.skitchThickness = 5
        XCTAssertEqual(e.annotations[0].thickness, 5)
        XCTAssertEqual(e.annotations[1].thickness, 1, "選んでいない部品は変わらない")
    }

    func testDeleteAndUndoRestoresPart() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        XCTAssertEqual(e.selectedAnnotation, 0)
        e.deleteAnnotation()
        XCTAssertTrue(e.annotations.isEmpty)
        e.undo()
        XCTAssertEqual(e.annotations.count, 1)
        XCTAssertEqual(e.flattened()[50, 50], StampKind.cross.defaultColor)
    }

    func testStampClickOnEmptyFirstDeselectsThenPlaces() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        click(e, IPoint(150, 150))
        XCTAssertEqual(e.annotations.count, 1, "選んでいる間の外側クリックは選択を外すだけ")
        XCTAssertNil(e.selectedAnnotation)
        click(e, IPoint(150, 150))
        XCTAssertEqual(e.annotations.count, 2)
    }

    func testStampDragSizesOnPlacement() {
        let e = makeEngine()
        e.setTool(.stamp)
        drag(e, IPoint(50, 50), IPoint(80, 60))
        XCTAssertEqual(e.annotations[0].shape, .stamp(.cross, center: IPoint(50, 50), radius: 30))
    }

    func testBoxCreateResizeMove() {
        let e = makeEngine()
        e.setTool(.skitchBox)
        drag(e, IPoint(20, 20), IPoint(80, 60))
        XCTAssertEqual(e.annotations[0].shape, .box(IRect(x: 20, y: 20, width: 61, height: 41)))
        let br = SelectionHandle.bottomRight.position(in: IRect(x: 20, y: 20, width: 61, height: 41))
        XCTAssertEqual(e.annotationPart(at: br), .boxHandle(.bottomRight))
        e.mouseDown(at: br, button: .primary)
        e.mouseDragged(to: CanvasPoint(br.x + 20, br.y + 10))
        e.mouseUp(at: CanvasPoint(br.x + 20, br.y + 10))
        XCTAssertEqual(e.annotations[0].shape, .box(IRect(x: 20, y: 20, width: 81, height: 51)))
        XCTAssertNil(e.annotationPart(at: cp(60, 45)), "中は空いている")
        drag(e, IPoint(20, 30), IPoint(30, 40))
        XCTAssertEqual(e.annotations[0].shape, .box(IRect(x: 30, y: 30, width: 81, height: 51)))
        // 中をクリック：選択を外すだけで、小さすぎる四角は置かない
        click(e, IPoint(60, 50))
        XCTAssertEqual(e.annotations.count, 1)
        XCTAssertNil(e.selectedAnnotation)
    }

    func testBoxShiftMakesSquare() {
        let e = makeEngine()
        e.setTool(.skitchBox)
        drag(e, IPoint(10, 10), IPoint(50, 30), modifiers: .shift)
        XCTAssertEqual(e.annotations[0].shape, .box(IRect(x: 10, y: 10, width: 41, height: 41)))
    }

    func testShortArrowIsNotPlacedAndOverShrinkRestores() {
        let e = makeEngine()
        e.setTool(.arrow)
        click(e, IPoint(10, 10))
        XCTAssertTrue(e.annotations.isEmpty)
        XCTAssertFalse(e.canUndo, "置かなかったものは履歴に残さない")
        drag(e, IPoint(10, 10), IPoint(60, 10))
        drag(e, IPoint(60, 10), IPoint(12, 10))
        XCTAssertEqual(e.annotations[0].shape, .arrow(tail: IPoint(10, 10), head: IPoint(60, 10)))
    }

    func testTextCreateAndReEdit() {
        let e = makeEngine()
        e.setTool(.skitchText)
        click(e, IPoint(20, 20))
        XCTAssertNotNil(e.textBox)
        XCTAssertTrue(e.textBoxIsSkitch)
        e.commitSkitchText("こんにちは", measured: ISize(120, 32))
        XCTAssertEqual(e.annotations.count, 1)
        guard case .text(let s, let f, let size) = e.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(s, "こんにちは")
        XCTAssertEqual(f.origin, IPoint(20, 20))
        XCTAssertEqual(f.height, 32)
        XCTAssertEqual(size, ToolOptions.skitchTextPixels(e.options.skitchTextSize))
        XCTAssertEqual(e.annotations[0].color, Annotation.skitchRed)
        XCTAssertEqual(e.canvas[25, 25], Colors.white, "文字も絵には焼き込まない")
        // 文字ツールでクリックすると打ち直し
        click(e, IPoint(25, 25))
        XCTAssertEqual(e.editingAnnotation, 0)
        XCTAssertEqual(e.textEditInitial, "こんにちは")
        XCTAssertEqual(e.textBox?.origin, IPoint(20, 20))
        XCTAssertEqual(e.renderDisplay()[25, 25], Colors.white, "打ち直している間は元の文字を隠す")
        e.commitSkitchText("こんばんは", measured: ISize(120, 32))
        guard case .text(let s2, _, _) = e.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(s2, "こんばんは")
        XCTAssertEqual(e.annotations.count, 1)
        e.undo()
        guard case .text(let s3, _, _) = e.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(s3, "こんにちは")
    }

    func testDoubleClickEditsTextWithOtherSkitchTool() {
        let e = makeEngine()
        e.setTool(.skitchText)
        click(e, IPoint(20, 20))
        e.commitSkitchText("文字", measured: ISize(100, 30))
        e.setTool(.arrow)
        click(e, IPoint(25, 25))
        XCTAssertEqual(e.selectedAnnotation, 0)
        XCTAssertNil(e.editingAnnotation, "1 回目のクリックは選ぶだけ")
        e.mouseDown(at: cp(25, 25), button: .primary, clickCount: 2)
        e.mouseUp(at: cp(25, 25))
        XCTAssertEqual(e.editingAnnotation, 0, "ダブルクリックで打ち直し")
        XCTAssertTrue(e.textBoxIsSkitch)
        // 空にして確定すると消える
        e.commitSkitchText("", measured: ISize(100, 30))
        XCTAssertTrue(e.annotations.isEmpty)
    }

    func testTextSizeChangeOnSelectedTextRemeasures() {
        let e = makeEngine()
        e.setTool(.skitchText)
        click(e, IPoint(20, 20))
        e.commitSkitchText("abc", measured: ISize(100, 30))
        e.setTool(.arrow)
        click(e, IPoint(25, 25))
        e.options.skitchTextSize = 2
        guard case .text(_, let f, let size) = e.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(size, 40)
        XCTAssertEqual(f.height, 44, "大きさに合わせて測り直す")
    }

    func testSkitchColorIsIndependentOfPaintColors() {
        let e = makeEngine()
        XCTAssertEqual(e.skitchColor, Colors.rgb(235, 69, 110))
        e.setTool(.arrow)
        e.mouseDown(at: cp(10, 10), button: .secondary)
        e.mouseDragged(to: cp(60, 10))
        e.mouseUp(at: cp(60, 10))
        XCTAssertEqual(e.annotations[0].color, Annotation.skitchRed, "右ボタンでも Skitch の色")
        e.primary = Colors.rgb(0, 0, 255)
        e.swapColors()
        XCTAssertEqual(e.annotations[0].color, Annotation.skitchRed)
        e.skitchColor = Colors.rgb(60, 185, 90)
        XCTAssertEqual(e.annotations[0].color, Colors.rgb(60, 185, 90), "選んでいる部品は Skitch の色で変わる")
    }

    func testReclickingSelectedColorRecolorsStamp() {
        let e = makeEngine()
        e.setTool(.stamp)
        e.options.stampKind = .check
        click(e, IPoint(50, 50))
        // スタンプを選ぶとツールバーはスタンプの色になる。赤をもう一度押すと赤に
        e.skitchColor = Annotation.skitchRed
        XCTAssertEqual(e.annotations[0].color, Annotation.skitchRed)
    }

    func testWholeImageTransformBakesPartsInOneUndo() {
        let e = makeEngine(100, 50)
        e.setTool(.stamp)
        click(e, IPoint(20, 20))
        e.rotateClockwise()
        XCTAssertTrue(e.annotations.isEmpty)
        XCTAssertEqual(e.canvas.size, ISize(50, 100))
        XCTAssertEqual(e.canvas[50 - 1 - 20, 20], StampKind.cross.defaultColor, "部品ごと回る")
        e.undo()
        XCTAssertEqual(e.annotations.count, 1, "1 回の元に戻すで部品も戻る")
        XCTAssertEqual(e.canvas.size, ISize(100, 50))
    }

    func testBakeAnnotations() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        e.bakeAnnotations()
        XCTAssertTrue(e.annotations.isEmpty)
        XCTAssertEqual(e.canvas[50, 50], StampKind.cross.defaultColor)
        e.undo()
        XCTAssertEqual(e.annotations.count, 1)
        XCTAssertEqual(e.canvas[50, 50], Colors.white)
    }

    func testCropKeepsPartsEditableAndShifted() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(100, 100))
        e.setTool(.select)
        drag(e, IPoint(50, 50), IPoint(149, 149))
        e.cropToSelection()
        XCTAssertEqual(e.canvas.size, ISize(100, 100))
        XCTAssertEqual(e.annotations[0].shape, .stamp(.cross, center: IPoint(50, 50), radius: Annotation.defaultStampRadius))
    }

    func testClearImageRemovesPartsUndoably() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        e.clearImage()
        XCTAssertTrue(e.annotations.isEmpty)
        e.undo()
        XCTAssertEqual(e.annotations.count, 1)
    }

    func testPartsMarkModifiedAndCountAsNotPristine() {
        let e = makeEngine()
        e.load(Bitmap(width: 100, height: 100))
        XCTAssertFalse(e.isModified)
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        XCTAssertTrue(e.isModified)
        e.markSaved()
        e.setTool(.pencil)
        XCTAssertFalse(e.isModified, "選択を外すだけでは変更なし")
        let f = PaintEngine(width: 100, height: 80)
        f.annotationRenderer = fakeRenderer
        f.setTool(.stamp)
        click(f, IPoint(10, 10))
        f.paste(Bitmap(width: 10, height: 10, fill: Colors.black))
        XCTAssertEqual(f.canvas.size, ISize(100, 80), "部品があればまっさら扱いではない")
    }

    func testArrowHitTestFollowsShape() {
        let a = Annotation(shape: .arrow(tail: IPoint(0, 50), head: IPoint(200, 50)), color: Annotation.skitchRed, thickness: 2)
        XCTAssertEqual(a.part(at: CanvasPoint(100.5, 50.5), tolerance: 5), .body)
        XCTAssertNil(a.part(at: CanvasPoint(100.5, 64.5), tolerance: 5))
        XCTAssertNil(a.part(at: CanvasPoint(230.5, 50.5), tolerance: 5))
        XCTAssertEqual(a.part(at: CanvasPoint(190.5, 58.5), tolerance: 5), .body)
    }

    func testThickBoxRimIsGrabbableWhenZoomed() {
        let e = makeEngine()
        e.zoom = 8
        e.options.skitchThickness = 3
        e.setTool(.skitchBox)
        drag(e, IPoint(20, 20), IPoint(120, 120))
        XCTAssertEqual(e.annotationPart(at: CanvasPoint(27.5, 60.5)), .body)
        XCTAssertNil(e.annotationPart(at: CanvasPoint(10.5, 60.5)))
    }

    func testHistorySharesUnchangedCanvas() {
        var h = History(maxCount: 100, maxBytes: 10 * 1024 * 1024)
        let big = Bitmap(width: 1000, height: 1000)
        for i in 0..<20 {
            h.push(DocState(canvas: big, annotations: [Annotation(shape: .stamp(.cross, center: IPoint(i, i), radius: 5),
                                                                   color: 0, thickness: 0)]))
        }
        XCTAssertEqual(h.undoStack.count, 20, "同じ絵を共有していればメモリを 1 枚分しか数えない")
        XCTAssertFalse(h.droppedOldest)
    }

    func testTextToolOnlyGrabsTextParts() {
        let e = makeEngine()
        e.setTool(.skitchBox)
        drag(e, IPoint(20, 20), IPoint(150, 120))
        e.deselectAnnotation()
        e.setTool(.skitchText)
        // 四角の枠線の上をクリックしても、四角はつかまずに文字の枠ができる
        click(e, IPoint(22, 60))
        XCTAssertNotNil(e.textBox)
        XCTAssertEqual(e.annotations[0].shape, .box(IRect(x: 20, y: 20, width: 131, height: 101)), "四角は動かない")
        XCTAssertNil(e.selectedAnnotation)
    }

    // MARK: 3 回目のレビュー指摘

    func testCutTakesPaintOnlyAndCopyIsWysiwyg() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        e.deselectAnnotation()
        e.setTool(.select)
        drag(e, IPoint(20, 20), IPoint(80, 80))
        XCTAssertEqual(e.copyImage()[30, 30], StampKind.cross.defaultColor, "コピーは見えているとおり")
        let cut = e.cut()
        XCTAssertEqual(cut?[30, 30], Colors.white, "切り取りはペイントの絵だけ（部品は残るので入れない）")
        XCTAssertEqual(e.annotations.count, 1)
    }

    func testHeldArrowKeyNudgesCoalesceIntoOneUndo() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        for _ in 0..<100 { e.nudgeAnnotation(dx: 1, dy: 0) }
        XCTAssertEqual(e.annotations[0].shape, .stamp(.cross, center: IPoint(150, 50), radius: Annotation.defaultStampRadius))
        e.undo()
        XCTAssertEqual(e.annotations[0].shape, .stamp(.cross, center: IPoint(50, 50), radius: Annotation.defaultStampRadius),
                       "押し続けた分は 1 回で戻る")
        e.undo()
        XCTAssertTrue(e.annotations.isEmpty)
    }

    func testUndoDuringDragCancelsCleanly() {
        let e = makeEngine()
        e.setTool(.arrow)
        drag(e, IPoint(10, 10), IPoint(80, 10))
        e.mouseDown(at: cp(10, 100), button: .primary)
        e.mouseDragged(to: cp(80, 100))
        e.undo()   // ドラッグ中に ⌘Z
        e.mouseDragged(to: cp(90, 120))
        e.mouseUp(at: cp(90, 120))
        XCTAssertTrue(e.annotations.isEmpty, "引きかけの矢印は取り消され、1 本目も元に戻る")
        e.redo()
        XCTAssertEqual(e.annotations.count, 1)
    }

    func testToolSwitchDuringDragRecordsThePart() {
        let e = makeEngine()
        e.load(Bitmap(width: 200, height: 200))
        e.setTool(.arrow)
        e.mouseDown(at: cp(10, 100), button: .primary)
        e.mouseDragged(to: cp(80, 100))
        e.setTool(.pencil)
        XCTAssertEqual(e.annotations.count, 1)
        XCTAssertTrue(e.isModified)
        XCTAssertTrue(e.canUndo)
    }

    func testPickerPicksVisiblePartColor() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(50, 50))
        e.setTool(.picker)
        click(e, IPoint(50, 50))
        XCTAssertEqual(e.primary, StampKind.cross.defaultColor)
    }

    func testShortTextGrabAreaIsTextWidth() {
        let e = makeEngine()
        e.setTool(.skitchText)
        click(e, IPoint(20, 20))
        e.commitSkitchText("OK", measured: ISize(30, 30))
        guard case .text(_, let f, _) = e.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(f.width, 32)
        e.setTool(.arrow)
        XCTAssertNil(e.annotationPart(at: cp(120, 30)), "文字の右の空いた所はつかまない")
        // 打ち直すときは広めの枠で打てる
        click(e, IPoint(25, 25))
        e.mouseDown(at: cp(25, 25), button: .primary, clickCount: 2)
        e.mouseUp(at: cp(25, 25))
        XCTAssertEqual(e.textBox?.width, min(e.defaultTextBoxSize.width, 200 - 20), "キャンバスに収まる範囲で広めに")
        XCTAssertNil(e.annotationPart(at: cp(25, 25)), "入力中は部品をつかまない")
    }

    func testCropDropsPartsOutside() {
        let e = makeEngine()
        e.setTool(.stamp)
        click(e, IPoint(30, 30))
        e.deselectAnnotation()
        click(e, IPoint(170, 170))
        e.deselectAnnotation()
        e.setTool(.select)
        drag(e, IPoint(0, 0), IPoint(79, 79))
        e.cropToSelection()
        XCTAssertEqual(e.annotations.count, 1, "外に出た部品は消える")
        e.resizeCanvas(to: ISize(200, 200))
        XCTAssertEqual(e.annotations.count, 1, "広げても復活しない")
        e.undo()
        e.undo()
        XCTAssertEqual(e.annotations.count, 2, "元に戻すと戻る")
    }
}

