/// Undo as a stack of whole values: recording keeps the value before a change, undo swaps the
/// current value for the last one kept, and redo swaps it back.
struct UndoStack<Value> {
    private var past: [Value] = []
    private var future: [Value] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Keeps `before` as the state to return to; a new change discards anything undone.
    mutating func record(_ before: Value) {
        past.append(before)
        future.removeAll()
    }

    mutating func undo(from current: Value) -> Value? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(from current: Value) -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}
