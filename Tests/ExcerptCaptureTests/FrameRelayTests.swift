import ExcerptCore
import ExcerptTestSupport
import Testing
import os

@testable import ExcerptCapture

/// Blocks scheduled for the main queue, run when the test says: a main actor busy elsewhere.
final class HeldMainQueue: @unchecked Sendable {
    private let blocks = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    var count: Int { blocks.withLock { $0.count } }

    func schedule(_ block: @escaping @Sendable () -> Void) {
        blocks.withLock { $0.append(block) }
    }

    @MainActor func runAll() {
        let queued = blocks.withLock { queued in
            defer { queued = [] }
            return queued
        }
        for block in queued { block() }
    }
}

@MainActor
@Suite struct FrameRelayTests {
    let a = ScrollFixtures.page(width: 8, height: 4, seed: 1)
    let b = ScrollFixtures.page(width: 8, height: 4, seed: 2)
    let c = ScrollFixtures.page(width: 8, height: 4, seed: 3)

    @Test func framesPostedWhileTheMainActorIsBusyHoldOnlyTheNewest() {
        let main = HeldMainQueue()
        var delivered: [PixelBuffer] = []
        let relay = FrameRelay(schedule: main.schedule) { delivered.append($0) }
        relay.post(a)
        relay.post(b)
        relay.post(c)
        #expect(main.count == 1)
        main.runAll()
        #expect(delivered == [c])
    }

    @Test func aFramePostedAfterTheWakeupRanSchedulesAnother() {
        let main = HeldMainQueue()
        var delivered: [PixelBuffer] = []
        let relay = FrameRelay(schedule: main.schedule) { delivered.append($0) }
        relay.post(a)
        main.runAll()
        relay.post(b)
        #expect(main.count == 1)
        main.runAll()
        #expect(delivered == [a, b])
    }
}
