/// 元に戻す 1 回分の状態：ペイントの絵と、その上に乗っている Skitch の部品。
public struct DocState: Equatable {
    public var canvas: Bitmap
    public var annotations: [Annotation]

    public init(canvas: Bitmap, annotations: [Annotation]) {
        self.canvas = canvas
        self.annotations = annotations
    }
}

/// 元に戻す / やり直し。状態のスナップショットを積む（絵は値型なので、変えていなければ中身は共有される）。
public struct History {
    public private(set) var undoStack: [DocState] = []
    public private(set) var redoStack: [DocState] = []
    /// 古い履歴を捨てたことがあるか（いちばん最初の状態にはもう戻れない）。
    public private(set) var droppedOldest = false
    public var maxCount: Int
    public var maxBytes: Int

    public init(maxCount: Int = 80, maxBytes: Int = 600 * 1024 * 1024) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func push(_ state: DocState) {
        undoStack.append(state)
        redoStack.removeAll()
        trim()
    }

    public mutating func undo(current: DocState) -> DocState? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return prev
    }

    public mutating func redo(current: DocState) -> DocState? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        droppedOldest = false
    }

    /// 履歴が使っているメモリ（同じ絵を共有しているスナップショットは 1 回だけ数える）。
    var bytes: Int {
        var seen = Set<UnsafeRawPointer>()
        var total = 0
        for s in undoStack {
            let p: UnsafeRawPointer? = s.canvas.pixels.withUnsafeBufferPointer { $0.baseAddress.map { UnsafeRawPointer($0) } }
            if let p = p, seen.insert(p).inserted { total += s.canvas.pixels.count * 4 }
        }
        return total
    }

    private mutating func trim() {
        while undoStack.count > maxCount { undoStack.removeFirst(); droppedOldest = true }
        while undoStack.count > 1 && bytes > maxBytes { undoStack.removeFirst(); droppedOldest = true }
    }
}
