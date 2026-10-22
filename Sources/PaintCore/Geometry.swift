/// 整数座標の点（キャンバスのピクセル）。
public struct IPoint: Hashable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    public var description: String { "(\(x), \(y))" }
}

public struct ISize: Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    public var description: String { "\(width)×\(height)" }
}

/// 整数の矩形。maxX / maxY は含まない（半開区間）。
public struct IRect: Hashable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(origin: IPoint, size: ISize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// 2 つの角（どちらもピクセルとして含む）から矩形を作る。
    public static func spanning(_ a: IPoint, _ b: IPoint) -> IRect {
        IRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)
    }

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var origin: IPoint {
        get { IPoint(x, y) }
        set { x = newValue.x; y = newValue.y }
    }
    public var size: ISize {
        get { ISize(width, height) }
        set { width = newValue.width; height = newValue.height }
    }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ p: IPoint) -> Bool {
        p.x >= x && p.x < maxX && p.y >= y && p.y < maxY
    }

    public func intersection(_ o: IRect) -> IRect {
        let nx = max(x, o.x), ny = max(y, o.y)
        let nx2 = min(maxX, o.maxX), ny2 = min(maxY, o.maxY)
        if nx2 <= nx || ny2 <= ny { return IRect(x: nx, y: ny, width: 0, height: 0) }
        return IRect(x: nx, y: ny, width: nx2 - nx, height: ny2 - ny)
    }

    public func offsetBy(dx: Int, dy: Int) -> IRect {
        IRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func insetBy(_ d: Int) -> IRect {
        IRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }

    public var description: String { "[\(x), \(y), \(width)×\(height)]" }
}

/// マウス位置などの小数のキャンバス座標（1.0 = 1 ピクセル）。
public struct CanvasPoint: Hashable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(_ p: IPoint) { self.x = Double(p.x) + 0.5; self.y = Double(p.y) + 0.5 }
    /// このピクセルの整数座標。
    public var pixel: IPoint { IPoint(Int(x.rounded(.down)), Int(y.rounded(.down))) }
}
