import Foundation
import MillerLive
import Testing
@testable import MillerLiveAudio

struct LiveAudioPlaybackTests {
    @Test
    func playbackClaimsDriverFailureBeforeAsyncCleanupDelivery() async throws {
        let terminal = LiveAudioTerminalClaim()
        let delivery = AsyncGate()
        let driver = FailingPlaybackDriver()
        let playback = LiveAudioPlayback(driver: driver)

        await playback.start(
            claimFailure: { terminal.claimAudio($0) },
            receiveFailure: { _ in await delivery.wait() }
        )
        try await playback.enqueue(shortFrame())
        try await waitUntil { await driver.interrupts == 1 }

        #expect(!terminal.claimProvider())
        #expect(terminal.audioFailure == .playbackFailed)
        await delivery.open()
        await playback.interrupt()
    }

    @Test
    func providerClaimBeforePlaybackDriverFailureRemainsWinner() async throws {
        let terminal = LiveAudioTerminalClaim()
        let delivered = CompletionFlag()
        let driver = FailingPlaybackDriver()
        let playback = LiveAudioPlayback(driver: driver)
        #expect(terminal.claimProvider())

        await playback.start(
            claimFailure: { terminal.claimAudio($0) },
            receiveFailure: { _ in await delivered.mark() }
        )
        try await playback.enqueue(shortFrame())
        try await waitUntil { await driver.interrupts == 1 }

        #expect(terminal.audioFailure == nil)
        #expect(await !delivered.value)
        await playback.interrupt()
    }

    @Test(arguments: [false, true])
    func outputBackpressureUsesTrueFirstClaimOrdering(
        providerFirst: Bool
    ) async throws {
        let terminal = LiveAudioTerminalClaim()
        let catchGate = AsyncGate()
        let caught = CompletionFlag()
        let playback = LiveAudioPlayback(driver: SuspendedPlaybackDriver())
        let oneSecond = try LiveAudioFrame(
            data: Data(repeating: 0, count: 48_000),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 24_000,
            itemID: nil
        )
        if providerFirst { #expect(terminal.claimProvider()) }
        await playback.start(
            claimFailure: { terminal.claimAudio($0) },
            receiveFailure: { _ in }
        )
        try await playback.enqueue(oneSecond)
        try await playback.enqueue(oneSecond)

        let attempt = Task<Result<Void, Error>, Never> {
            do {
                try await playback.enqueue(oneSecond)
                return .success(())
            } catch {
                await caught.mark()
                await catchGate.wait()
                return .failure(error)
            }
        }
        try await waitUntil { await caught.value }

        if providerFirst {
            #expect(terminal.audioFailure == nil)
        } else {
            #expect(!terminal.claimProvider())
            #expect(terminal.audioFailure == .audioBackpressure)
        }
        await catchGate.open()
        #expect(await attempt.value.failure as? LiveAudioError == .audioBackpressure)
        await playback.interrupt()
    }

    @Test
    func queueAcceptsAtMostTwoSecondsAndInterruptClearsIt() async throws {
        let playback = LiveAudioPlayback(driver: SuspendedPlaybackDriver())
        let oneSecond = try LiveAudioFrame(
            data: Data(repeating: 0, count: 48_000),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 24_000,
            itemID: nil
        )

        try await playback.enqueue(oneSecond)
        try await playback.enqueue(oneSecond)
        await #expect(throws: LiveAudioError.audioBackpressure) {
            try await playback.enqueue(oneSecond)
        }
        await playback.interrupt()
        #expect(await playback.queuedDuration == .zero)
    }

    @Test
    func repeatedPlaybackInterruptReachesDriverExactlyOnce() async {
        let driver = InterruptCountingPlaybackDriver()
        let playback = LiveAudioPlayback(driver: driver)

        await playback.interrupt()
        await playback.interrupt()

        #expect(await driver.interrupts == 1)
    }

    @Test
    func playbackDriverFailureIsReportedOnceAndClearsQueuedOutput() async throws {
        let driver = FailingPlaybackDriver()
        let failures = PlaybackFailureRecorder()
        let playback = LiveAudioPlayback(driver: driver)
        let frame = try LiveAudioFrame(
            data: Data(repeating: 0, count: 4_800),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 2_400,
            itemID: nil
        )

        await playback.start { failure in
            await failures.record(failure)
        }
        try await playback.enqueue(frame)
        try await waitUntil { await failures.values.count == 1 }

        #expect(await failures.values == [.playbackFailed])
        #expect(await playback.queuedDuration == .zero)
        #expect(await driver.interrupts == 1)
    }

    @Test
    func playbackDriverDetectsUnavailableOutputWithoutPhysicalDevice() async {
        let driver = AVFoundationPlaybackDriver(
            outputAvailable: { false },
            monitoringInterval: .milliseconds(10)
        )

        let failure = await driver.invalidations().first(where: { _ in true })

        #expect(failure == .microphoneUnavailable)
    }

    @Test
    func stalePlaybackCompletionCannotClearNextRunState() async throws {
        let driver = ReusablePlaybackDriver()
        let first = PlaybackFailureRecorder()
        let second = PlaybackFailureRecorder()
        let playback = LiveAudioPlayback(driver: driver)
        let frame = try shortFrame()

        await playback.start { failure in await first.record(failure) }
        try await playback.enqueue(frame)
        try await waitUntil { await driver.playCount == 1 }
        await playback.interrupt()
        await playback.start { failure in await second.record(failure) }
        try await playback.enqueue(frame)
        try await waitUntil { await driver.playCount == 2 }
        try await playback.enqueue(frame)

        await driver.complete(play: 0)
        await driver.complete(play: 1)
        try await waitUntil { await driver.playCount == 3 }

        #expect(await playback.queuedDuration == frame.duration)
        #expect(await second.values.isEmpty)
        await driver.complete(play: 2)
        await playback.interrupt()
    }

    @Test
    func stalePlaybackFailureCannotFailNextRun() async throws {
        let driver = ReusablePlaybackDriver()
        let first = PlaybackFailureRecorder()
        let second = PlaybackFailureRecorder()
        let playback = LiveAudioPlayback(driver: driver)
        let frame = try shortFrame()

        await playback.start { failure in await first.record(failure) }
        try await playback.enqueue(frame)
        try await waitUntil { await driver.playCount == 1 }
        await playback.interrupt()
        await playback.start { failure in await second.record(failure) }
        try await playback.enqueue(frame)
        try await waitUntil { await driver.playCount == 2 }
        try await playback.enqueue(frame)

        await driver.fail(play: 0)
        await driver.complete(play: 1)
        try await waitUntil { await driver.playCount == 3 }

        #expect(await second.values.isEmpty)
        #expect(await playback.queuedDuration == frame.duration)
        await driver.complete(play: 2)
        await playback.interrupt()
    }

    @Test
    func staleFailureCompletionCannotEraseNextInterruptFence() async throws {
        let driver = GatedInterruptPlaybackDriver()
        let firstFailure = AsyncGate()
        let secondFailure = AsyncGate()
        let cleanupFinished = CompletionFlag()
        let frame = try shortFrame()
        let playback = LiveAudioPlayback(driver: driver)

        await playback.start { _ in await firstFailure.wait() }
        try await playback.enqueue(frame)
        await driver.waitForInterrupts(1)

        await playback.start { _ in await secondFailure.wait() }
        try await playback.enqueue(frame)
        await driver.waitForInterrupts(2)

        await driver.release(interrupt: 0)
        await firstFailure.open()

        let cleanup = Task {
            await playback.interrupt()
            await cleanupFinished.mark()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await !cleanupFinished.value)

        await driver.release(interrupt: 1)
        await cleanup.value
        await secondFailure.open()
        #expect(await driver.interrupts == 2)
    }

    @Test
    func playbackInvalidationChecksUseOneSerializedAudioBoundary() async {
        let probe = PlaybackSerializationProbe()
        let driver = AVFoundationPlaybackDriver(
            outputAvailable: { probe.check() },
            monitoringInterval: .milliseconds(10)
        )

        async let first = driver.invalidations().first(where: { _ in true })
        async let second = driver.invalidations().first(where: { _ in true })
        _ = await (first, second)

        #expect(probe.maximumConcurrentChecks == 1)
    }

    private func shortFrame() throws -> LiveAudioFrame {
        try LiveAudioFrame(
            data: Data(repeating: 0, count: 4_800),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 2_400,
            itemID: nil
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw LiveAudioError.playbackFailed }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

private actor SuspendedPlaybackDriver: LiveAudioPlaybackDriving {
    func play(_ frame: LiveAudioFrame) async throws {
        try await Task.sleep(for: .seconds(30))
    }

    func interrupt() async {}
}

private actor InterruptCountingPlaybackDriver: LiveAudioPlaybackDriving {
    private(set) var interrupts = 0

    func play(_ frame: LiveAudioFrame) async throws {}
    func interrupt() async { interrupts += 1 }
}

private actor FailingPlaybackDriver: LiveAudioPlaybackDriving {
    private(set) var interrupts = 0

    func play(_ frame: LiveAudioFrame) async throws {
        throw SyntheticPlaybackError.rawDiagnostic
    }

    func interrupt() async { interrupts += 1 }
}

private actor PlaybackFailureRecorder {
    private(set) var values: [LiveAudioError] = []

    func record(_ failure: LiveAudioError) { values.append(failure) }
}

private enum SyntheticPlaybackError: Error {
    case rawDiagnostic
}

private actor ReusablePlaybackDriver: LiveAudioPlaybackDriving {
    private var plays: [CheckedContinuation<Void, Error>] = []
    private(set) var playCount = 0

    func play(_ frame: LiveAudioFrame) async throws {
        playCount += 1
        try await withCheckedThrowingContinuation { plays.append($0) }
    }

    func interrupt() async {}

    func complete(play: Int) {
        plays[play].resume()
    }

    func fail(play: Int) {
        plays[play].resume(throwing: SyntheticPlaybackError.rawDiagnostic)
    }
}

private actor GatedInterruptPlaybackDriver: LiveAudioPlaybackDriving {
    private var interruptionContinuations: [CheckedContinuation<Void, Never>?] = []
    private var interruptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var interrupts = 0

    func play(_ frame: LiveAudioFrame) async throws {
        throw SyntheticPlaybackError.rawDiagnostic
    }

    func interrupt() async {
        interrupts += 1
        for (target, waiter) in interruptWaiters where interrupts >= target {
            waiter.resume()
        }
        interruptWaiters.removeAll { interrupts >= $0.0 }
        await withCheckedContinuation {
            interruptionContinuations.append($0)
        }
    }

    func waitForInterrupts(_ target: Int) async {
        guard interrupts < target else { return }
        await withCheckedContinuation { interruptWaiters.append((target, $0)) }
    }

    func release(interrupt index: Int) {
        interruptionContinuations[index]?.resume()
        interruptionContinuations[index] = nil
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CompletionFlag {
    private(set) var value = false

    func mark() { value = true }
}

private final class PlaybackSerializationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximumConcurrentChecks = 0

    func check() -> Bool {
        lock.withLock {
            active += 1
            maximumConcurrentChecks = max(maximumConcurrentChecks, active)
        }
        Thread.sleep(forTimeInterval: 0.05)
        lock.withLock { active -= 1 }
        return false
    }
}
