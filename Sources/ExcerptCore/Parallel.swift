import Dispatch

/// Work started on another thread now and waited for later, so a caller can do its own work
/// meanwhile: two PNG encodes of one save run side by side.
public final class Started<Value: Sendable>: @unchecked Sendable {
    private let group = DispatchGroup()
    /// Written once on the work's thread before the group leaves; read only after `wait`.
    private var result: Result<Value, any Error>?

    public init(_ work: @escaping @Sendable () throws -> Value) {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            self.result = Result { try work() }
        }
    }

    /// Blocks until the work is done; its value, or what it threw.
    public func value() throws -> Value {
        group.wait()
        return try result!.get()
    }
}

/// `transform` applied to every element of `items` across the machine's cores, results in the
/// order of `items`. The first error thrown (by index) is rethrown once every element is done.
public func parallelMap<Item: Sendable, Value: Sendable>(
    _ items: [Item], _ transform: @Sendable (Item) throws -> Value
) throws -> [Value] {
    let results = ResultSlots<Value>(count: items.count)
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        results.set(i, Result { try transform(items[i]) })
    }
    return try results.values()
}

/// One slot per index, each written by exactly one iteration of `concurrentPerform`, which
/// returns only after all of them: distinct slots, so no two writes race.
/// A raw buffer rather than an array: concurrent writes through an array property would be
/// overlapping accesses to that property, however distinct the elements.
private final class ResultSlots<Value>: @unchecked Sendable {
    private let slots: UnsafeMutableBufferPointer<Result<Value, any Error>?>

    init(count: Int) {
        slots = .allocate(capacity: count)
        slots.initialize(repeating: nil)
    }

    deinit {
        slots.deinitialize()
        slots.deallocate()
    }

    func set(_ index: Int, _ result: Result<Value, any Error>) { slots[index] = result }

    func values() throws -> [Value] { try slots.map { try $0!.get() } }
}
