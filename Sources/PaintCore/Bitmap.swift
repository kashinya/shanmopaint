/// 行優先で並んだ 0xAARRGGBB ピクセルの画像。値型（コピーオンライト）。
public struct Bitmap: Equatable {
    public private(set) var width: Int
    public private(set) var height: Int
    public var pixels: [Pixel]

    public init(width: Int, height: Int, fill: Pixel = Colors.white) {
        precondition(width > 0 && height > 0, "Bitmap size must be positive")
        self.width = width
        self.height = height
        self.pixels = Array(repeating: fill, count: width * height)
    }

    public init(width: Int, height: Int, pixels: [Pixel]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var size: ISize { ISize(width, height) }
    public var bounds: IRect { IRect(x: 0, y: 0, width: width, height: height) }

    @inline(__always)
    public func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    public subscript(x: Int, y: Int) -> Pixel {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    public func pixel(_ x: Int, _ y: Int) -> Pixel? {
        contains(x, y) ? pixels[y * width + x] : nil
    }

    /// 範囲外は無視して 1 ピクセル置く。
    @inline(__always)
    public mutating func plot(_ x: Int, _ y: Int, _ c: Pixel) {
        if contains(x, y) { pixels[y * width + x] = c }
    }

    /// y 行の [x0, x1) を塗る（範囲外は切り捨て）。
    public mutating func hspan(y: Int, from x0: Int, to x1: Int, _ c: Pixel) {
        guard y >= 0, y < height else { return }
        let a = max(0, x0), b = min(width, x1)
        guard b > a else { return }
        let w = width
        pixels.withUnsafeMutableBufferPointer { p in
            let row = y * w
            for x in a..<b { p[row + x] = c }
        }
    }

    public mutating func fill(_ r: IRect, with c: Pixel) {
        let r = r.intersection(bounds)
        guard !r.isEmpty else { return }
        for y in r.minY..<r.maxY { hspan(y: y, from: r.minX, to: r.maxX, c) }
    }

    /// r の範囲を切り出す。キャンバス外の部分は outside で埋める。
    public func cropped(to r: IRect, outside: Pixel = Colors.white) -> Bitmap {
        precondition(!r.isEmpty)
        var out = Bitmap(width: r.width, height: r.height, fill: outside)
        let inter = r.intersection(bounds)
        guard !inter.isEmpty else { return out }
        let w = width, ow = out.width
        pixels.withUnsafeBufferPointer { src in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                for y in inter.minY..<inter.maxY {
                    let s = y * w, d = (y - r.y) * ow - r.x
                    for x in inter.minX..<inter.maxX { dst[d + x] = src[s + x] }
                }
            }
        }
        return out
    }

    /// src を p の位置に描く。transparentKey と同じ色のピクセルは描かない（Win98 の「透明」選択）。
    /// mask を渡すと true の画素だけ描く（自由選択）。
    public mutating func draw(_ src: Bitmap, at p: IPoint, transparentKey: Pixel? = nil, mask: [Bool]? = nil) {
        let target = IRect(origin: p, size: src.size).intersection(bounds)
        guard !target.isEmpty else { return }
        let w = width, sw = src.width
        let key = transparentKey.map { $0 | 0xFF00_0000 }
        src.pixels.withUnsafeBufferPointer { s in
            pixels.withUnsafeMutableBufferPointer { d in
                for y in target.minY..<target.maxY {
                    let srow = (y - p.y) * sw - p.x, drow = y * w
                    if let mask = mask {
                        for x in target.minX..<target.maxX where mask[srow + x] {
                            let c = s[srow + x]
                            if let key = key, c | 0xFF00_0000 == key { continue }
                            d[drow + x] = c
                        }
                    } else if let key = key {
                        for x in target.minX..<target.maxX {
                            let c = s[srow + x]
                            if c | 0xFF00_0000 != key { d[drow + x] = c }
                        }
                    } else {
                        for x in target.minX..<target.maxX { d[drow + x] = s[srow + x] }
                    }
                }
            }
        }
    }

    /// 乗算済みアルファの src を合成する（テキスト用）。
    public mutating func drawPremultiplied(_ src: Bitmap, at p: IPoint) {
        let target = IRect(origin: p, size: src.size).intersection(bounds)
        guard !target.isEmpty else { return }
        let w = width, sw = src.width
        src.pixels.withUnsafeBufferPointer { s in
            pixels.withUnsafeMutableBufferPointer { d in
                for y in target.minY..<target.maxY {
                    let srow = (y - p.y) * sw - p.x, drow = y * w
                    for x in target.minX..<target.maxX {
                        d[drow + x] = Colors.blendPremultiplied(s[srow + x], over: d[drow + x])
                    }
                }
            }
        }
    }

    /// キャンバスのサイズ変更（左上基準）。増えた部分は fill で埋める。
    public func resizingCanvas(to s: ISize, fill: Pixel) -> Bitmap {
        var out = Bitmap(width: s.width, height: s.height, fill: fill)
        out.draw(self, at: IPoint(0, 0))
        return out
    }

    /// 最近傍法で拡大・縮小。
    public func scaled(to s: ISize) -> Bitmap {
        if s == size { return self }
        var out = Bitmap(width: s.width, height: s.height)
        let w = width, h = height, ow = s.width, oh = s.height
        var xmap = [Int](repeating: 0, count: ow)
        for x in 0..<ow { xmap[x] = min(w - 1, x * w / ow) }
        pixels.withUnsafeBufferPointer { src in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<oh {
                    let sy = min(h - 1, y * h / oh)
                    let srow = sy * w, drow = y * ow
                    for x in 0..<ow { dst[drow + x] = src[srow + xmap[x]] }
                }
            }
        }
        return out
    }

    public func flippedHorizontally() -> Bitmap {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out[x, y] = self[width - 1 - x, y] }
        }
        return out
    }

    public func flippedVertically() -> Bitmap {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out[x, y] = self[x, height - 1 - y] }
        }
        return out
    }

    public func rotated180() -> Bitmap {
        Bitmap(width: width, height: height, pixels: pixels.reversed())
    }

    /// 時計回りに 90 度。
    public func rotatedClockwise() -> Bitmap {
        var out = Bitmap(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width { out[height - 1 - y, x] = self[x, y] }
        }
        return out
    }

    /// 反時計回りに 90 度。
    public func rotatedCounterClockwise() -> Bitmap {
        var out = Bitmap(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width { out[y, width - 1 - x] = self[x, y] }
        }
        return out
    }

    public mutating func invertColors() {
        pixels.withUnsafeMutableBufferPointer { p in
            for i in p.indices { p[i] = Colors.inverted(p[i]) }
        }
    }

    /// r の中で from 色のピクセルだけ to 色に置き換える（消しゴムの右ドラッグ）。
    public mutating func replace(_ from: Pixel, with to: Pixel, in r: IRect) {
        let r = r.intersection(bounds)
        guard !r.isEmpty else { return }
        let w = width
        pixels.withUnsafeMutableBufferPointer { p in
            for y in r.minY..<r.maxY {
                for x in r.minX..<r.maxX where p[y * w + x] == from { p[y * w + x] = to }
            }
        }
    }

    /// 不透明にする（読み込んだ画像の半透明を背景色で潰したあと等の保険）。
    public mutating func makeOpaque() {
        pixels.withUnsafeMutableBufferPointer { p in
            for i in p.indices { p[i] |= 0xFF00_0000 }
        }
    }
}
