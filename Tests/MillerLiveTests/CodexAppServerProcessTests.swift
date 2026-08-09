@testable import MillerLive
import Darwin
import Foundation
import Testing

private let processTestSHA256Fingerprint = "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"

private let processTestBrowserWebRTCOffer = """
v=0\r
o=- 0 0 IN IP4 0.0.0.0\r
s=-\r
t=0 0\r
a=group:BUNDLE 0 1\r
m=audio 9 UDP/TLS/RTP/SAVPF 111\r
a=mid:0\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 \(processTestSHA256Fingerprint)\r
a=setup:actpass\r
a=rtpmap:111 opus/48000/2\r
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
a=mid:1\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 \(processTestSHA256Fingerprint)\r
a=setup:actpass\r
a=sctp-port:5000\r
a=max-message-size:262144\r
"""

@Suite(.serialized)
struct CodexAppServerProcessTests {
    @Test
    func rejectsRelativeExecutableAndCreatesPrivate0700Roots() async throws {
        #expect(throws: LiveProcessError.invalidConfiguration) {
            try CodexAppServerProcess.Configuration(
                executableURL: URL(fileURLWithPath: "relative/node", relativeTo: repository),
                arguments: [],
                temporaryParentURL: repository.appendingPathComponent(".artifacts")
            )
        }
        let process = CodexAppServerProcess(configuration: try configuration(mode: "hang"))
        _ = try process.start()
        #expect(process.inputSuppressesSIGPIPE)
        for root in [
            process.temporaryRootURL,
            process.temporaryRootURL.appendingPathComponent("codex-home"),
            process.temporaryRootURL.appendingPathComponent("tmp"),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        let config = process.temporaryRootURL.appendingPathComponent("codex-home/config.toml")
        #expect(try String(contentsOf: config, encoding: .utf8) == """
        [features]
        realtime_conversation = true

        [realtime]
        version = "v1"

        """)
        let configAttributes = try FileManager.default.attributesOfItem(atPath: config.path)
        #expect((configAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await process.stop()
    }

    @Test
    func stalledConsumerBackpressuresBoundedOutputUntilOperatorStop() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "flood-output"))
        _ = try process.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(process.isRunning)
        #expect(FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
        await process.stop()
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func concurrentLargeFrameWritesAndCloseNeverInterleaveOrRaceDescriptors() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "transport-race"))
        _ = try process.start()
        let payload = String(repeating: "x", count: 32_768)
        await withTaskGroup(of: Void.self) { group in
            for ordinal in 0..<8 {
                group.addTask {
                    let frame = Data("{\"method\":\"race\",\"ordinal\":\(ordinal),\"payload\":\"\(payload)\"}\n".utf8)
                    try? process.send(frame)
                }
            }
        }
        process.closeInput()
        try await process.waitForExit(timeout: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func usesExactReviewedFixedEnvironment() throws {
        let config = try configuration(mode: "normal")
        #expect(config.environment == [
            "HOME": config.temporaryRootURL.path,
            "CODEX_HOME": config.temporaryRootURL.appendingPathComponent("codex-home").path,
            "TMPDIR": config.temporaryRootURL.appendingPathComponent("tmp").path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "NO_COLOR": "1",
        ])
    }

    @Test
    func streamsFramesAndRemovesPrivateRootAfterNormalExit() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "normal"))
        let root = process.temporaryRootURL
        let stream = try process.start()
        try process.send(Data("{\"method\":\"ping\"}\n".utf8))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data("{\"id\":1,\"result\":{}}".utf8))
        process.closeInput()
        try await process.waitForExit(timeout: .seconds(2))
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func fakeServerRejectsRealtimeStartBeforeThreadCreation() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "persistent"))
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        let codec = CodexAppServerProtocol()
        try process.send(try codec.initializeRequest(id: "request:initialize"))
        _ = try await iterator.next()
        try process.send(try codec.realtimeStartRequest(
            id: "request:start", threadID: "invented-thread",
            offerSDP: processTestBrowserWebRTCOffer
        ))
        let response = try #require(try await iterator.next())
        #expect(try codec.decode(response) == .requestError(
            id: "request:start", code: -32600, message: "thread not loaded"
        ))
        await process.stop()
    }

    @Test
    func clientOfferPreflightLeavesTheProcessUnstartedAndRootAbsent() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/preflight-process-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "record-helper-launch", extraArguments: [marker.path]
        ))
        let root = process.temporaryRootURL
        let client = CodexAppServerClient(process: process)
        let fabricatedOffer = """
        v=0\r
        m=audio 9 UDP/TLS/RTP/SAVPF 111\r
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
        """

        await #expect(throws: (any Error).self) {
            _ = try await client.runUntilClosed(
                identity: .init(requestID: "preflight", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic".utf8), accountID: "account-1", planType: nil
                ),
                offerSDP: fabricatedOffer,
                timeout: .seconds(2)
            )
        }

        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func rejectingSpawnedVerifierReapsTheActualProcessBeforeProtocolWrites() async throws {
        let marker = repository.appendingPathComponent(
            ".artifacts/rejected-spawn-input-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let verifier = SpawnVerifierProbe(outcome: .reject)
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "record-stdin",
            extraArguments: [marker.path],
            spawnedProcessVerifier: { pid in try verifier.verify(pid: pid) }
        ))
        let root = process.temporaryRootURL
        let client = CodexAppServerClient(process: process)

        await #expect(throws: (any Error).self) {
            _ = try await client.runUntilClosed(
                identity: .init(requestID: "rejected-spawn", threadID: "thread-1", generation: 1),
                credential: .init(
                    accessToken: Data("synthetic-credential".utf8),
                    accountID: "account-1",
                    planType: nil
                ),
                offerSDP: processTestBrowserWebRTCOffer,
                timeout: .seconds(2)
            )
        }

        let pid = try #require(verifier.observedPID)
        #expect(pid > 0)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try await waitUntil { Darwin.kill(pid, 0) != 0 && errno == ESRCH }
    }

    @Test
    func acceptedSpawnedVerifierAllowsTheProcessToProceed() async throws {
        let verifier = SpawnVerifierProbe(outcome: .accept)
        let process = CodexAppServerProcess(configuration: try configuration(
            mode: "normal",
            spawnedProcessVerifier: { pid in try verifier.verify(pid: pid) }
        ))
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        try process.send(Data("{\"method\":\"ping\"}\n".utf8))

        #expect(try await iterator.next() == Data("{\"id\":1,\"result\":{}}".utf8))
        #expect(try #require(verifier.observedPID) > 0)
        await process.stop()
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test(arguments: ["hang-child", "crash-child"])
    func processGroupKillsRecordedDescendantAndCleansRoot(mode: String) async throws {
        let pidFile = repository.appendingPathComponent(".artifacts/\(mode)-pid.txt")
        try? FileManager.default.removeItem(at: pidFile)
        let process = CodexAppServerProcess(
            configuration: try configuration(mode: mode, extraArguments: [pidFile.path])
        )
        let root = process.temporaryRootURL
        _ = try process.start()
        let descendantPID = try await readPID(pidFile)
        if mode == "hang-child" { await process.stop() }
        else { await #expect(throws: LiveProcessError.helperExited) {
            try await process.waitForExit(timeout: .seconds(2))
        } }
        try await waitUntil { Darwin.kill(descendantPID, 0) != 0 && errno == ESRCH }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try? FileManager.default.removeItem(at: pidFile)
    }

    @Test
    func ownerReleaseTerminatesAndReapsProcessGroup() async throws {
        let pidFile = repository.appendingPathComponent(".artifacts/deinit-child-pid.txt")
        try? FileManager.default.removeItem(at: pidFile)
        var process: CodexAppServerProcess? = CodexAppServerProcess(
            configuration: try configuration(mode: "hang-child", extraArguments: [pidFile.path])
        )
        let root = process!.temporaryRootURL
        _ = try process!.start()
        let descendantPID = try await readPID(pidFile)
        process = nil
        try await waitUntil { Darwin.kill(descendantPID, 0) != 0 && errno == ESRCH }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try? FileManager.default.removeItem(at: pidFile)
    }

    @Test
    func timeoutAndCancellationTerminateAndClean() async throws {
        let timeout = CodexAppServerProcess(configuration: try configuration(mode: "hang"))
        _ = try timeout.start()
        await #expect(throws: LiveProcessError.timeout) {
            try await timeout.waitForExit(timeout: .milliseconds(100))
        }
        await timeout.stop()

        let cancelled = CodexAppServerProcess(configuration: try configuration(mode: "hang"))
        _ = try cancelled.start()
        cancelled.cancel()
        try await cancelled.waitForTermination(timeout: .seconds(2))
        #expect(!cancelled.isRunning)
    }

    @Test
    func cancelledStopStillWaitsForReaperBeforeReturning() async throws {
        let process = CodexAppServerProcess(configuration: try configuration(mode: "hang"))
        _ = try process.start()

        let wasRunningWhenStopReturned = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            await process.stop()
            return process.isRunning
        }.value

        #expect(!wasRunningWhenStopReturned)
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func stopReturnsAfterItsCleanupBoundWhenPrivateRootCannotBeRemoved() async throws {
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/cleanup-deadline-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent, withIntermediateDirectories: true
        )
        defer {
            _ = chmod(temporaryParent.path, 0o700)
            try? FileManager.default.removeItem(at: temporaryParent)
        }
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "hang"],
            temporaryParentURL: temporaryParent,
            terminationGrace: .milliseconds(20),
            cleanupPendingDelay: .milliseconds(20),
            cleanupDeadline: .milliseconds(100)
        ))
        _ = try process.start()
        #expect(chmod(temporaryParent.path, 0o500) == 0)

        let completion = ProcessStopCompletion()
        let stop = Task {
            let result = await process.stop()
            await completion.markComplete(result)
        }
        let bound = ContinuousClock.now.advanced(by: .milliseconds(300))
        while !(await completion.isComplete), ContinuousClock.now < bound {
            try await Task.sleep(for: .milliseconds(10))
        }

        let completedWithinBound = await completion.isComplete
        #expect(completedWithinBound)
        #expect(await completion.result == .pending)
        #expect(throws: LiveProcessError.processUnavailable) {
            _ = try process.start()
        }
        #expect(chmod(temporaryParent.path, 0o700) == 0)
        await stop.value
        #expect(!process.isRunning)
        #expect(await process.stop() == .completed)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func stopDoesNotWaitForCleanupCallbackThatNeverReturns() async throws {
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/callback-deadline-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent, withIntermediateDirectories: true
        )
        defer {
            _ = chmod(temporaryParent.path, 0o700)
            try? FileManager.default.removeItem(at: temporaryParent)
        }
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "hang"],
            temporaryParentURL: temporaryParent,
            terminationGrace: .milliseconds(20),
            cleanupPendingDelay: .milliseconds(20),
            cleanupDeadline: .milliseconds(100)
        ))
        _ = try process.start()
        #expect(chmod(temporaryParent.path, 0o500) == 0)

        let callback = NeverReturningCleanupCallback()
        let completion = ProcessStopCompletion()
        let stop = Task {
            let result = await process.stop { await callback.call() }
            await completion.markComplete(result)
        }
        let bound = ContinuousClock.now.advanced(by: .milliseconds(300))
        while !(await completion.isComplete), ContinuousClock.now < bound {
            try await Task.sleep(for: .milliseconds(10))
        }

        let completedWithinBound = await completion.isComplete
        #expect(completedWithinBound)
        #expect(await completion.result == .pending)
        let callbackBound = ContinuousClock.now.advanced(by: .milliseconds(300))
        while !(await callback.isEntered), ContinuousClock.now < callbackBound {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await callback.isEntered)
        #expect(chmod(temporaryParent.path, 0o700) == 0)
        await callback.release()
        await stop.value
        #expect(!process.isRunning)
        #expect(await process.stop() == .completed)
        #expect(!FileManager.default.fileExists(atPath: process.temporaryRootURL.path))
    }

    @Test
    func terminationNeverPublishesStoppedBeforeRootRemoval() async throws {
        for _ in 0..<20 {
            let process = CodexAppServerProcess(configuration: try configuration(mode: "hang"))
            let root = process.temporaryRootURL
            _ = try process.start()
            process.cancel()
            while process.isRunning { await Task.yield() }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test
    func operatorRequiresExternalRuntimeAndRefusesInvalidInputs() throws {
        let shippingPlistData = try Data(
            contentsOf: repository.appendingPathComponent("Packaging/Info.plist")
        )
        let shippingPlist = try #require(
            PropertyListSerialization.propertyList(
                from: shippingPlistData, options: [], format: nil
            ) as? [String: Any]
        )
        #expect(shippingPlist["MillerGPTLiveHarnessCapability"] == nil)

        let testRoot = repository.appendingPathComponent(".artifacts/operator-harness-test")
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let harness = testRoot.appendingPathComponent("Miller.app/Contents/MacOS/Miller")
        let plist = testRoot.appendingPathComponent("Miller.app/Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: harness.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try writePlist(["CFBundleIdentifier": "ai.millrace.miller"], to: plist)
        try Data("#!/bin/zsh\nexit 17\n".utf8).write(to: harness)
        #expect(chmod(harness.path, 0o700) == 0)

        let refused = try runOperator(arguments: ["--test-cleanup", "--harness", harness.path])
        #expect(refused == 64)

        try writePlist([
            "CFBundleIdentifier": "ai.millrace.miller",
            "MillerGPTLiveHarnessCapability": "miller-gpt-live-webrtc-harness-v1",
        ], to: plist)
        try Data(
            "#!/bin/zsh\nif [[ \"$1\" == \"--gpt-live-operator-cleanup-test\" ]]; then\n  print GPT_LIVE_OPERATOR_CLEANUP_OK\n  exit 0\nfi\nexit 17\n".utf8
        ).write(to: harness)
        #expect(chmod(harness.path, 0o700) == 0)
        let helper = testRoot.appendingPathComponent("synthetic-helper")
        try Data("fixture".utf8).write(to: helper)
        #expect(chmod(helper.path, 0o700) == 0)
        let dryArguments = [
            "--dry-run", "--helper", helper.path,
            "--harness", harness.path, "--minimum-free-bytes", "0",
        ]
        for mode in [
            "wrong-identifier", "wrong-team", "wrong-requirement", "wrong-arch",
            "missing-helper", "missing-harness",
            "nonexecutable-harness", "unrecognized-harness", "insufficient-space",
        ] {
            #expect(try runOperator(arguments: dryArguments + ["--simulate", mode]) == 64)
        }
        #expect(try runOperator(arguments: dryArguments) == 64)
        #expect(try runOperator(arguments: [
            "--live", "--helper", helper.path,
            "--harness", harness.path,
        ]) == 64)
        let syntheticExit = try runOperator(arguments: ["--test-cleanup", "--harness", harness.path])
        #expect(syntheticExit == 0)
        #expect(!FileManager.default.fileExists(
            atPath: repository.appendingPathComponent(".artifacts/gpt-live-app-server-check").path
        ))
    }

    @Test
    func operatorUsesOfficialOpenAIPublisherRequirementWithoutVersionOrHashPin() throws {
        let script = try String(
            contentsOf: repository.appendingPathComponent(
                "scripts/run-gpt-live-app-server-check.sh"
            ),
            encoding: .utf8
        )

        #expect(script.contains("expected_identifier=\"codex\""))
        #expect(script.contains("expected_team=\"2DC432GLL2\""))
        #expect(script.contains("certificate leaf[subject.OU] = \\\"$expected_team\\\""))
        #expect(!script.contains("expected_cdhash"))
        #expect(!script.contains("expected_version"))
        #expect(!script.contains("--metadata"))
        #expect(script.contains("@openai/codex-darwin-arm64"))
        #expect(script.contains("vendor/aarch64-apple-darwin/bin/codex"))
    }

    @Test
    func operatorRetainsCodesignRequirementOutputForValidation() throws {
        let script = try String(
            contentsOf: repository.appendingPathComponent(
                "scripts/run-gpt-live-app-server-check.sh"
            ),
            encoding: .utf8
        )

        #expect(script.contains(
            "codesign -dvvv -r- \"$helper\" > \"$codesign_detail\" 2>&1"
        ))
        #expect(script.contains("TeamIdentifier=//p"))
        #expect(!script.contains(
            "codesign -dvvv -r- \"$helper\" > /dev/null 2> \"$codesign_detail\""
        ))
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func configuration(
        mode: String,
        extraArguments: [String] = [],
        spawnedProcessVerifier: @escaping @Sendable (pid_t) throws -> Void = { _ in }
    ) throws -> CodexAppServerProcess.Configuration {
        try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, mode] + extraArguments,
            temporaryParentURL: repository.appendingPathComponent(".artifacts"),
            terminationGrace: .milliseconds(100),
            spawnedProcessVerifier: spawnedProcessVerifier
        )
    }

    private var fixture: URL {
        Bundle.module.url(
            forResource: "fake-codex-app-server",
            withExtension: "mjs",
            subdirectory: "Fixtures"
        )!
    }

    private func readPID(_ url: URL) async throws -> pid_t {
        var value: pid_t?
        try await waitUntil {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8),
                  let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return false }
            value = parsed
            return true
        }
        return try #require(value)
    }

    private func writePlist(_ value: [String: String], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value, format: .xml, options: 0
        )
        try data.write(to: url)
    }

    private func runOperator(arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [repository.appendingPathComponent("scripts/run-gpt-live-app-server-check.sh").path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func waitUntil(
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw LiveProcessError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum SpawnVerifierOutcome {
    case accept
    case reject
}

private enum SpawnVerifierError: Error {
    case rejected
}

private final class SpawnVerifierProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: SpawnVerifierOutcome
    private var pid: pid_t?

    init(outcome: SpawnVerifierOutcome) {
        self.outcome = outcome
    }

    var observedPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    func verify(pid: pid_t) throws {
        lock.lock(); defer { lock.unlock() }
        self.pid = pid
        guard outcome == .accept else { throw SpawnVerifierError.rejected }
    }
}

private actor ProcessStopCompletion {
    private(set) var isComplete = false
    private(set) var result: CodexAppServerCleanupResult?

    func markComplete(_ result: CodexAppServerCleanupResult) {
        self.result = result
        isComplete = true
    }
}

private actor NeverReturningCleanupCallback {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isEntered = false
    private var released = false

    func call() async {
        isEntered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
