import Testing

@testable import ExcerptCore

/// Jobs that record their start and run until the test releases them.
private actor Jobs {
    private(set) var started: [Int] = []
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]

    func run(_ key: Int) async -> String? {
        started.append(key)
        await withCheckedContinuation { gates[key] = $0 }
        return key < 0 ? nil : "v\(key)"
    }

    func release(_ key: Int) { gates.removeValue(forKey: key)?.resume() }
}

/// Yields until `condition` holds; fails the test after many turns.
private func eventually(_ condition: () async -> Bool) async {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("condition never held")
}

@Suite struct QueuedWorkTests {
    @Test func startsInOrderAtMostWidthAtOnce() async {
        let jobs = Jobs()
        let work = QueuedWork(keys: [1, 2, 3, 4], width: 2) { await jobs.run($0) }
        await work.start()
        await eventually { await jobs.started == [1, 2] }
        await jobs.release(1)
        await eventually { await jobs.started == [1, 2, 3] }
        #expect(await jobs.started == [1, 2, 3])
    }

    @Test func aWaitedKeyStartsNext() async {
        let jobs = Jobs()
        let work = QueuedWork(keys: [1, 2, 3, 4, 5], width: 1) { await jobs.run($0) }
        await work.start()
        await eventually { await jobs.started == [1] }
        async let five = work.value(for: 5)
        await eventually { await work.isWaiting(for: 5) }
        await jobs.release(1)
        await eventually { await jobs.started == [1, 5] }
        await jobs.release(5)
        #expect(await five == "v5")
    }

    @Test func aFinishedKeyAnswersAtOnce() async {
        let jobs = Jobs()
        let work = QueuedWork(keys: [1], width: 1) { await jobs.run($0) }
        await work.start()
        await eventually { await jobs.started == [1] }
        await jobs.release(1)
        #expect(await work.value(for: 1) == "v1")
        #expect(await work.value(for: 1) == "v1")
    }

    @Test func aFailedJobAnswersNil() async {
        let jobs = Jobs()
        let work = QueuedWork(keys: [-1], width: 1) { await jobs.run($0) }
        await work.start()
        await eventually { await jobs.started == [-1] }
        await jobs.release(-1)
        #expect(await work.value(for: -1) == nil)
    }

    @Test func aKeyNotQueuedAnswersNil() async {
        let work = QueuedWork(keys: [1], width: 1) { _ in "never" }
        #expect(await work.value(for: 9) == nil)
    }

    @Test func cancelStartsNothingMoreAndAnswersUnstartedKeysNil() async {
        let jobs = Jobs()
        let work = QueuedWork(keys: [1, 2, 3], width: 1) { await jobs.run($0) }
        await work.start()
        await eventually { await jobs.started == [1] }
        async let three = work.value(for: 3)
        await eventually { await work.isWaiting(for: 3) }
        await work.cancel()
        #expect(await three == nil)
        await jobs.release(1)
        #expect(await work.value(for: 1) == "v1")
        for _ in 0..<100 { await Task.yield() }
        #expect(await jobs.started == [1])
    }
}
