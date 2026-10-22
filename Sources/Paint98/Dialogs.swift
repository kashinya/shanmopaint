import AppKit
import PaintCore

/// 数値入力などの小さなダイアログ（NSAlert + 付属ビュー）。
enum Dialogs {
    private static func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private static func number(_ v: Int) -> NSTextField {
        let f = NSTextField(string: "\(v)")
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return f
    }

    private static func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 8
        g.columnSpacing = 8
        g.column(at: 0).xPlacement = .trailing
        return g
    }

    private static func fit(_ v: NSView) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        let size = v.fittingSize
        let box = NSView(frame: NSRect(origin: .zero, size: NSSize(width: max(size.width, 260), height: size.height)))
        box.addSubview(v)
        v.frame = NSRect(origin: .zero, size: size)
        v.translatesAutoresizingMaskIntoConstraints = true
        return box
    }

    private static func parse(_ f: NSTextField, _ range: ClosedRange<Int>) -> Int? {
        // 日本語入力のまま打った全角数字・全角マイナスも受け付ける
        let half = f.stringValue.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? f.stringValue
        let t = half.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        guard let v = Int(t), range.contains(v) else { return nil }
        return v
    }

    static func error(_ message: String, info: String? = nil, window: NSWindow?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = message
        if let info = info { a.informativeText = info }
        a.runModal()
    }

    /// キャンバスのサイズ（Win98 の「属性」）。
    static func canvasSize(current: ISize) -> ISize? {
        let w = number(current.width), h = number(current.height)
        let a = NSAlert()
        a.messageText = "キャンバスのサイズ"
        a.informativeText = "単位はピクセルです（1〜10000）。広げた部分は背景色で塗られます。"
        a.accessoryView = fit(grid([[label("幅:"), w, NSTextField(labelWithString: "ピクセル")],
                                    [label("高さ:"), h, NSTextField(labelWithString: "ピクセル")]]))
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = w
        while a.runModal() == .alertFirstButtonReturn {
            if let wv = parse(w, 1...10000), let hv = parse(h, 1...10000) { return ISize(wv, hv) }
            NSSound.beep()
        }
        return nil
    }

    /// 伸縮（%）。
    static func stretch() -> (Int, Int)? {
        let x = number(100), y = number(100)
        let a = NSAlert()
        a.messageText = "伸縮"
        a.informativeText = "選択範囲があればその部分を、なければ画像全体を伸び縮みさせます（1〜500%）。"
        a.accessoryView = fit(grid([[label("水平方向:"), x, NSTextField(labelWithString: "%")],
                                    [label("垂直方向:"), y, NSTextField(labelWithString: "%")]]))
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = x
        while a.runModal() == .alertFirstButtonReturn {
            if let xv = parse(x, 1...500), let yv = parse(y, 1...500) { return (xv, yv) }
            NSSound.beep()
        }
        return nil
    }

    enum FlipRotate { case horizontal, vertical, rotate90, rotate180, rotate270 }

    /// 反転と回転。
    static func flipRotate() -> FlipRotate? {
        let choices: [(String, FlipRotate)] = [("左右反転", .horizontal), ("上下反転", .vertical),
                                               ("右に 90° 回転", .rotate90), ("180° 回転", .rotate180),
                                               ("左に 90° 回転（270°）", .rotate270)]
        let buttons = choices.map { NSButton(radioButtonWithTitle: $0.0, target: nil, action: nil) }
        let pick = RadioGroup(buttons)
        buttons[0].state = .on
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        let a = NSAlert()
        a.messageText = "反転と回転"
        a.informativeText = "選択範囲があればその部分を、なければ画像全体を変えます。"
        a.accessoryView = fit(stack)
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        // ボタンの target は弱参照なので、ダイアログを閉じるまで pick を生かしておく
        let ok = withExtendedLifetime(pick) { a.runModal() == .alertFirstButtonReturn }
        guard ok else { return nil }
        return choices[buttons.firstIndex { $0.state == .on } ?? 0].1
    }

    struct PastePosition {
        var origin: IPoint
        var growCanvas: Bool
    }

    /// 位置を指定して貼り付け。
    static func pastePosition(image: ISize, canvas: ISize, initial: IPoint) -> PastePosition? {
        let x = number(initial.x), y = number(initial.y)
        let grow = NSButton(checkboxWithTitle: "はみ出す分はキャンバスを広げる", target: nil, action: nil)
        grow.state = .on
        let anchors: [(String, PastePlacement.Anchor)] = [
            ("↖", .topLeft), ("↑", .top), ("↗", .topRight),
            ("←", .left), ("・", .center), ("→", .right),
            ("↙", .bottomLeft), ("↓", .bottom), ("↘", .bottomRight),
        ]
        let handler = AnchorHandler(image: image, canvas: canvas, x: x, y: y, grow: grow)
        let anchorButtons: [NSButton] = anchors.enumerated().map { i, a in
            let b = NSButton(title: a.0, target: handler, action: #selector(AnchorHandler.pick(_:)))
            b.tag = i
            b.bezelStyle = .regularSquare
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            b.toolTip = "この位置に合わせる"
            return b
        }
        handler.anchors = anchors.map(\.1)
        let anchorGrid = NSGridView(views: [Array(anchorButtons[0..<3]), Array(anchorButtons[3..<6]), Array(anchorButtons[6..<9])])
        anchorGrid.rowSpacing = 2
        anchorGrid.columnSpacing = 2
        let fields = grid([[label("X:"), x, NSTextField(labelWithString: "ピクセル")],
                           [label("Y:"), y, NSTextField(labelWithString: "ピクセル")]])
        let row = NSStackView(views: [anchorGrid, fields])
        row.orientation = .horizontal
        row.spacing = 16
        row.alignment = .centerY
        let col = NSStackView(views: [row, grow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 10

        let a = NSAlert()
        a.messageText = "位置を指定して貼り付け"
        a.informativeText = "貼り付ける画像: \(image.width)×\(image.height) ／ キャンバス: \(canvas.width)×\(canvas.height)\n左上の座標を指定するか、ボタンで位置を合わせてください。貼り付けたあともドラッグや矢印キーで動かせます。"
        a.accessoryView = fit(col)
        a.addButton(withTitle: "貼り付け")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = x
        return withExtendedLifetime(handler) { () -> PastePosition? in
            while a.runModal() == .alertFirstButtonReturn {
                if let xv = parse(x, -100_000...100_000), let yv = parse(y, -100_000...100_000) {
                    return PastePosition(origin: IPoint(xv, yv), growCanvas: grow.state == .on)
                }
                NSSound.beep()
            }
            return nil
        }
    }

    private final class AnchorHandler: NSObject {
        let image: ISize, canvas: ISize
        let x: NSTextField, y: NSTextField
        let grow: NSButton
        var anchors: [PastePlacement.Anchor] = []

        init(image: ISize, canvas: ISize, x: NSTextField, y: NSTextField, grow: NSButton) {
            self.image = image
            self.canvas = canvas
            self.x = x
            self.y = y
            self.grow = grow
        }

        @objc func pick(_ sender: NSButton) {
            // 画像の方が大きくてキャンバスを広げるなら、広げた後の大きさで位置を合わせる（左や上が切れないように）
            var c = canvas
            if grow.state == .on { c = ISize(max(c.width, image.width), max(c.height, image.height)) }
            let o = PastePlacement.origin(anchor: anchors[sender.tag], image: image, canvas: c)
            x.stringValue = "\(o.x)"
            y.stringValue = "\(o.y)"
        }
    }

    /// ラジオボタンを 1 つだけ選べるようにする。
    private final class RadioGroup: NSObject {
        let buttons: [NSButton]
        init(_ buttons: [NSButton]) {
            self.buttons = buttons
            super.init()
            for b in buttons {
                b.target = self
                b.action = #selector(select(_:))
            }
        }
        @objc func select(_ sender: NSButton) {
            for b in buttons { b.state = b === sender ? .on : .off }
        }
    }
}
