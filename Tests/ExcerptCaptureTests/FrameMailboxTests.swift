import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptCapture

/// A clock the test fires by hand. A sleep ignores cancellation, like a timer that outlives
/// its wait, so a late fire is what the mailbox's wait ids must absorb.
@MainActor
final class ManualTimers {
    private var sleepers: [CheckedContinuation<Void, Never>?] = []
    var started: Int { sleepers.count }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// Ends the `index`th sleep started (0 first).
    func fire(_ index: Int) {
        guard let sleeper = sleepers[index] else { return }
        sleepers[index] = nil
        sleeper.resume()
    }
}

@MainActor
@Suite struct FrameMailboxTests {
    let a = ScrollFixtures.page(width: 8, height: 4, seed: 1)
    let b = ScrollFixtures.page(width: 8, height: 4, seed: 2)
    let timers = ManualTimers()

    struct Broken: Error, Equatable {}

    func makeMailbox() -> FrameMailbox {
        FrameMailbox(sleep: { [timers] in await timers.sleep($0) })
    }

    /// Starts a read and returns once it is waiting with its timer running.
    func startRead(
        _ mailbox: FrameMailbox, timersStarted: Int
    ) async -> Task<PixelBuffer?, Error> {
        let read = Task { @MainActor in try await mailbox.nextFrame(timeout: .seconds(1)) }
        while !mailbox.isWaiting || timers.started < timersStarted { await Task.yield() }
        return read
    }

    @Test func aWaitingFrameIsReadAtOnceAndOnlyTheNewestIsKept() async throws {
        let mailbox = makeMailbox()
        mailbox.deliver(a)
        mailbox.deliver(b)
        #expect(try await mailbox.nextFrame(timeout: .seconds(1)) == b)
        let read = await startRead(mailbox, timersStarted: 1)
        timers.fire(0)
        #expect(try await read.value == nil)
    }

    @Test func aReaderGetsTheNextFrameDelivered() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        mailbox.deliver(a)
        #expect(try await read.value == a)
    }

    @Test func aQuietStreamTimesOutWithNilNotAnError() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        timers.fire(0)
        #expect(try await read.value == nil)
    }

    @Test func anEarlierTimeoutNeverEndsALaterWait() async throws {
        let mailbox = makeMailbox()
        let first = await startRead(mailbox, timersStarted: 1)
        mailbox.deliver(a)
        #expect(try await first.value == a)
        let second = await startRead(mailbox, timersStarted: 2)
        timers.fire(0)  // the first wait's timer fires during the second wait
        for _ in 0..<20 { await Task.yield() }
        #expect(mailbox.isWaiting)
        mailbox.deliver(b)
        #expect(try await second.value == b)
    }

    @Test func discardedFramesAreNotRead() async throws {
        let mailbox = makeMailbox()
        mailbox.deliver(a)
        mailbox.discardWaiting()
        let read = await startRead(mailbox, timersStarted: 1)
        timers.fire(0)
        #expect(try await read.value == nil)
    }

    @Test func aFailureWhileWaitingEndsTheWaitAndEveryLaterRead() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        mailbox.fail(Broken())
        await #expect(throws: Broken.self) { try await read.value }
        mailbox.deliver(a)
        await #expect(throws: Broken.self) { try await mailbox.nextFrame(timeout: .seconds(1)) }
    }

    @Test func aFailureAfterATimeoutIsNotLostToIt() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        timers.fire(0)
        #expect(try await read.value == nil)
        mailbox.fail(Broken())
        await #expect(throws: Broken.self) { try await mailbox.nextFrame(timeout: .seconds(1)) }
    }

    @Test func aFailureWithNoReaderThrowsOnTheNextReadNotNil() async throws {
        let mailbox = makeMailbox()
        mailbox.deliver(a)
        mailbox.fail(Broken())
        await #expect(throws: Broken.self) { try await mailbox.nextFrame(timeout: .seconds(1)) }
    }

    @Test func aTimerFiringAfterAFailureChangesNothing() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        mailbox.fail(Broken())
        await #expect(throws: Broken.self) { try await read.value }
        timers.fire(0)
        for _ in 0..<20 { await Task.yield() }
        await #expect(throws: Broken.self) { try await mailbox.nextFrame(timeout: .seconds(1)) }
    }

    @Test func aSecondFailureKeepsTheFirst() async throws {
        struct Other: Error {}
        let mailbox = makeMailbox()
        mailbox.fail(Broken())
        mailbox.fail(Other())
        await #expect(throws: Broken.self) { try await mailbox.nextFrame(timeout: .seconds(1)) }
    }

    @Test func cancellingAWaitEndsItWithCancellation() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(!mailbox.isWaiting)
        timers.fire(0)
        for _ in 0..<20 { await Task.yield() }
        let next = await startRead(mailbox, timersStarted: 2)
        mailbox.deliver(a)
        #expect(try await next.value == a)
    }

    @Test func aReadRightAfterACancelledOneEndsTheStaleWaitInsteadOfTrapping() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        // The cancelled wait is resumed by a hop to the main actor, which runs after the next
        // read below has started.
        read.cancel()
        Task { @MainActor in mailbox.deliver(a) }
        #expect(try await mailbox.nextFrame(timeout: .seconds(1)) == a)
        await #expect(throws: CancellationError.self) { try await read.value }
        timers.fire(0)
        timers.fire(1)
    }

    @Test func aReadStartedAlreadyCancelledThrowsAndLeavesNoWait() async throws {
        let mailbox = makeMailbox()
        let read = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await mailbox.nextFrame(timeout: .seconds(1))
        }
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(!mailbox.isWaiting)
    }

    @Test func aFrameAfterATimeoutIsKeptForTheNextRead() async throws {
        let mailbox = makeMailbox()
        let read = await startRead(mailbox, timersStarted: 1)
        timers.fire(0)
        #expect(try await read.value == nil)
        mailbox.deliver(a)
        #expect(try await mailbox.nextFrame(timeout: .seconds(1)) == a)
    }
}
