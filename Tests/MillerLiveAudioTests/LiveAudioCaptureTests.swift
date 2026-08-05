import Foundation
import MillerLive
import Testing
@testable import MillerLiveAudio

struct LiveAudioCaptureTests {
    @Test(arguments: [false, true])
    func captureDriverFailureUsesTrueFirstClaimOrdering(
        providerFirst: Bool
    ) async throws {
        let terminal = LiveAudioTerminalClaim()
        let driver = SignalingCaptureDriver()
        let capture = LiveAudioCapture(driver: driver)
        if providerFirst { #expect(terminal.claimProvider()) }
        try await capture.start(
            permission: .authorized,
            claimFailure: { terminal.claimAudio($0) },
            receive: { _ in }
        )

        await driver.fail(SyntheticCaptureError.rawDiagnostic)

        if providerFirst {
            #expect(terminal.audioFailure == nil)
        } else {
            #expect(!terminal.claimProvider())
            #expect(terminal.audioFailure == .captureFailed)
        }
        await capture.stop()
    }

    @Test
    func chunkerEmitsExactOneHundredMillisecondPCM16Frames() throws {
        var chunker = PCM16InputChunker()
        #expect(try chunker.append(Data(repeating: 0x01, count: 4_798)).isEmpty)
        let frames = try chunker.append(Data([0x02, 0x02]) + Data(repeating: 0x03, count: 4_800))

        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.data.count == 4_800 })
        #expect(frames.allSatisfy { $0.sampleRate == 24_000 })
        #expect(frames.allSatisfy { $0.numChannels == 1 })
        #expect(frames.allSatisfy { $0.samplesPerChannel == 2_400 })
    }

    @Test
    func chunkerRejectsMisalignedPCM16Input() {
        var chunker = PCM16InputChunker()
        #expect(throws: (any Error).self) {
            _ = try chunker.append(Data([0x01]))
        }
    }

    @Test
    func repeatedCaptureStopReachesDriverExactlyOnce() async throws {
        let driver = StopCountingCaptureDriver()
        let capture = LiveAudioCapture(driver: driver)
        try await capture.start(permission: .authorized) { _ in }

        await capture.stop()
        await capture.stop()

        #expect(await driver.stops == 1)
    }

    @Test
    func activeInputDeviceLossPreservesSanitizedDeviceFailure() async throws {
        let driver = SignalingCaptureDriver()
        let failures = CaptureFailureRecorder()
        let capture = LiveAudioCapture(driver: driver)
        try await capture.start(permission: .authorized) { result in
            guard case let .failure(error) = result,
                  let failure = error as? LiveAudioError else { return }
            Task { await failures.record(failure) }
        }

        await driver.fail(LiveAudioError.microphoneUnavailable)
        try await waitUntil { await failures.values.count == 1 }
        await capture.stop()

        #expect(await failures.values == [.microphoneUnavailable])
        #expect(await driver.stops == 1)
    }

    @Test
    func captureDriverDetectsUnavailableInputWithoutPhysicalDevice() async {
        let driver = AVFoundationCaptureDriver(
            permissionStatus: { .authorized },
            inputAvailable: { false },
            monitoringInterval: .milliseconds(10)
        )

        let failure = await driver.invalidations().first(where: { _ in true })

        #expect(failure == .microphoneUnavailable)
    }

    @Test
    func captureDriverDetectsRevokedPermissionWithoutSystemPrompt() async {
        let driver = AVFoundationCaptureDriver(
            permissionStatus: { .denied },
            inputAvailable: { true },
            monitoringInterval: .milliseconds(10)
        )

        let failure = await firstInvalidation(
            from: await driver.invalidations(),
            within: .milliseconds(50)
        )

        #expect(failure == .permissionDenied)
    }

    @Test
    func staleCaptureDataAndErrorCannotReachNextRun() async throws {
        let driver = ReusableCaptureDriver()
        let first = CaptureResultRecorder()
        let second = CaptureResultRecorder()
        let capture = LiveAudioCapture(driver: driver)

        try await capture.start(permission: .authorized) { result in
            Task { await first.record(result) }
        }
        try await waitUntil { await driver.subscriptionCount == 1 }
        await capture.stop()
        try await capture.start(permission: .authorized) { result in
            Task { await second.record(result) }
        }
        try await waitUntil { await driver.subscriptionCount == 2 }

        await driver.emitData(run: 0)
        await driver.emitError(run: 0)
        await driver.emitData(run: 1)
        try await waitUntil { await second.resultCount > 0 }
        await capture.stop()

        #expect(await first.resultCount == 0)
        #expect(await second.successCount == 1)
        #expect(await second.failureCount == 0)
    }

    @Test
    func staleCaptureInvalidationCannotReachNextRun() async throws {
        let driver = ReusableCaptureDriver()
        let first = CaptureResultRecorder()
        let second = CaptureResultRecorder()
        let capture = LiveAudioCapture(driver: driver)

        try await capture.start(permission: .authorized) { result in
            Task { await first.record(result) }
        }
        try await waitUntil { await driver.subscriptionCount == 1 }
        await capture.stop()
        try await capture.start(permission: .authorized) { result in
            Task { await second.record(result) }
        }
        try await waitUntil { await driver.subscriptionCount == 2 }

        await driver.failInvalidation(run: 0)
        await driver.emitData(run: 1)
        try await waitUntil { await second.resultCount > 0 }
        await capture.stop()

        #expect(await first.resultCount == 0)
        #expect(await second.successCount == 1)
        #expect(await second.failureCount == 0)
    }

    @Test
    func captureInvalidationChecksUseOneSerializedAudioBoundary() async {
        let probe = CaptureSerializationProbe()
        let driver = AVFoundationCaptureDriver(
            permissionStatus: { .authorized },
            inputAvailable: { probe.check() },
            monitoringInterval: .milliseconds(10)
        )

        async let first = driver.invalidations().first(where: { _ in true })
        async let second = driver.invalidations().first(where: { _ in true })
        _ = await (first, second)

        #expect(probe.maximumConcurrentChecks == 1)
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw LiveAudioError.captureFailed }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func firstInvalidation(
        from stream: AsyncStream<LiveAudioError>,
        within duration: Duration
    ) async -> LiveAudioError? {
        await withTaskGroup(of: LiveAudioError?.self) { group in
            group.addTask { await stream.first(where: { _ in true }) }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private actor StopCountingCaptureDriver: LiveAudioCaptureDriving {
    private(set) var stops = 0

    func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws {}

    func stop() async { stops += 1 }
}

private actor SignalingCaptureDriver: LiveAudioCaptureDriving {
    private var receive: (@Sendable (Result<Data, Error>) -> Void)?
    private(set) var stops = 0

    func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws {
        self.receive = receive
    }

    func stop() async {
        stops += 1
        receive = nil
    }

    func fail(_ error: Error) { receive?(.failure(error)) }
}

private actor CaptureFailureRecorder {
    private(set) var values: [LiveAudioError] = []

    func record(_ failure: LiveAudioError) { values.append(failure) }
}

private actor ReusableCaptureDriver: LiveAudioCaptureDriving {
    private var receivers: [@Sendable (Result<Data, Error>) -> Void] = []
    private var invalidationContinuations: [AsyncStream<LiveAudioError>.Continuation] = []
    private(set) var subscriptionCount = 0

    func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws {
        receivers.append(receive)
    }

    func stop() async {}

    func invalidations() async -> AsyncStream<LiveAudioError> {
        AsyncStream { continuation in
            invalidationContinuations.append(continuation)
            subscriptionCount += 1
        }
    }

    func emitData(run: Int) {
        receivers[run](.success(Data(repeating: 0, count: 4_800)))
    }

    func emitError(run: Int) {
        receivers[run](.failure(SyntheticCaptureError.rawDiagnostic))
    }

    func failInvalidation(run: Int) {
        invalidationContinuations[run].yield(.microphoneUnavailable)
    }
}

private actor CaptureResultRecorder {
    private(set) var successCount = 0
    private(set) var failureCount = 0
    var resultCount: Int { successCount + failureCount }

    func record(_ result: Result<LiveAudioFrame, Error>) {
        switch result {
        case .success: successCount += 1
        case .failure: failureCount += 1
        }
    }
}

private enum SyntheticCaptureError: Error {
    case rawDiagnostic
}

private final class CaptureSerializationProbe: @unchecked Sendable {
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
