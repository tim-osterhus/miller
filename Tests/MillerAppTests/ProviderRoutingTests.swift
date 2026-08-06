@testable import MillerApp
import Foundation
import MillerCore
import MillerLive
import Testing

@Suite
struct ProviderRoutingTests {
    @Test
    func typedProcessUsesOnlyCompleteSecretFreeBridgeConfiguration() throws {
        let token = Data(repeating: 9, count: 32).base64EncodedString()
        let environment = [
            "MILLER_CAPABILITY_BRIDGE_PATH": "/Applications/Miller.app/Contents/MacOS/MillerCapabilityBridge",
            "MILLER_CAPABILITY_RPC_SOCKET": "/private/tmp/miller/capability.sock",
            "MILLER_CAPABILITY_RPC_TOKEN": token,
            "MILLER_CAPABILITY_PROVIDER_PROFILE_ID": UUID().uuidString,
            "MILLER_CAPABILITY_RPC_TRUSTED_PARENT": "/private/tmp/miller",
        ]
        let configuration = try AppCoordinator.typedCodexProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller"),
            environment: environment,
            spawnedProcessVerifier: { _ in }
        )
        #expect(configuration.arguments.contains {
            $0.contains("miller-capability-bridge")
        })
        #expect(configuration.arguments.contains {
            $0.contains("miller-typed-read-only")
        })
        #expect(!configuration.arguments.joined().contains(token))
        #expect(configuration.environment["MILLER_CAPABILITY_RPC_TOKEN"] == token)
        #expect(configuration.arguments.suffix(4) == [
            "app-server", "--listen", "stdio://", "--strict-config",
        ])

        let withoutBridge = try AppCoordinator.typedCodexProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller"),
            environment: [:],
            spawnedProcessVerifier: { _ in }
        )
        #expect(withoutBridge.arguments.suffix(4) == [
            "app-server", "--listen", "stdio://", "--strict-config",
        ])

        #expect(throws: (any Error).self) {
            _ = try AppCoordinator.typedCodexProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller"),
                environment: ["MILLER_CAPABILITY_RPC_TOKEN": token],
                spawnedProcessVerifier: { _ in }
            )
        }
    }

    @Test
    func routesCodexAndOpenAICompatibleProfilesToDistinctGateways() async throws {
        let codex = RoutingGatewayProbe()
        let compatible = RoutingGatewayProbe()
        let selection = ProviderKindSelection(.codexOAuth)
        let router = ProviderRoutingGateway(
            selectedKind: { await selection.value },
            codex: codex,
            openAICompatible: compatible
        )

        for try await _ in try await router.start(request()) {}
        #expect(await codex.startCount == 1)
        #expect(await compatible.startCount == 0)

        await selection.set(.openAICompatible)
        for try await _ in try await router.start(request()) {}
        #expect(await codex.startCount == 1)
        #expect(await compatible.startCount == 1)
    }

    @Test
    func locksRouteForActiveTurnAndRejectsProviderSwitch() async throws {
        let codex = RoutingGatewayProbe(holdsOpen: true)
        let compatible = RoutingGatewayProbe()
        let selection = ProviderKindSelection(.codexOAuth)
        let router = ProviderRoutingGateway(
            selectedKind: { await selection.value },
            codex: codex,
            openAICompatible: compatible
        )
        let value = request()
        let stream = try await router.start(value)
        let collector = Task {
            for try await _ in stream {}
        }
        defer { collector.cancel() }
        await selection.set(.openAICompatible)

        await #expect(throws: ProviderRoutingError.routeChangedDuringActiveTurn) {
            _ = try await router.start(request())
        }
        await router.cancel(.init(turnID: value.turnID, targetGeneration: value.generation))
        #expect(await codex.cancelCount == 1)
        #expect(await compatible.cancelCount == 0)
    }

    @Test
    func cancellationDuringProviderSelectionPreventsDownstreamStart() async throws {
        let selection = SuspendedProviderKindSelection(.codexOAuth)
        let codex = RoutingGatewayProbe()
        let router = ProviderRoutingGateway(
            selectedKind: { await selection.load() },
            codex: codex,
            openAICompatible: RoutingGatewayProbe()
        )
        let value = request()
        let start = Task { try await router.start(value) }
        try await waitUntil { await selection.entered }
        await router.cancel(.init(
            turnID: value.turnID, targetGeneration: value.generation
        ))
        await selection.release()
        await #expect(throws: CancellationError.self) { _ = try await start.value }
        #expect(await codex.startCount == 0)
    }

    @Test
    func typedCredentialRefreshInvokesProviderRefreshBeforeReloadingKeychain() async throws {
        let probe = TypedCredentialRefreshProbe()
        let refresher = CodexTypedCredentialRefresher(
            refreshSelected: { await probe.refresh() },
            loadSelected: { await probe.load() }
        )
        let replacement = try await refresher.refresh(accountID: "account-1")
        #expect(replacement.accessToken == Data("replacement".utf8))
        #expect(await probe.operations == ["refresh", "load"])
    }

    @Test
    func typedCredentialRefreshRejectsUnchangedOrWrongAccountCredential() async {
        for replacement in [
            CodexOAuthCredential(
                accessToken: Data("original".utf8), accountID: "account-1", planType: nil
            ),
            CodexOAuthCredential(
                accessToken: Data("replacement".utf8), accountID: "account-2", planType: nil
            ),
        ] {
            let refresher = CodexTypedCredentialRefresher(
                refreshSelected: {},
                loadSelected: { replacement }
            )
            await #expect(throws: (any Error).self) {
                _ = try await refresher.refresh(
                    accountID: "account-1", previousAccessToken: Data("original".utf8)
                )
            }
        }
    }

    private func request() -> ReasoningRequest {
        .init(
            conversationID: .init(), turnID: .init(), generation: 1,
            context: [], userText: "hello"
        )
    }
}

private actor SuspendedProviderKindSelection {
    private let kind: ProviderKind
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    init(_ kind: ProviderKind) { self.kind = kind }

    func load() async -> ProviderKind {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return kind
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await !predicate() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor ProviderKindSelection {
    private(set) var value: ProviderKind
    init(_ value: ProviderKind) { self.value = value }
    func set(_ value: ProviderKind) { self.value = value }
}

private actor TypedCredentialRefreshProbe {
    private(set) var operations: [String] = []

    func refresh() { operations.append("refresh") }

    func load() -> CodexOAuthCredential {
        operations.append("load")
        return .init(
            accessToken: Data("replacement".utf8),
            accountID: "account-1",
            planType: "plus"
        )
    }
}

private actor RoutingGatewayProbe: ReasoningGateway {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private let holdsOpen: Bool

    init(holdsOpen: Bool = false) { self.holdsOpen = holdsOpen }

    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        _ = request
        startCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.accepted)
            if !holdsOpen {
                continuation.yield(.completed)
                continuation.finish()
            }
        }
    }

    func cancel(_ cancellation: ReasoningCancellation) async {
        _ = cancellation
        cancelCount += 1
    }
}
