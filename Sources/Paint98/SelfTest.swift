import AppKit
import PaintCore

/// `Paint98 --selftest <出力先>` で起動したときの自己テスト。
/// 本物のクリップボードとウインドウを使って、貼り付け・コピー・文字入れ・保存を一通り試し、
/// 画面のスナップショットと結果（report.txt）を書き出して終了する。
final class SelfTest {
    private let c: MainController
    private let dir: URL
    private var lines: [String] = []
    private var failures = 0
    private var engine: PaintEngine { c.engine }

    init(controller: MainController, outputDir: URL) {
        c = controller
        dir = outputDir
    }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        run(steps(), 0)
    }

    private func log(_ s: String) {
        lines.append(s)
        print(s)
        fflush(stdout)
    }

    private func check(_ ok: Bool, _ msg: String) {
        if ok { log("  ✓ \(msg)") } else { failures += 1; log("  ✗ \(msg)") }
    }

    private func snapshot(_ name: String) {
        guard let view = c.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
            log("  📷 \(name).png")
        }
    }

    private func run(_ steps: [(String, () -> Void)], _ i: Int) {
        guard i < steps.count else { finish(); return }
        let (name, body) = steps[i]
        log("▶ \(name)")
        body()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.run(steps, i + 1) }
    }

    private func finish() {
        log(failures == 0 ? "SELFTEST PASS" : "SELFTEST FAIL (\(failures))")
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }

    /// 向きと色がわかる試験画像。
    private static func testImage(_ w: Int, _ h: Int, seed: Int) -> Bitmap {
        var b = Bitmap(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                b[x, y] = Colors.rgb((x * 255) / max(1, w - 1), (y * 255) / max(1, h - 1), (seed * 60) % 256)
            }
        }
        b.fill(IRect(x: 0, y: 0, width: 8, height: 8), with: Colors.rgb(255, 0, 0))
        b.fill(IRect(x: w - 8, y: h - 8, width: 8, height: 8), with: Colors.black)
        return b
    }

    private func cp(_ x: Int, _ y: Int) -> CanvasPoint { CanvasPoint(IPoint(x, y)) }

    private func drag(_ a: IPoint, _ b: IPoint, button: MouseButton = .primary) {
        engine.mouseDown(at: cp(a.x, a.y), button: button)
        engine.mouseDragged(to: cp((a.x + b.x) / 2, (a.y + b.y) / 2))
        engine.mouseDragged(to: cp(b.x, b.y))
        engine.mouseUp(at: cp(b.x, b.y))
    }

    private func steps() -> [(String, () -> Void)] {
        let img = Self.testImage(320, 200, seed: 1)
        let small = Self.testImage(100, 80, seed: 2)
        let big = Self.testImage(900, 700, seed: 3)
        var beforeText = engine.canvas
        var textBox = IRect(x: 0, y: 0, width: 1, height: 1)

        return [
            ("起動直後", {
                self.check(self.engine.isPristine, "まっさらなキャンバス")
                self.check(self.engine.canvas.size == MainController.defaultCanvasSize, "既定サイズ \(self.engine.canvas.size)")
                self.snapshot("00-launch")
            }),
            ("クリップボードの読み書き", {
                Clipboard.write(img)
                self.check(Clipboard.hasImage, "クリップボードに画像がある")
                let back = Clipboard.readImage()
                self.check(back?.size == img.size, "読み戻しのサイズ \(back.map { "\($0.size)" } ?? "nil")")
                if let back = back {
                    var maxDiff = 0
                    for i in back.pixels.indices {
                        let a = back.pixels[i], b = img.pixels[i]
                        maxDiff = max(maxDiff, abs(Colors.red(a) - Colors.red(b)), abs(Colors.green(a) - Colors.green(b)), abs(Colors.blue(a) - Colors.blue(b)))
                    }
                    self.check(maxDiff == 0, "画素がそのまま戻る（最大差 \(maxDiff)）")
                }
            }),
            ("まっさらなキャンバスに貼り付け（⌘V）", {
                self.c.window.makeFirstResponder(self.c.canvasView)
                self.check(self.c.canvasView.validateMenuItem(NSMenuItem(title: "", action: #selector(NSText.paste(_:)), keyEquivalent: "")),
                           "キャンバスで貼り付けメニューが有効")
                self.c.canvasView.paste(nil)
                self.check(self.engine.canvas.size == img.size, "キャンバスが画像サイズになる \(self.engine.canvas.size)")
                self.check(self.engine.selection == nil, "浮かせずにそのまま描き込む（すぐ編集できる）")
                self.check(self.engine.tool == .pencil, "道具はそのまま")
                self.snapshot("01-paste-into-new-canvas")
            }),
            ("確定して画素を確認", {
                self.engine.commitSelection()
                self.check(self.engine.canvas == img, "貼った画像と完全一致")
            }),
            ("キャンバスより小さい画像を位置決めして貼り付け", {
                self.engine.resizeCanvas(to: ISize(640, 480))
                Clipboard.write(small)
                self.c.paste(nil)
                self.check(self.engine.canvas.size == ISize(640, 480), "キャンバスはそのまま")
                self.check(self.engine.selection?.frame.size == small.size, "浮いた選択範囲として置かれる")
                self.engine.moveSelection(to: IPoint(300, 200))
                self.engine.nudgeSelection(dx: 5, dy: 5)
                self.snapshot("02-floating-paste")
            }),
            ("位置を確定", {
                self.engine.commitSelection()
                self.check(self.engine.canvas[305, 205] == small[0, 0], "指定位置の左上")
                self.check(self.engine.canvas[404, 284] == small[99, 79], "指定位置の右下")
                self.check(self.engine.canvas[304, 204] == Colors.white, "外側は元のまま")
            }),
            ("大きい画像を貼るとキャンバスが広がる", {
                Clipboard.write(big)
                self.c.paste(nil)
                self.check(self.engine.canvas.size == ISize(900, 700), "キャンバス \(self.engine.canvas.size)")
                self.engine.commitSelection()
            }),
            ("範囲選択してコピー（⌘C）", {
                self.c.chooseTool(.select)
                self.drag(IPoint(10, 10), IPoint(59, 39))
                self.check(self.engine.selection?.frame == IRect(x: 10, y: 10, width: 50, height: 30), "選択範囲 \(String(describing: self.engine.selection?.frame))")
                self.c.copy(nil)
                let back = Clipboard.readImage()
                self.check(back == self.engine.canvas.cropped(to: IRect(x: 10, y: 10, width: 50, height: 30)), "選択範囲の画素がクリップボードに入る")
                self.snapshot("03-selection")
            }),
            ("切り取り（⌘X）", {
                self.c.cut(nil)
                self.check(self.engine.canvas[20, 20] == self.engine.secondary, "切り取った所は背景色")
                self.check(Clipboard.readImage()?.size == ISize(50, 30), "クリップボードに入る")
            }),
            ("位置を指定して貼り付け（はみ出す分は広げる）", {
                self.engine.paste(small, at: IPoint(850, 650), growCanvas: true)
                self.check(self.engine.canvas.size == ISize(950, 730), "キャンバス \(self.engine.canvas.size)")
                self.engine.commitSelection()
            }),
            ("新規画像として貼り付け（⌥⌘V）", {
                Clipboard.write(img)
                self.c.pasteAsNewImage(nil)
                self.check(self.engine.canvas == img, "画像そのものがキャンバスになる")
            }),
            ("文字入れ：枠を作って日本語を入力", {
                self.c.chooseTool(.text)
                self.drag(IPoint(20, 20), IPoint(300, 90))
                self.check(self.c.canvasView.textView != nil, "入力欄が出る")
                textBox = self.engine.textBox ?? textBox
                beforeText = self.engine.canvas
                self.c.canvasView.textView?.insertText("ペイント98 文字入れ ABC", replacementRange: NSRange(location: NSNotFound, length: 0))
                self.snapshot("04-text-editing")
            }),
            ("文字を確定", {
                self.c.commitText()
                self.check(self.engine.textBox == nil, "入力欄が消える")
                self.check(self.c.canvasView.textView == nil, "入力欄のビューも消える")
                var changed = 0, dark = 0
                for y in textBox.minY..<min(textBox.maxY, self.engine.canvas.height) {
                    for x in textBox.minX..<min(textBox.maxX, self.engine.canvas.width) {
                        let p = self.engine.canvas[x, y]
                        if p != beforeText[x, y] { changed += 1 }
                        if Colors.red(p) + Colors.green(p) + Colors.blue(p) < 200 { dark += 1 }
                    }
                }
                self.check(changed > 500, "枠の中が描き変わる（\(changed) 画素）")
                self.check(dark > 100, "文字の黒い画素がある（\(dark) 画素）")
                self.snapshot("05-text-committed")
            }),
            ("ギザギザ文字（なめらか オフ）", {
                var s = self.c.textStyle
                s.smooth = false
                s.size = 24
                self.c.textStyle = s
                self.drag(IPoint(20, 120), IPoint(300, 170))
                self.c.canvasView.textView?.insertText("Win98 ギザギザ", replacementRange: NSRange(location: NSNotFound, length: 0))
                let box = self.engine.textBox ?? textBox
                self.c.commitText()
                var others = 0
                for y in box.minY..<min(box.maxY, self.engine.canvas.height) {
                    for x in box.minX..<min(box.maxX, self.engine.canvas.width) {
                        let p = self.engine.canvas[x, y]
                        if p != self.engine.primary && p != self.engine.secondary { others += 1 }
                    }
                }
                self.check(others == 0, "描画色と背景色の 2 色だけ（中間色 \(others) 画素）")
                s.smooth = true
                s.size = 16
                self.c.textStyle = s
            }),
            ("文字入力中に ⌘V（クリップボードは画像）", {
                self.c.chooseTool(.text)
                self.drag(IPoint(20, 120), IPoint(200, 160))
                self.c.canvasView.textView?.insertText("確定される文字", replacementRange: NSRange(location: NSNotFound, length: 0))
                Clipboard.write(small)
                let tv = self.c.canvasView.textView as? PaintTextView
                self.check(tv != nil, "入力欄は PaintTextView")
                // ⌘I は斜体の切り替え（画像の色の反転にならない）
                let before = self.c.textStyle.italic
                let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                          windowNumber: self.c.window.windowNumber, context: nil, characters: "i",
                                          charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)
                if let ev = ev { _ = tv?.performKeyEquivalent(with: ev) }
                self.check(self.c.textStyle.italic != before, "入力中の ⌘I は斜体の切り替え")
                self.c.toggleTextStyle("i")
                self.check(tv?.validateMenuItem(NSMenuItem(title: "", action: #selector(NSText.paste(_:)), keyEquivalent: "")) == true,
                           "入力中でも画像の貼り付けメニューが有効")
                tv?.paste(nil)
                self.check(self.engine.textBox == nil, "入力中の文字は確定される")
                self.check(self.engine.selection?.frame.size == small.size, "画像が浮いた状態で貼られる")
                self.engine.commitSelection()
            }),
            ("全部の道具を一通り使う", {
                let tools: [Tool] = [.pencil, .brush, .airbrush, .eraser, .line, .rectangle, .ellipse, .roundedRectangle, .fill]
                for (i, t) in tools.enumerated() {
                    self.c.chooseTool(t)
                    self.engine.primary = Colors.win98Palette[(i * 3 + 16) % 28]
                    let y = 10 + i * 18
                    self.drag(IPoint(10, y), IPoint(150, y + 14))
                }
                self.c.chooseTool(.polygon)
                self.drag(IPoint(170, 10), IPoint(300, 10))
                self.engine.mouseDown(at: self.cp(300, 120), button: .primary)
                self.engine.mouseUp(at: self.cp(300, 120))
                self.engine.mouseDown(at: self.cp(300, 120), button: .primary, clickCount: 2)
                self.c.chooseTool(.curve)
                self.drag(IPoint(170, 150), IPoint(310, 150))
                self.drag(IPoint(220, 120), IPoint(220, 110))
                self.drag(IPoint(260, 190), IPoint(260, 195))
                self.c.chooseTool(.freeSelect)
                self.drag(IPoint(10, 10), IPoint(60, 60))
                self.engine.primary = Colors.black
                self.check(!self.engine.hasPendingShape, "描きかけが残っていない")
                self.snapshot("06-tools")
            }),
            ("拡大表示とグリッド", {
                self.c.setZoom(4, center: IPoint(40, 40))
                self.c.canvasView.showGrid = true
                self.snapshot("07-zoom-grid")
            }),
            ("保存して開き直す", {
                self.c.canvasView.showGrid = false
                self.c.setZoom(1, center: IPoint(0, 0))
                self.engine.commitSelection()
                let url = self.dir.appendingPathComponent("roundtrip.png")
                do {
                    try BitmapIO.save(self.engine.flattened(), to: url, format: .png)
                    let back = try BitmapIO.load(url)
                    self.check(back == self.engine.canvas, "PNG で保存して読み戻すと一致")
                    for f in [BitmapIO.Format.bmp, .jpeg, .gif, .tiff] {
                        let u = self.dir.appendingPathComponent("roundtrip.\(f.rawValue)")
                        try BitmapIO.save(self.engine.canvas, to: u, format: f)
                        self.check((try? BitmapIO.load(u))?.size == self.engine.canvas.size, "\(f.rawValue) で保存して開ける")
                    }
                } catch {
                    self.check(false, "保存・読み込みでエラー: \(error)")
                }
            }),
            ("Skitch 風の矢印", {
                self.c.setZoom(1, center: IPoint(0, 0))
                self.engine.load(Bitmap(width: 500, height: 320, fill: Colors.white))
                self.c.chooseTool(.arrow)
                self.engine.primary = Colors.rgb(236, 64, 122)
                self.drag(IPoint(60, 60), IPoint(220, 140))
                self.check(self.engine.annotation != nil, "矢印が浮いた状態で置かれる")
                // 先端をつまんで直す
                self.drag(IPoint(220, 140), IPoint(230, 160))
                if case .arrow(_, let h)? = self.engine.annotation?.shape {
                    self.check(h == IPoint(230, 160), "先端を動かせる \(h)")
                } else {
                    self.check(false, "矢印のまま")
                }
                self.snapshot("09-arrow-floating")
            }),
            ("矢印を確定", {
                // 何もない所をクリック → 確定（クリックだけなので次の矢印は置かれない）
                self.engine.mouseDown(at: self.cp(450, 300), button: .primary)
                self.engine.mouseUp(at: self.cp(450, 300))
                self.check(self.engine.annotation == nil, "確定した")
                let mid = self.engine.canvas[145, 110]
                self.check(Colors.red(mid) > 200 && Colors.green(mid) < 120, "軸の真ん中が矢印の色 \(Colors.hexString(mid))")
                var shadow = 0
                for y in 100..<175 {
                    for x in 130..<250 {
                        let p = self.engine.canvas[x, y]
                        if Colors.red(p) < 200 && Colors.red(p) == Colors.green(p) && Colors.green(p) == Colors.blue(p) { shadow += 1 }
                    }
                }
                self.check(shadow > 20, "影がある（\(shadow) 画素）")
            }),
            ("Skitch 風のスタンプ", {
                self.c.chooseTool(.stamp)
                self.engine.options.stampKind = .cross
                self.engine.mouseDown(at: self.cp(330, 90), button: .primary)
                self.engine.mouseDragged(to: self.cp(360, 90))
                self.engine.mouseUp(at: self.cp(360, 90))
                if case .stamp(let k, let c, let r)? = self.engine.annotation?.shape {
                    self.check(k == .cross && c == IPoint(330, 90) && r == 30, "ドラッグで大きさを決めて置ける (r=\(r))")
                } else {
                    self.check(false, "スタンプが置かれる")
                }
                self.engine.commitAnnotation() // 浮いているスタンプの種類を変えないよう先に確定
                self.engine.options.stampKind = .check
                self.engine.mouseDown(at: self.cp(430, 90), button: .primary)
                self.engine.mouseUp(at: self.cp(430, 90))
                self.engine.commitAnnotation()
                self.engine.options.stampKind = .question
                self.engine.mouseDown(at: self.cp(330, 200), button: .primary)
                self.engine.mouseUp(at: self.cp(330, 200))
                self.engine.commitAnnotation()
                self.engine.options.stampKind = .exclamation
                self.engine.mouseDown(at: self.cp(390, 200), button: .primary)
                self.engine.mouseUp(at: self.cp(390, 200))
                self.engine.commitAnnotation()
                self.engine.options.stampKind = .star
                self.engine.mouseDown(at: self.cp(450, 200), button: .primary)
                self.engine.mouseUp(at: self.cp(450, 200))
                self.engine.commitAnnotation()
                self.engine.options.stampKind = .heart
                self.engine.mouseDown(at: self.cp(450, 270), button: .primary)
                self.engine.mouseUp(at: self.cp(450, 270))
                self.c.chooseTool(.pencil)
                let ring = self.engine.canvas[330 + 27, 90]
                self.check(Colors.red(ring) > 180 && Colors.green(ring) < 110, "✕ の輪が赤 \(Colors.hexString(ring))")
                let inside = self.engine.canvas[330 + 16, 90]
                self.check(inside == Colors.white, "輪の内側は白 \(Colors.hexString(inside))")
                let center = self.engine.canvas[330, 90]
                self.check(Colors.red(center) > 180 && Colors.blue(center) < 110, "✕ の交点が赤 \(Colors.hexString(center))")
            }),
            ("Skitch 風の文字（ふち取り＋影）", {
                var s = self.c.textStyle
                s.outline = true
                s.bold = true
                s.size = 28
                self.c.textStyle = s
                self.engine.options.transparentBackground = true
                self.engine.primary = Colors.rgb(236, 64, 122)
                self.c.chooseTool(.text)
                self.drag(IPoint(40, 220), IPoint(290, 280))
                self.c.canvasView.textView?.insertText("文字入れ Skitch", replacementRange: NSRange(location: NSNotFound, length: 0))
                self.snapshot("10-skitch-text-editing")
                self.c.commitText()
                var pink = 0
                for y in 215..<290 {
                    for x in 35..<300 {
                        let p = self.engine.canvas[x, y]
                        if Colors.red(p) > 200 && Colors.green(p) < 120 && Colors.blue(p) > 90 { pink += 1 }
                    }
                }
                self.check(pink > 150, "文字の色の画素がある（\(pink) 画素）")
                s.outline = false
                s.bold = false
                s.size = 16
                self.c.textStyle = s
                self.engine.options.transparentBackground = false
                self.engine.primary = Colors.black
                self.c.chooseTool(.pencil)
                self.snapshot("11-skitch-all")
            }),
            ("元に戻すを連打", {
                for _ in 0..<60 { self.c.paintUndo(nil) }
                self.check(!self.engine.canUndo, "履歴の最初まで戻れる")
                self.c.paintRedo(nil)
                self.check(self.engine.canRedo || self.engine.canUndo, "やり直しできる")
                self.snapshot("08-after-undo")
            }),
        ]
    }
}
