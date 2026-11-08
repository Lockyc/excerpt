/// One job per key, started in the keys' order with at most `width` running at once; asking
/// for a key's value moves it to the front of the jobs not yet started. A job's nil, a key not
/// queued, and a key `cancel` stopped before it started all answer nil.
///
/// For work a service runs one at a time, such as ScreenCaptureKit's stills: a few in flight
/// keep it busy, and the one a caller is waiting on never sits behind the rest.
public actor QueuedWork<Key: Hashable & Sendable, Value: Sendable> {
    private let width: Int
    private let job: @Sendable (Key) async -> Value?
    private var pending: [Key]
    /// Keys whose jobs have started and not finished.
    private var running: Set<Key> = []
    private var cancelled = false
    private var values: [Key: Value?] = [:]
    private var waiters: [Key: [CheckedContinuation<Value?, Never>]] = [:]

    public init(keys: [Key], width: Int, job: @escaping @Sendable (Key) async -> Value?) {
        self.pending = keys
        self.width = max(1, width)
        self.job = job
    }

    /// Starts the first jobs.
    public func start() { fill() }

    /// The value of `key`'s job, once it has run.
    public func value(for key: Key) async -> Value? {
        if let value = values[key] { return value }
        guard let index = pending.firstIndex(of: key) else {
            // Running, or never queued.
            guard running.contains(key) else { return nil }
            return await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
        pending.remove(at: index)
        pending.insert(key, at: 0)
        return await withCheckedContinuation {
            waiters[key, default: []].append($0)
            fill()
        }
    }

    /// Starts no more jobs; those not started answer nil. Running jobs finish.
    public func cancel() {
        cancelled = true
        for key in pending {
            for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume(returning: nil) }
        }
        pending = []
    }

    /// Whether a caller is waiting on `key`.
    func isWaiting(for key: Key) -> Bool { !(waiters[key] ?? []).isEmpty }

    private func fill() {
        while !cancelled, running.count < width, !pending.isEmpty {
            let key = pending.removeFirst()
            running.insert(key)
            let job = self.job
            Task { await finish(key, await job(key)) }
        }
    }

    private func finish(_ key: Key, _ value: Value?) {
        running.remove(key)
        values[key] = .some(value)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume(returning: value) }
        fill()
    }
}
