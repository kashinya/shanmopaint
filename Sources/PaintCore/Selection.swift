/// 浮いている選択範囲（範囲選択・貼り付けた画像）。
public struct FloatingSelection: Equatable {
    /// 元の画素。
    public var image: Bitmap
    /// キャンバス上の位置と表示サイズ（伸縮中は image と大きさが違う）。
    public var frame: IRect
    /// true: 画素はキャンバスから切り離されている（移動済み・貼り付け）。
    /// false: まだ選んだだけで、画素はキャンバス上にそのまま残っている。
    public var lifted: Bool
    /// この選択の操作のために、元に戻す履歴をもう 1 つ積んだかどうか。
    public var recorded: Bool
    /// 自由選択の形（image と同じ大きさ。true の画素だけが選択対象）。四角い選択なら nil。
    public var mask: [Bool]?

    public init(image: Bitmap, frame: IRect, lifted: Bool, recorded: Bool, mask: [Bool]? = nil) {
        precondition(mask == nil || mask!.count == image.pixels.count)
        self.image = image
        self.frame = frame
        self.lifted = lifted
        self.recorded = recorded
        self.mask = mask
    }

    /// frame の大きさに合わせた画像。
    public var rendered: Bitmap { image.scaled(to: frame.size) }

    /// frame の大きさに合わせたマスク。
    public var renderedMask: [Bool]? {
        guard let mask = mask else { return nil }
        return Self.scaleMask(mask, from: image.size, to: frame.size)
    }

    public static func scaleMask(_ mask: [Bool], from: ISize, to: ISize) -> [Bool] {
        if from == to { return mask }
        var out = [Bool](repeating: false, count: to.width * to.height)
        for y in 0..<to.height {
            let sy = min(from.height - 1, y * from.height / to.height)
            for x in 0..<to.width {
                let sx = min(from.width - 1, x * from.width / to.width)
                out[y * to.width + x] = mask[sy * from.width + sx]
            }
        }
        return out
    }
}

public enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// 枠 f に対するハンドル中心（キャンバス座標）。
    public func position(in f: IRect) -> CanvasPoint {
        let l = Double(f.minX), r = Double(f.maxX), t = Double(f.minY), b = Double(f.maxY)
        let cx = (l + r) / 2, cy = (t + b) / 2
        switch self {
        case .topLeft: return CanvasPoint(l, t)
        case .top: return CanvasPoint(cx, t)
        case .topRight: return CanvasPoint(r, t)
        case .right: return CanvasPoint(r, cy)
        case .bottomRight: return CanvasPoint(r, b)
        case .bottom: return CanvasPoint(cx, b)
        case .bottomLeft: return CanvasPoint(l, b)
        case .left: return CanvasPoint(l, cy)
        }
    }

    /// ハンドルを (dx, dy) ピクセル動かしたあとの枠。最小 1×1。
    public func resize(_ f: IRect, dx: Int, dy: Int) -> IRect {
        var l = f.minX, r = f.maxX, t = f.minY, b = f.maxY
        switch self {
        case .topLeft: l += dx; t += dy
        case .top: t += dy
        case .topRight: r += dx; t += dy
        case .right: r += dx
        case .bottomRight: r += dx; b += dy
        case .bottom: b += dy
        case .bottomLeft: l += dx; b += dy
        case .left: l += dx
        }
        if r - l < 1 {
            if [.topLeft, .bottomLeft, .left].contains(self) { l = r - 1 } else { r = l + 1 }
        }
        if b - t < 1 {
            if [.topLeft, .top, .topRight].contains(self) { t = b - 1 } else { b = t + 1 }
        }
        return IRect(x: l, y: t, width: r - l, height: b - t)
    }
}

/// 貼り付け位置とキャンバスサイズの決め方。
public enum PastePlacement {
    /// - Parameters:
    ///   - image: 貼り付ける画像のサイズ
    ///   - canvas: 今のキャンバスのサイズ
    ///   - pristine: 新規作成から何も描いていない（サイズ変更もしていない）
    ///   - fitWhenPristine: まっさらなキャンバスなら画像とぴったり同じサイズにする
    ///   - visibleOrigin: 画面に見えている範囲の左上（キャンバス座標）
    /// - Returns: 貼り付け後のキャンバスサイズと、画像を置く左上の位置
    public static func plan(image: ISize, canvas: ISize, pristine: Bool, fitWhenPristine: Bool,
                            visibleOrigin: IPoint) -> (canvas: ISize, origin: IPoint) {
        if pristine && fitWhenPristine {
            return (image, IPoint(0, 0))
        }
        if image.width > canvas.width || image.height > canvas.height {
            // Win98 と同じく「ビットマップを拡大」して左上に置く
            return (ISize(max(canvas.width, image.width), max(canvas.height, image.height)), IPoint(0, 0))
        }
        // キャンバスの方が広い：見えている左上に置く（はみ出さないよう寄せる）
        let x = max(0, min(visibleOrigin.x, canvas.width - image.width))
        let y = max(0, min(visibleOrigin.y, canvas.height - image.height))
        return (canvas, IPoint(x, y))
    }

    /// 「位置を指定して貼り付け」の基準点。
    public enum Anchor: CaseIterable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    }

    /// 基準点とオフセットから左上座標を求める。
    public static func origin(anchor: Anchor, image: ISize, canvas: ISize, offset: IPoint = IPoint(0, 0)) -> IPoint {
        let freeX = canvas.width - image.width, freeY = canvas.height - image.height
        let x: Int, y: Int
        switch anchor {
        case .topLeft, .left, .bottomLeft: x = 0
        case .top, .center, .bottom: x = freeX / 2
        case .topRight, .right, .bottomRight: x = freeX
        }
        switch anchor {
        case .topLeft, .top, .topRight: y = 0
        case .left, .center, .right: y = freeY / 2
        case .bottomLeft, .bottom, .bottomRight: y = freeY
        }
        return IPoint(x + offset.x, y + offset.y)
    }
}
