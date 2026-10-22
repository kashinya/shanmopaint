public enum BrushShape: String, CaseIterable {
    case round, square, slash, backslash
}

public enum ShapeKind {
    case rectangle, ellipse, roundedRectangle
}

public enum FillStyle: CaseIterable {
    /// 輪郭のみ
    case outline
    /// 輪郭（描画色）＋ 塗りつぶし（もう一方の色）
    case outlineAndFill
    /// 塗りつぶしのみ（描画色）
    case fill
}

/// 小さな決定的乱数（エアブラシ用。テストで種を固定できる）。
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// アンチエイリアスなしのドット描画プリミティブ。
public enum Raster {
    /// ブレゼンハムの直線。両端を含む。
    public static func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ body: (Int, Int) -> Void) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            body(x, y)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /// 直径 d の円の各行の [開始, 終了)。
    static func circleMask(_ d: Int) -> [(Int, Int)] {
        let r = Double(d) / 2
        var rows: [(Int, Int)] = []
        for j in 0..<d {
            let dy = Double(j) + 0.5 - r
            let hw = max(0, r * r - dy * dy).squareRoot()
            rows.append((Int((r - hw).rounded()), Int((r + hw).rounded())))
        }
        return rows
    }

    /// (x, y) を中心にブラシの形を 1 回押す。
    public static func stamp(_ bmp: inout Bitmap, x: Int, y: Int, size: Int, shape: BrushShape, color: Pixel) {
        let d = max(1, size)
        let o = d / 2
        switch shape {
        case .square:
            bmp.fill(IRect(x: x - o, y: y - o, width: d, height: d), with: color)
        case .round:
            if d < 3 {
                bmp.fill(IRect(x: x - o, y: y - o, width: d, height: d), with: color)
                return
            }
            let m = circleMask(d)
            for j in 0..<d {
                let (a, b) = m[j]
                if b > a { bmp.hspan(y: y - o + j, from: x - o + a, to: x - o + b, color) }
            }
        case .slash:
            for i in 0..<d { bmp.plot(x - o + i, y + o - i, color) }
        case .backslash:
            for i in 0..<d { bmp.plot(x - o + i, y - o + i, color) }
        }
    }

    public static func strokeLine(_ bmp: inout Bitmap, from a: IPoint, to b: IPoint, size: Int, shape: BrushShape, color: Pixel) {
        if size <= 1 {
            line(a.x, a.y, b.x, b.y) { x, y in bmp.plot(x, y, color) }
            return
        }
        line(a.x, a.y, b.x, b.y) { x, y in stamp(&bmp, x: x, y: y, size: size, shape: shape, color: color) }
    }

    /// 図形の各行の塗り範囲 [開始, 終了) を返す関数。rect が空なら nil。
    public static func spans(_ kind: ShapeKind, _ rect: IRect, radius: Double) -> ((Int) -> (Int, Int)?)? {
        guard !rect.isEmpty else { return nil }
        let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
        switch kind {
        case .rectangle:
            return { y in (y >= y0 && y < y1) ? (x0, x1) : nil }
        case .ellipse:
            let a = Double(rect.width) / 2, b = Double(rect.height) / 2
            let cx = Double(x0) + a, cy = Double(y0) + b
            return { y in
                let dy = (Double(y) + 0.5 - cy) / b
                if abs(dy) > 1 { return nil }
                let hw = a * max(0, 1 - dy * dy).squareRoot()
                let s = Int((cx - hw).rounded()), e = Int((cx + hw).rounded())
                return e > s ? (s, e) : nil
            }
        case .roundedRectangle:
            let r = min(radius, Double(rect.width) / 2, Double(rect.height) / 2)
            return { y in
                if y < y0 || y >= y1 { return nil }
                let yy = Double(y) + 0.5
                var dy = 0.0
                if yy < Double(y0) + r { dy = Double(y0) + r - yy } else if yy > Double(y1) - r { dy = yy - (Double(y1) - r) }
                let inset = r - max(0, r * r - dy * dy).squareRoot()
                let s = Int((Double(x0) + inset).rounded()), e = Int((Double(x1) - inset).rounded())
                return e > s ? (s, e) : nil
            }
        }
    }

    public static let roundedRadius = 10.0

    /// 四角形・楕円・角丸四角形を描く。
    public static func drawShape(_ bmp: inout Bitmap, _ kind: ShapeKind, in rect: IRect, style: FillStyle,
                                 lineWidth: Int, outline: Pixel, fill: Pixel) {
        guard let outer = spans(kind, rect, radius: roundedRadius) else { return }
        let lw = max(1, lineWidth)
        let inner = spans(kind, rect.insetBy(lw), radius: max(0, roundedRadius - Double(lw)))
        for y in rect.minY..<rect.maxY {
            guard let o = outer(y) else { continue }
            if style == .fill {
                bmp.hspan(y: y, from: o.0, to: o.1, outline)
                continue
            }
            let i = inner?(y)
            if style == .outlineAndFill, let i = i {
                bmp.hspan(y: y, from: i.0, to: i.1, fill)
            }
            if let i = i {
                bmp.hspan(y: y, from: o.0, to: i.0, outline)
                bmp.hspan(y: y, from: i.1, to: o.1, outline)
            } else {
                bmp.hspan(y: y, from: o.0, to: o.1, outline)
            }
        }
    }

    /// 多角形を偶奇規則で塗る。頂点はピクセル中心として扱う。
    public static func fillPolygon(_ bmp: inout Bitmap, _ pts: [IPoint], color: Pixel) {
        guard pts.count >= 3 else { return }
        let minY = max(0, pts.map(\.y).min()!), maxY = min(bmp.height - 1, pts.map(\.y).max()!)
        guard minY <= maxY else { return }
        var xs: [Double] = []
        for y in minY...maxY {
            let yc = Double(y) + 0.5
            xs.removeAll(keepingCapacity: true)
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                let ay = Double(a.y) + 0.5, by = Double(b.y) + 0.5
                if (ay <= yc && yc < by) || (by <= yc && yc < ay) {
                    let t = (yc - ay) / (by - ay)
                    xs.append(Double(a.x) + 0.5 + t * Double(b.x - a.x))
                }
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let s = Int((xs[k] - 0.5).rounded(.up)), e = Int((xs[k + 1] - 0.5).rounded(.up))
                bmp.hspan(y: y, from: s, to: e, color)
                k += 2
            }
        }
    }

    /// 3 次ベジェ曲線上の点列（連続する重複は除く）。
    public static func cubicBezier(_ p0: IPoint, _ c1: IPoint, _ c2: IPoint, _ p3: IPoint) -> [IPoint] {
        func dist(_ a: IPoint, _ b: IPoint) -> Double {
            let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
            return (dx * dx + dy * dy).squareRoot()
        }
        let approx = dist(p0, c1) + dist(c1, c2) + dist(c2, p3)
        let n = max(8, Int(approx))
        var out: [IPoint] = [p0]
        for i in 1...n {
            let t = Double(i) / Double(n), u = 1 - t
            let b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
            let x = b0 * Double(p0.x) + b1 * Double(c1.x) + b2 * Double(c2.x) + b3 * Double(p3.x)
            let y = b0 * Double(p0.y) + b1 * Double(c1.y) + b2 * Double(c2.y) + b3 * Double(p3.y)
            let p = IPoint(Int(x.rounded()), Int(y.rounded()))
            if p != out.last! { out.append(p) }
        }
        return out
    }

    /// 点列を折れ線で描く。
    public static func polyline(_ bmp: inout Bitmap, _ pts: [IPoint], closed: Bool, width: Int, color: Pixel) {
        guard let first = pts.first else { return }
        if pts.count == 1 {
            stamp(&bmp, x: first.x, y: first.y, size: width, shape: .square, color: color)
            return
        }
        for i in 0..<(pts.count - 1) {
            strokeLine(&bmp, from: pts[i], to: pts[i + 1], size: width, shape: .square, color: color)
        }
        if closed { strokeLine(&bmp, from: pts[pts.count - 1], to: first, size: width, shape: .square, color: color) }
    }

    /// 塗りつぶし（4 近傍・完全一致）。変化した範囲を返す。何も変わらなければ nil。
    @discardableResult
    public static func floodFill(_ bmp: inout Bitmap, x: Int, y: Int, color: Pixel) -> IRect? {
        guard bmp.contains(x, y) else { return nil }
        let w = bmp.width, h = bmp.height
        let target = bmp[x, y]
        if target == color { return nil }
        var minX = x, maxX = x, minY = y, maxY = y
        bmp.pixels.withUnsafeMutableBufferPointer { d in
            var stack: [(Int, Int)] = [(x, y)]
            while let (sx, sy) = stack.popLast() {
                let row = sy * w
                if d[row + sx] != target { continue }
                var l = sx
                while l > 0 && d[row + l - 1] == target { l -= 1 }
                var up = false, down = false
                var cx = l
                while cx < w && d[row + cx] == target {
                    d[row + cx] = color
                    if sy > 0 {
                        let t = d[row - w + cx] == target
                        if t && !up { stack.append((cx, sy - 1)); up = true } else if !t { up = false }
                    }
                    if sy < h - 1 {
                        let t = d[row + w + cx] == target
                        if t && !down { stack.append((cx, sy + 1)); down = true } else if !t { down = false }
                    }
                    cx += 1
                }
                minX = min(minX, l); maxX = max(maxX, cx - 1)
                minY = min(minY, sy); maxY = max(maxY, sy)
            }
        }
        return IRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// エアブラシ：半径 radius の円内にランダムな点を count 個。
    public static func spray<R: RandomNumberGenerator>(_ bmp: inout Bitmap, center: IPoint, radius: Int, count: Int,
                                                      color: Pixel, rng: inout R) {
        let r = max(1, radius)
        var placed = 0, tries = 0
        while placed < count && tries < count * 4 {
            tries += 1
            let dx = Int.random(in: -r...r, using: &rng), dy = Int.random(in: -r...r, using: &rng)
            if dx * dx + dy * dy > r * r { continue }
            bmp.plot(center.x + dx, center.y + dy, color)
            placed += 1
        }
    }

    /// Shift 押下時：水平・垂直・45 度に寄せる。
    public static func constrainLine(from a: IPoint, to b: IPoint) -> IPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let ax = abs(dx), ay = abs(dy)
        if ax > 2 * ay { return IPoint(b.x, a.y) }
        if ay > 2 * ax { return IPoint(a.x, b.y) }
        let d = max(ax, ay)
        return IPoint(a.x + (dx < 0 ? -d : d), a.y + (dy < 0 ? -d : d))
    }

    /// Shift 押下時：正方形・正円に寄せる。
    public static func constrainSquare(from a: IPoint, to b: IPoint) -> IPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = max(abs(dx), abs(dy))
        return IPoint(a.x + (dx < 0 ? -d : d), a.y + (dy < 0 ? -d : d))
    }
}
