/// 元に戻す / やり直し。キャンバス全体のスナップショットを積む。
public struct History {
    public private(set) var undoStack: [Bitmap] = []
    public private(set) var redoStack: [Bitmap] = []
    /// 古い履歴を捨てたことがあるか（いちばん最初の状態にはもう戻れない）。
    public private(set) var droppedOldest = false
    public var maxCount: Int
    public var maxBytes: Int

    public init(maxCount: Int = 50, maxBytes: Int = 600 * 1024 * 1024) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func push(_ state: Bitmap) {
        undoStack.append(state)
        redoStack.removeAll()
        trim()
    }

    public mutating func undo(current: Bitmap) -> Bitmap? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return prev
    }

    public mutating func redo(current: Bitmap) -> Bitmap? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        droppedOldest = false
    }

    private mutating func trim() {
        func bytes() -> Int { undoStack.reduce(0) { $0 + $1.pixels.count * 4 } }
        while undoStack.count > maxCount { undoStack.removeFirst(); droppedOldest = true }
        while undoStack.count > 1 && bytes() > maxBytes { undoStack.removeFirst(); droppedOldest = true }
    }
}
