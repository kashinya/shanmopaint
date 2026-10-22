/// Skitch 風の注釈（矢印・スタンプ）。置いた直後は浮いていて、つまんで直せる。確定するとキャンバスに焼き込む。
public struct Annotation: Equatable {
    public enum Shape: Equatable {
        case arrow(tail: IPoint, head: IPoint)
        case stamp(StampKind, center: IPoint, radius: Int)
    }

    public var shape: Shape
    public var color: Pixel
    /// 矢印の太さ（1〜3）。
    public var thickness: Int

    public init(shape: Shape, color: Pixel, thickness: Int) {
        self.shape = shape
        self.color = color
        self.thickness = thickness
    }

    /// 矢印の軸の太さ（ピクセル）。頭はこの約 3 倍の幅になる。
    public static func arrowWidth(_ thickness: Int) -> Double {
        switch thickness {
        case ...1: return 5
        case 2: return 8
        default: return 12
        }
    }

    public static let defaultStampRadius = 22
    public static let minStampRadius = 8
    /// これより短い矢印は置かない（クリックしただけ・ほとんど動かさなかったとき）。
    public static let minArrowLength = 10.0

    /// 矢印の形の寸法。描画と当たり判定で同じものを使う。
    public struct ArrowGeometry {
        /// 軸の太さ（短い矢印では細くする）
        public var width: Double
        public var headLength: Double
        public var headHalfWidth: Double
        public var tailHalfWidth: Double
        /// 白いふちの太さ
        public var outline: Double
    }

    public static func arrowGeometry(length: Double, thickness: Int) -> ArrowGeometry {
        let w = min(arrowWidth(thickness), max(1.5, length / 4))
        let headLen = min(w * 3.3, length * 0.65)
        let headHalf = max(w * 1.8, headLen * 0.58)
        return ArrowGeometry(width: w, headLength: headLen, headHalfWidth: headHalf,
                             tailHalfWidth: max(0.8, w * 0.16), outline: max(2, (w * 0.32).rounded()))
    }

    /// どこをつまんだか。
    public enum Part: Equatable {
        case tail, head, resize, body
    }

    /// つまむ点（キャンバス座標）。
    public var handles: [CanvasPoint] {
        switch shape {
        case .arrow(let t, let h):
            return [CanvasPoint(t), CanvasPoint(h)]
        case .stamp(_, let c, let r):
            let cx = Double(c.x) + 0.5, cy = Double(c.y) + 0.5, rr = Double(r)
            return [CanvasPoint(cx - rr, cy - rr), CanvasPoint(cx + rr, cy - rr),
                    CanvasPoint(cx + rr, cy + rr), CanvasPoint(cx - rr, cy + rr)]
        }
    }

    /// 点 p が注釈のどこに当たるか。tolerance はキャンバスのピクセル単位。
    public func part(at p: CanvasPoint, tolerance: Double) -> Part? {
        func dist(_ a: CanvasPoint, _ b: CanvasPoint) -> Double {
            let dx = a.x - b.x, dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }
        switch shape {
        case .arrow(let t, let h):
            let tp = CanvasPoint(t), hp = CanvasPoint(h)
            if dist(p, hp) <= tolerance + 2 { return .head }
            if dist(p, tp) <= tolerance + 2 { return .tail }
            // 実際の形（根元が細く、頭が太い）に沿った当たり判定
            let vx = hp.x - tp.x, vy = hp.y - tp.y
            let len = (vx * vx + vy * vy).squareRoot()
            guard len > 0 else { return nil }
            let along = ((p.x - tp.x) * vx + (p.y - tp.y) * vy) / len
            if along < -tolerance || along > len + tolerance { return nil }
            let a = max(0, min(len, along))
            let q = CanvasPoint(tp.x + vx * a / len, tp.y + vy * a / len)
            let g = Self.arrowGeometry(length: len, thickness: thickness)
            let half: Double
            if a >= len - g.headLength {
                half = g.headHalfWidth * (len - a) / max(1, g.headLength)
            } else {
                half = g.tailHalfWidth + (g.width / 2 - g.tailHalfWidth) * a / max(1, len - g.headLength)
            }
            if dist(p, q) <= half + g.outline + tolerance { return .body }
            return nil
        case .stamp(_, let c, let r):
            // 縮小表示でも本体をつかめるよう、角の当たり判定はスタンプの大きさに対して控えめにする
            let ht = min(tolerance, max(2, Double(r) * 0.35))
            for hp in handles where abs(p.x - hp.x) <= ht && abs(p.y - hp.y) <= ht { return .resize }
            if dist(p, CanvasPoint(c)) <= Double(r) + tolerance { return .body }
            return nil
        }
    }

    /// つまんだ部分を (dx, dy) 動かした結果。pointer は今のマウス位置（ピクセル）。
    public func adjusted(_ part: Part, dx: Int, dy: Int, pointer: IPoint, constrain: Bool) -> Annotation {
        var a = self
        switch shape {
        case .arrow(let t, let h):
            switch part {
            case .head:
                let nh = IPoint(h.x + dx, h.y + dy)
                a.shape = .arrow(tail: t, head: constrain ? Raster.constrainLine(from: t, to: nh) : nh)
            case .tail:
                let nt = IPoint(t.x + dx, t.y + dy)
                a.shape = .arrow(tail: constrain ? Raster.constrainLine(from: h, to: nt) : nt, head: h)
            case .body, .resize:
                a.shape = .arrow(tail: IPoint(t.x + dx, t.y + dy), head: IPoint(h.x + dx, h.y + dy))
            }
        case .stamp(let k, let c, let r):
            switch part {
            case .resize:
                let nr = max(abs(pointer.x - c.x), abs(pointer.y - c.y))
                a.shape = .stamp(k, center: c, radius: max(Self.minStampRadius, nr))
            default:
                a.shape = .stamp(k, center: IPoint(c.x + dx, c.y + dy), radius: r)
            }
        }
        return a
    }

    public func moved(dx: Int, dy: Int) -> Annotation {
        adjusted(.body, dx: dx, dy: dy, pointer: IPoint(0, 0), constrain: false)
    }

    /// 矢印の長さ（ピクセル）。スタンプは 0。
    public var arrowLength: Double {
        guard case .arrow(let t, let h) = shape else { return 0 }
        let dx = Double(h.x - t.x), dy = Double(h.y - t.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

public enum StampKind: String, CaseIterable {
    case cross, check, question, exclamation, star, heart

    /// スタンプごとの色（パレットをクリックすれば変えられる）。
    public var defaultColor: Pixel {
        switch self {
        case .cross: return Colors.rgb(226, 62, 51)
        case .check: return Colors.rgb(40, 165, 70)
        case .question: return Colors.rgb(35, 120, 215)
        case .exclamation: return Colors.rgb(240, 145, 20)
        case .star: return Colors.rgb(240, 180, 0)
        case .heart: return Colors.rgb(236, 64, 122)
        }
    }

    public var label: String {
        switch self {
        case .cross: return "✕"
        case .check: return "✓"
        case .question: return "?"
        case .exclamation: return "!"
        case .star: return "★"
        case .heart: return "♥"
        }
    }
}

/// UI が描いた注釈の画像（乗算済みアルファ）と、キャンバス上の左上位置。
public struct RenderedAnnotation {
    public var image: Bitmap
    public var origin: IPoint

    public init(image: Bitmap, origin: IPoint) {
        self.image = image
        self.origin = origin
    }
}
