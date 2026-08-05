import Foundation
import MillerCore
import MillerLive
import Security
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct CodexAppServerHelperVerifierTests {
    @Test
    func officialIdentityIsPublisherBoundWithoutACDHashPin() {
        #expect(CodexAppServerHelperInspection.expectedIdentifier == "codex")
        #expect(CodexAppServerHelperInspection.expectedTeamIdentifier == "2DC432GLL2")
        #expect(CodexAppServerHelperVerifier.executionRequirement.contains("anchor apple generic"))
        #expect(CodexAppServerHelperVerifier.executionRequirement.contains("2DC432GLL2"))
        #expect(!CodexAppServerHelperVerifier.executionRequirement.contains("cdhash"))
    }

    @Test
    func unsignedExecutableIsRejectedByTheProductionVerifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-untrusted-helper-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        #expect(chmod(helper.path, 0o700) == 0)

        #expect(throws: CodexAppServerHelperVerificationError.rejected) {
            try CodexAppServerHelperVerifier().verify(helper)
        }
    }

    @Test(arguments: CodexAppServerHelperInspection.mismatchedFixtures)
    func everyPublisherOrArchitectureMismatchFailsClosed(
        inspection: CodexAppServerHelperInspection
    ) throws {
        let verifier = CodexAppServerHelperVerifier(inspect: { _ in inspection })

        #expect(throws: CodexAppServerHelperVerificationError.rejected) {
            try verifier.verify(URL(fileURLWithPath: "/usr/bin/true"))
        }
    }

    @Test
    func exactInjectedOfficialIdentityIsAccepted() throws {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let verifier = CodexAppServerHelperVerifier(inspect: {
            .official(executableURL: $0)
        })

        try verifier.verify(executable)
    }

    @Test
    func spawnedProcessMustMatchPIDPublisherAndCanonicalExecutable() throws {
        let executable = URL(fileURLWithPath: "/private/tmp/codex")
        let probe = RunningProcessVerificationProbe(
            result: .official(executableURL: executable)
        )
        let verifier = CodexAppServerHelperVerifier(
            inspect: { .official(executableURL: $0) },
            inspectRunningProcess: { pid in try probe.inspect(pid) }
        )

        try verifier.verifyRunningProcess(pid: 4242, expectedExecutableURL: executable)

        #expect(probe.observedPID == 4242)
    }

    @Test
    func spawnedProcessPathMismatchIsRejected() {
        let expected = URL(fileURLWithPath: "/private/tmp/codex")
        let changed = URL(fileURLWithPath: "/private/tmp/substitute-codex")
        let verifier = CodexAppServerHelperVerifier(
            inspect: { .official(executableURL: $0) },
            inspectRunningProcess: { _ in .official(executableURL: changed) }
        )

        #expect(throws: CodexAppServerHelperVerificationError.rejected) {
            try verifier.verifyRunningProcess(pid: 4242, expectedExecutableURL: expected)
        }
    }

    @Test
    func installedOfficialCodexSurvivesSpawnAdmission() async throws {
        guard let path = ProcessInfo.processInfo.environment["MILLER_EXTERNAL_CODEX"] else {
            return
        }
        let executable = URL(fileURLWithPath: path)
        let verifier = CodexAppServerHelperVerifier()
        try verifier.verify(executable)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-installed-codex-admission-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: executable,
            arguments: ["app-server", "--listen", "stdio://", "--strict-config"],
            temporaryParentURL: parent,
            spawnedProcessVerifier: { pid in
                try verifier.verifyRunningProcess(
                    pid: pid,
                    expectedExecutableURL: executable
                )
            }
        ))

        _ = try process.start()
        try await Task.sleep(for: .milliseconds(250))
        #expect(process.isRunning)
        await process.stop()
    }

    @Test
    func verifiedHelperAllowsReadinessToReachTheCredentialCheck() async throws {
        let loads = CounterProbe()
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let controller = try GPTLiveController(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: FileManager.default.temporaryDirectory,
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await loads.increment()
                return envelope
            }),
            refreshCredential: {},
            microphonePermissionStatus: { .authorized },
            helperVerifier: { _ in }
        )

        #expect(await controller.availability() == .available)
        #expect(await loads.value == 1)
    }

    @Test
    func failedReverificationPrecedesCredentialAndPeerWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-helper-verifier-order-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = HelperVerifierProbe()
        let credentialLoads = CounterProbe()
        let peerFactories = CounterProbe()
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let controller = try GPTLiveController(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: root,
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await credentialLoads.increment()
                return envelope
            }),
            refreshCredential: {},
            microphonePermissionStatus: { .authorized },
            microphonePermission: { .authorized },
            makePeer: {
                await peerFactories.increment()
                throw GPTLiveCredentialError.unavailable
            },
            helperVerifier: { url in try verifier.verify(url) }
        )

        verifier.rejectNextVerification()
        await #expect(throws: CodexAppServerHelperVerificationError.rejected) {
            try await controller.start { _ in }
        }

        #expect(verifier.calls == 2)
        #expect(await credentialLoads.value == 0)
        #expect(await peerFactories.value == 0)
    }

    @Test
    func explicitDevelopmentOverrideUsesTheInjectedVerifier() throws {
        let helper = URL(fileURLWithPath: "/usr/bin/true")

        let resolved = try AppCoordinator.liveHelperURL(
            arguments: ["Miller", "--gpt-live-app-server", helper.path],
            helperVerifier: { #expect($0 == helper) }
        )

        #expect(resolved == helper)
    }
}

private extension CodexAppServerHelperInspection {
    static func official(executableURL: URL) -> Self {
        .init(
            identifier: expectedIdentifier,
            teamIdentifier: expectedTeamIdentifier,
            architecture: .arm64,
            executableURL: executableURL.resolvingSymlinksInPath()
        )
    }

    static var mismatchedFixtures: [Self] {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        var wrongIdentifier = official(executableURL: executable)
        wrongIdentifier.identifier = "synthetic.wrong"
        var wrongTeam = official(executableURL: executable)
        wrongTeam.teamIdentifier = "WRONGTEAM"
        var wrongArchitecture = official(executableURL: executable)
        wrongArchitecture.architecture = .x86_64
        return [wrongIdentifier, wrongTeam, wrongArchitecture]
    }
}

private final class HelperVerifierProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldReject = false
    private var invocationCount = 0

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return invocationCount
    }

    func rejectNextVerification() {
        lock.lock(); defer { lock.unlock() }
        shouldReject = true
    }

    func verify(_: URL) throws {
        lock.lock(); defer { lock.unlock() }
        invocationCount += 1
        guard !shouldReject else { throw CodexAppServerHelperVerificationError.rejected }
    }
}

private final class RunningProcessVerificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let result: CodexAppServerHelperInspection
    private var pid: pid_t?

    init(result: CodexAppServerHelperInspection) {
        self.result = result
    }

    var observedPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    func inspect(_ pid: pid_t) throws -> CodexAppServerHelperInspection {
        lock.lock(); defer { lock.unlock() }
        self.pid = pid
        return result
    }
}

private actor CounterProbe {
    private var count = 0

    var value: Int { count }

    func increment() { count += 1 }
}
