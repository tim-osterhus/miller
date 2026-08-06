import AVFoundation
import Combine
import Darwin
import Foundation
import MillerCapabilities
import MillerCore
import MillerGateway
import MillerLive
import MillerStorage

enum CapabilityControllerError: Error, Equatable {
    case unavailable
    case auditUnavailable
    case staleGeneration
    case providerMismatch
    case settingsBusy
    case serverAlreadyExists
    case serverIdentityMismatch
    case serverQualificationRequired
}

enum CapabilitySettingsMutationError: Error, Equatable {
    case secretMutationFailed
    case recoveryFailed
}

enum CapabilityInvocationRoute: Equatable, Sendable {
    case typedPi
    case typedCodex
    case gptLive
}

enum CapabilityApprovalTermination: Equatable, Sendable {
    case close
    case interrupt
    case timeout
}

struct CapabilityProviderCallbacks: Sendable {
    let activity: CodexCapabilityActivityHandler
    let approval: CodexProviderApprovalResolver
    let approvalDetails: CodexProviderApprovalDetailsResolver
}

struct CapabilityProviderCallbackAuthority: Equatable, Sendable {
    let generation: UUID
    let isVoice: Bool
}

struct CapabilityVoicePreparation: Equatable, Sendable {
    fileprivate let token: UUID
}

enum CapabilityAdapterProcessState: Equatable, Sendable {
    case unavailable
    case noReachableLeasePID
    case leasePIDAliveUnverified

    var diagnosticsLabel: String {
        switch self {
        case .unavailable: "Unavailable"
        case .noReachableLeasePID: "No reachable lease PID"
        case .leasePIDAliveUnverified: "Lease PID alive (identity unverified)"
        }
    }
}

struct CapabilityControllerDiagnostics: Equatable, Sendable {
    let controllerState: String
    let broker: CapabilityBrokerLifecycleSnapshot?
    let bridgeRPCServerRunning: Bool
    let adapterProcessState: CapabilityAdapterProcessState
    let sanitizedLastFailure: String?
}

@MainActor
private final class CapabilityConfirmationSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func announce(_ message: String) {
        synthesizer.speak(AVSpeechUtterance(string: message))
    }
}

enum CapabilityAssociation: Equatable, Sendable {
    case typed(
        conversationID: ConversationID,
        turnID: TurnID,
        generation: Int
    )
    case voice(sessionID: UUID, generation: Int)

    var generation: Int {
        switch self {
        case .typed(_, _, let generation), .voice(_, let generation): generation
        }
    }

    var conversationID: ConversationID? {
        if case .typed(let value, _, _) = self { return value }
        return nil
    }

    var turnID: TurnID? {
        if case .typed(_, let value, _) = self { return value }
        return nil
    }

    var voiceSessionID: UUID? {
        if case .voice(let value, _) = self { return value }
        return nil
    }

    var isVoice: Bool {
        if case .voice = self { return true }
        return false
    }
}

struct CapabilityRuntimeConfiguration: Sendable {
    let servers: [MCPServerConfiguration]
    let toolPolicies: [CapabilityID: CapabilityPolicy]

    init(
        servers: [MCPServerConfiguration],
        toolPolicies: [CapabilityID: CapabilityPolicy]
    ) {
        self.servers = servers
        self.toolPolicies = toolPolicies
    }
}

struct CapabilityPersistenceDependencies: Sendable {
    let loadOpenAudits: @Sendable () async throws -> [CapabilityAuditRecord]
    let beginAudit: @Sendable (CapabilityAuditRecord) async throws -> Void
    let requireApproval: @Sendable (
        CapabilityCallID,
        CapabilityPolicy
    ) async throws -> Void
    let terminalizeAudit: @Sendable (
        CapabilityCallID,
        CapabilityTerminalOutcome,
        CapabilityApprovalDecision?
    ) async throws -> Void

    static let unavailable = Self(
        loadOpenAudits: { [] },
        beginAudit: { _ in },
        requireApproval: { _, _ in },
        terminalizeAudit: { _, _, _ in }
    )
}

struct CapabilitySettingsSecretDependencies: Sendable {
    let load: @Sendable (UUID) async throws -> String?
    let store: @Sendable (UUID, String) async throws -> Void
    let delete: @Sendable (UUID) async throws -> Void

    static let unavailable = Self(
        load: { _ in nil },
        store: { _, _ in throw CapabilityControllerError.unavailable },
        delete: { _ in throw CapabilityControllerError.unavailable }
    )
}

struct CapabilityProviderProjectionDependencies: Sendable {
    let selectedProfile: @Sendable () async throws -> ProviderProfile?
    let inventory: @Sendable (
        ProviderProfile,
        [CapabilityDescriptor]
    ) async throws -> CapabilityCatalogSnapshot
}

struct CapabilityApprovalPresentation: Identifiable, Equatable, Sendable {
    let callID: CapabilityCallID
    let origin: String
    let server: String
    let tool: String
    let intent: String
    let policy: CapabilityPolicy
    let requiresVisualConfirmation: Bool
    let canAllowOnce: Bool

    var id: UUID { callID.rawValue }

    init(
        callID: CapabilityCallID,
        origin: String,
        server: String,
        tool: String,
        intent: String,
        policy: CapabilityPolicy,
        requiresVisualConfirmation: Bool,
        canAllowOnce: Bool = true
    ) {
        self.callID = callID
        self.origin = Self.bound(origin, bytes: 128)
        self.server = Self.bound(server, bytes: 128)
        self.tool = Self.bound(tool, bytes: 256)
        self.intent = Self.bound(intent, bytes: 1_024)
        self.policy = policy
        self.requiresVisualConfirmation = requiresVisualConfirmation
        self.canAllowOnce = canAllowOnce
    }

    private static func bound(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        var result = ""
        for scalar in value.unicodeScalars {
            let next = result + String(scalar)
            guard next.utf8.count <= bytes else { break }
            result = next
        }
        return result
    }
}

struct CapabilityActivityRow: Identifiable, Equatable, Sendable {
    let callID: CapabilityCallID
    let origin: String
    let server: String
    let tool: String
    let outcome: CapabilityTerminalOutcome

    var id: UUID { callID.rawValue }

    var status: String {
        switch outcome {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .declined: "Declined"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        }
    }

    var displayText: String {
        "\(Self.bound(origin, bytes: 128)) · "
            + "\(Self.bound(server, bytes: 128)) · "
            + "\(Self.bound(tool, bytes: 256)) — \(status)"
    }

    private static func bound(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        var result = ""
        for scalar in value.unicodeScalars {
            let next = result + String(scalar)
            guard next.utf8.count <= bytes else { break }
            result = next
        }
        return result
    }
}

final class CapabilityBridgeSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private let executableURL: URL
    private var endpoint: CapabilityRPCEndpoint?
    private var providerProfileID: UUID?
    private var descriptors: [CapabilityDescriptor] = []

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func install(
        endpoint: CapabilityRPCEndpoint,
        providerProfileID: UUID,
        descriptors: [CapabilityDescriptor]
    ) {
        lock.lock(); defer { lock.unlock() }
        self.endpoint = endpoint
        self.providerProfileID = providerProfileID
        self.descriptors = Array(descriptors.prefix(2_048))
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        endpoint = nil
        providerProfileID = nil
        descriptors = []
    }

    func configuration() throws -> CodexMCPBridgeConfiguration? {
        lock.lock(); defer { lock.unlock() }
        guard let endpoint, let providerProfileID else { return nil }
        return try CodexMCPBridgeConfiguration(
            executableURL: executableURL,
            socketPath: endpoint.socketURL.path,
            sessionToken: endpoint.token.environmentValue,
            providerProfileID: providerProfileID,
            trustedParentPath: endpoint.trustedParentURL.path
        )
    }

    func catalog() -> [CapabilityDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return descriptors
    }
}

final class CapabilityProviderCallbackAuthorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var authority: CapabilityProviderCallbackAuthority?

    func install(_ authority: CapabilityProviderCallbackAuthority) {
        lock.lock(); defer { lock.unlock() }
        self.authority = authority
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        authority = nil
    }

    func current() -> CapabilityProviderCallbackAuthority? {
        lock.lock(); defer { lock.unlock() }
        return authority
    }
}

@MainActor
final class CapabilityController: ObservableObject {
    private struct CallContext {
        let association: CapabilityAssociation
        let descriptor: CapabilityDescriptor
        let visibility: CapabilityAuditVisibility
    }

    private struct PendingApproval {
        let request: CapabilityApprovalRequest
        let presentation: CapabilityApprovalPresentation
        let continuation: CheckedContinuation<CapabilityApprovalDecision, Never>
        let timeout: Task<Void, Never>
    }

    private enum StoredSecret {
        case absent
        case value(String)
    }

    private enum PreparationKind: Equatable {
        case typed(turnID: TurnID, generation: Int)
        case voice
    }

    private struct PreparationReservation: Equatable {
        let token: UUID
        let kind: PreparationKind
    }

    private struct StartupReservation: Equatable {
        let generation: UInt64
    }

    @Published private(set) var pendingApproval: CapabilityApprovalPresentation?
    @Published private(set) var activityRows: [CapabilityActivityRow] = []
    @Published private(set) var liveVoiceConfirmationMessage: String?

    var pendingApprovalCount: Int {
        (activePending == nil ? 0 : 1) + pendingQueue.count
    }

    private let loadConfiguration:
        @Sendable () async throws -> CapabilityRuntimeConfiguration
    private let credentialResolver: MCPCredentialResolver
    private let sessionFactory: MCPClientSessionFactory?
    private let persistence: CapabilityPersistenceDependencies
    private let approvalTimeout: Duration
    private let trustedParent: URL?
    private let bridgeBox: CapabilityBridgeSessionBox?
    private let providerCallbackAuthorityBox:
        CapabilityProviderCallbackAuthorityBox?
    private let confirmationAnnouncer: @MainActor @Sendable (String) -> Void
    private let settingsRepository: SQLiteCapabilityRepository?
    private let settingsSecrets: CapabilitySettingsSecretDependencies

    private var broker: CapabilityBroker?
    private var descriptors: [CapabilityID: CapabilityDescriptor] = [:]
    private var serverDisplayNames: [String: String] = [:]
    private var serverPolicies: [String: CapabilityPolicy] = [:]
    private var toolPolicies: [CapabilityID: CapabilityPolicy] = [:]
    private var providerDescriptors: [CapabilityID: CapabilityDescriptor] = [:]
    private var providerProjection: CapabilityProviderProjectionDependencies?
    private var providerProjectionGeneration: UInt64 = 0
    private var startupError: Error?
    private var sanitizedLastFailure: String?
    private var pendingQueue: [PendingApproval] = []
    private var activePending: PendingApproval?
    private var approvalDecisions: [CapabilityCallID: CapabilityApprovalDecision] = [:]
    private var callContexts: [CapabilityCallID: CallContext] = [:]
    private var begunAuditIDs = Set<CapabilityCallID>()
    private var terminalAuditIDs = Set<CapabilityCallID>()
    private var pendingTerminalAudits: [CapabilityCallID: CapabilityLifecycleEvent] = [:]
    private var pendingApprovalUpgrades: [CapabilityCallID: CapabilityPolicy] = [:]
    private var activeTypedAssociation: CapabilityAssociation?
    private var activeVoiceAssociation: CapabilityAssociation?
    private var activeProviderProfileID: UUID?
    private var activeProviderCallbackAuthority: CapabilityProviderCallbackAuthority?
    private var cancelledTypedGenerations = Set<String>()
    private var cancelledTypedGenerationOrder: [String] = []
    private var cancelledVoiceSessionIDs = Set<UUID>()
    private var cancelledVoiceSessionOrder: [UUID] = []
    private var rpcServer: CapabilityRPCServer?
    private var rpcEndpoint: CapabilityRPCEndpoint?
    private var rpcTasks: [CapabilityCallID: Task<SanitizedCapabilityResult, Error>] = [:]
    private var eventEmitters: [CapabilityCallID: @Sendable (ReasoningEvent) async -> Void] = [:]
    private var providerCallIDs: [String: CapabilityCallID] = [:]
    private var providerCallPolicies: [CapabilityCallID: EffectiveCapabilityPolicy] = [:]
    private var providerCallStartedAt: [CapabilityCallID: Date] = [:]
    private var approvalCanAllowOnce: [CapabilityCallID: Bool] = [:]
    private var completedProviderCallKeys = Set<String>()
    @Published private(set) var settingsMutationInProgress = false
    @Published private(set) var settingsBusy = false
    private var settingsMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var maintenanceOwner: UUID?
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparationReservation: PreparationReservation?
    private var startupGeneration: UInt64 = 0
    private var startupReservation: StartupReservation?
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []

    private var maintenanceInProgress: Bool { maintenanceOwner != nil }

    init(
        loadConfiguration: @escaping @Sendable () async throws
            -> CapabilityRuntimeConfiguration,
        credentialResolver: @escaping MCPCredentialResolver = { _ in
            throw CapabilityControllerError.unavailable
        },
        sessionFactory: MCPClientSessionFactory? = nil,
        persistence: CapabilityPersistenceDependencies = .unavailable,
        approvalTimeout: Duration = .seconds(60),
        trustedParent: URL? = nil,
        bridgeBox: CapabilityBridgeSessionBox? = nil,
        providerCallbackAuthorityBox:
            CapabilityProviderCallbackAuthorityBox? = nil,
        settingsRepository: SQLiteCapabilityRepository? = nil,
        settingsSecrets: CapabilitySettingsSecretDependencies = .unavailable,
        confirmationAnnouncer: @escaping @MainActor @Sendable (String) -> Void = {
            _ in
        }
    ) {
        self.loadConfiguration = loadConfiguration
        self.credentialResolver = credentialResolver
        self.sessionFactory = sessionFactory
        self.persistence = persistence
        self.approvalTimeout = approvalTimeout
        self.trustedParent = trustedParent
        self.bridgeBox = bridgeBox
        self.providerCallbackAuthorityBox = providerCallbackAuthorityBox
        self.settingsRepository = settingsRepository
        self.settingsSecrets = settingsSecrets
        self.confirmationAnnouncer = confirmationAnnouncer
    }

    convenience init(
        databasePath: String,
        credentialStore: KeychainCredentialStore,
        trustedParent: URL? = nil,
        bridgeBox: CapabilityBridgeSessionBox? = nil,
        providerCallbackAuthorityBox:
            CapabilityProviderCallbackAuthorityBox? = nil
    ) throws {
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let confirmationSpeaker = CapabilityConfirmationSpeaker()
        self.init(
            loadConfiguration: { [repository] in
                try await Self.runtimeConfiguration(repository: repository)
            },
            credentialResolver: { [credentialStore] reference in
                let envelope = try await credentialStore.load(for: reference)
                guard let value = String(data: envelope.payload, encoding: .utf8),
                      !value.isEmpty, value.utf8.count <= 65_536,
                      !value.contains("\0")
                else { throw CapabilityControllerError.unavailable }
                return value
            },
            persistence: CapabilityPersistenceDependencies(
                loadOpenAudits: { [repository] in
                    try await repository.audits().filter {
                        $0.terminalOutcome == nil
                    }
                },
                beginAudit: { [repository] record in
                    try await repository.beginAudit(record)
                },
                requireApproval: { [repository] id, policy in
                    try await repository.requireAuditApproval(
                        id: id,
                        effectivePolicy: policy
                    )
                },
                terminalizeAudit: { [repository] id, outcome, decision in
                    try await repository.terminalizeAudit(
                        id: id,
                        outcome: outcome,
                        approvalDecision: decision
                    )
                }
            ),
            trustedParent: trustedParent,
            bridgeBox: bridgeBox,
            providerCallbackAuthorityBox: providerCallbackAuthorityBox,
            settingsRepository: repository,
            settingsSecrets: CapabilitySettingsSecretDependencies(
                load: { [credentialStore] reference in
                    do {
                        let envelope = try await credentialStore.load(for: reference)
                        guard let value = String(data: envelope.payload, encoding: .utf8),
                              !value.isEmpty, value.utf8.count <= 65_536,
                              !value.contains("\0")
                        else { throw CapabilitySettingsMutationError.secretMutationFailed }
                        return value
                    } catch CredentialError.itemNotFound {
                        return nil
                    }
                },
                store: { [credentialStore] reference, value in
                    guard let payload = value.data(using: .utf8), !payload.isEmpty,
                          payload.count <= 65_536, !value.contains("\0")
                    else { throw CapabilitySettingsMutationError.secretMutationFailed }
                    try await credentialStore.store(
                        try CredentialEnvelope(
                            providerKind: .openAICompatible,
                            payload: payload
                        ),
                        for: reference
                    )
                },
                delete: { [credentialStore] reference in
                    do {
                        try await credentialStore.delete(for: reference)
                    } catch CredentialError.itemNotFound {
                        return
                    }
                }
            ),
            confirmationAnnouncer: { [confirmationSpeaker] message in
                confirmationSpeaker.announce(message)
            }
        )
    }

    func start() async {
        await start(allowDuringAuthorityMutation: false)
    }

    private func start(allowDuringAuthorityMutation: Bool) async {
        guard broker == nil, startupError == nil else { return }
        if startupReservation != nil {
            await waitForStartup()
            return
        }
        guard allowDuringAuthorityMutation
                || (!settingsMutationInProgress && !maintenanceInProgress)
        else { return }
        startupGeneration &+= 1
        let reservation = StartupReservation(generation: startupGeneration)
        startupReservation = reservation
        await performStartup(reservation)
        finishStartup(reservation)
    }

    private func performStartup(_ reservation: StartupReservation) async {
        var candidate: CapabilityBroker?
        do {
            let configuration = try await loadConfiguration()
            try await recoverDurableNonterminalAudits()
            let built = try CapabilityBroker(
                configurations: configuration.servers,
                toolPolicies: configuration.toolPolicies,
                credentialResolver: credentialResolver,
                sessionFactory: sessionFactory,
                approval: { [weak self] request in
                    guard let self else { return .decline }
                    return await self.requestApproval(request)
                },
                audit: { [weak self] event in
                    await self?.recordLifecycle(event)
                }
            )
            candidate = built
            let catalog = await built.refresh()
            if let settingsRepository {
                try await Self.persist(
                    catalog: catalog,
                    repository: settingsRepository,
                    serverIDs: Set(configuration.servers.map(\.id)),
                    attemptedServerIDs: Set(configuration.servers.compactMap {
                        $0.enabled && !$0.providerProfileIDs.isEmpty ? $0.id : nil
                    })
                )
            }
            guard startupReservation == reservation,
                  startupGeneration == reservation.generation
            else {
                await built.disconnectAll()
                return
            }
            broker = built
            serverDisplayNames = Dictionary(
                uniqueKeysWithValues: configuration.servers.map {
                    ($0.id, $0.displayName)
                }
            )
            serverPolicies = Dictionary(
                uniqueKeysWithValues: configuration.servers.map {
                    ($0.id, $0.defaultPolicy)
                }
            )
            toolPolicies = configuration.toolPolicies
            descriptors = Dictionary(
                uniqueKeysWithValues: catalog.descriptors.map { ($0.id, $0) }
            )
            sanitizedLastFailure = catalog.staleServerIDs.isEmpty
                ? nil : "capability_broker_failed"
        } catch {
            await candidate?.disconnectAll()
            guard startupReservation == reservation,
                  startupGeneration == reservation.generation
            else { return }
            descriptors.removeAll()
            startupError = error
            sanitizedLastFailure = "capability_startup_failed"
        }
    }

    private func waitForStartup() async {
        guard startupReservation != nil else { return }
        await withCheckedContinuation { continuation in
            guard startupReservation != nil else {
                continuation.resume()
                return
            }
            startupWaiters.append(continuation)
        }
    }

    private func finishStartup(_ reservation: StartupReservation) {
        guard startupReservation == reservation else { return }
        startupReservation = nil
        let waiters = startupWaiters
        startupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func recoverDurableNonterminalAudits() async throws {
        for audit in try await persistence.loadOpenAudits() {
            try await persistence.terminalizeAudit(
                audit.id,
                .cancelled,
                nil
            )
        }
    }

    func shutdown() async {
        while maintenanceInProgress {
            await waitForMaintenance()
        }
        let owner = UUID()
        maintenanceOwner = owner
        settingsBusy = true
        await waitForSettingsMutation()
        if startupReservation != nil {
            startupGeneration &+= 1
        }
        await waitForStartup()
        await shutdownRuntime()
        finishMaintenance(owner: owner)
    }

    private func shutdownRuntime() async {
        preparationReservation = nil
        declinePendingApprovals(for: .interrupt)
        await finalizeProviderActivities()
        await recoverPendingTerminalAuditsBestEffort()
        retainOnlyUndurableProviderActivityAuthority()
        rpcTasks.removeAll()
        eventEmitters.removeAll()
        await stopBridge()
        activeProviderProfileID = nil
        await broker?.disconnectAll()
    }

    func performManagedReset(
        _ operation: @escaping @Sendable () async -> ResetResult
    ) async -> ResetResult {
        guard !maintenanceInProgress, runtimeAuthorityIsIdle else {
            return ResetResult(roots: [
                .init(root: "capabilities.runtime_idle", succeeded: false),
            ])
        }
        let owner = UUID()
        maintenanceOwner = owner
        settingsBusy = true
        await waitForSettingsMutation()
        await shutdownRuntime()
        activityRows.removeAll()
        liveVoiceConfirmationMessage = nil
        await settingsRepository?.close()
        var roots = await operation().roots
        do {
            guard let settingsRepository else {
                throw CapabilityControllerError.unavailable
            }
            try await settingsRepository.reopen()
            try await reloadRuntimeAuthority()
            roots.append(.init(root: "sqlite.capabilities.reopen", succeeded: true))
        } catch {
            roots.append(.init(root: "sqlite.capabilities.reopen", succeeded: false))
        }
        finishMaintenance(owner: owner)
        return ResetResult(roots: roots)
    }

    private var runtimeAuthorityIsIdle: Bool {
        startupReservation == nil
            && preparationReservation == nil
            && activeTypedAssociation == nil
            && activeVoiceAssociation == nil
            && pendingApprovalCount == 0
            && rpcTasks.isEmpty
            && callContexts.isEmpty
            && pendingTerminalAudits.isEmpty
            && begunAuditIDs.isEmpty
            && providerCallIDs.isEmpty
            && providerCallPolicies.isEmpty
            && providerCallStartedAt.isEmpty
    }

    private func waitForMaintenance() async {
        guard maintenanceInProgress else { return }
        await withCheckedContinuation { continuation in
            maintenanceWaiters.append(continuation)
        }
    }

    private func finishMaintenance(owner: UUID) {
        guard maintenanceOwner == owner else { return }
        maintenanceOwner = nil
        settingsBusy = settingsMutationInProgress
        let waiters = maintenanceWaiters
        maintenanceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func catalog(providerProfileID: UUID) async -> CapabilityCatalogSnapshot {
        await start()
        let local = await broker?.catalog(providerProfileID: providerProfileID) ?? []
        let provider = providerDescriptors.values.filter {
            $0.isAvailable(to: providerProfileID)
        }
        return (try? CapabilityCatalogSnapshot(
            Array((local + provider).prefix(2_048))
        )) ?? .empty
    }

    func execute(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        argumentsJSON: Data,
        providerProfileID: UUID,
        association: CapabilityAssociation,
        route _: CapabilityInvocationRoute
    ) async throws -> SanitizedCapabilityResult {
        await start()
        try await recoverPendingTerminalAudits()
        guard !isCancelled(association), let broker else {
            throw isCancelled(association)
                ? CapabilityControllerError.staleGeneration
                : CapabilityControllerError.unavailable
        }
        let available = await broker.catalog(providerProfileID: providerProfileID)
        guard let descriptor = available.first(where: { $0.id == capabilityID })
        else { throw CapabilityBrokerError.capabilityUnavailable }
        callContexts[callID] = CallContext(
            association: association,
            descriptor: descriptor,
            visibility: .complete
        )
        do {
            try await persistBeginAudit(
                callID: callID,
                context: callContexts[callID]!,
                policy: effectivePolicy(for: descriptor)
            )
        } catch {
            releaseCallState(callID)
            throw CapabilityControllerError.auditUnavailable
        }
        let result: Result<SanitizedCapabilityResult, Error>
        do {
            result = .success(try await broker.call(
                callID: callID,
                capabilityID: capabilityID,
                argumentsJSON: argumentsJSON,
                providerProfileID: providerProfileID
            ))
        } catch {
            result = .failure(error)
        }
        if pendingTerminalAudits[callID] == nil,
           !terminalAuditIDs.contains(callID),
           let event = try? CapabilityLifecycleEvent(
               callID: callID,
               capabilityID: descriptor.id,
               summary: CapabilitySummary(text: "Capability call ended"),
               state: .terminal,
               outcome: Self.terminalOutcome(for: result),
               policy: effectivePolicy(for: descriptor)
           ) {
            await recordLifecycle(event)
        }
        do {
            try await settleTerminalAudit(callID)
        } catch {
            throw CapabilityControllerError.auditUnavailable
        }
        releaseCallState(callID)
        return try result.get()
    }

    func handlePiToolCall(
        _ call: GatewayToolCall,
        emit: @escaping @Sendable (ReasoningEvent) async -> Void
    ) async throws -> GatewayToolResult {
        guard case .typed(_, let turnID, let generation)? = activeTypedAssociation,
              turnID == call.turnID, generation == call.generation,
              let providerProfileID = activeProviderProfileID
        else { throw CapabilityControllerError.staleGeneration }
        eventEmitters[call.callID] = emit
        defer { eventEmitters[call.callID] = nil }
        do {
            let result = try await execute(
                callID: call.callID,
                capabilityID: call.capabilityID,
                argumentsJSON: call.argumentsJSON,
                providerProfileID: providerProfileID,
                association: activeTypedAssociation!,
                route: .typedPi
            )
            return try GatewayToolResult(
                outcome: result.isError ? .failed : .succeeded,
                contentJSON: result.contentJSON
            )
        } catch CapabilityBrokerError.declined {
            return try GatewayToolResult(outcome: .declined)
        } catch CapabilityBrokerError.timedOut {
            return try GatewayToolResult(outcome: .timedOut)
        } catch is CancellationError {
            return try GatewayToolResult(outcome: .cancelled)
        } catch {
            return try GatewayToolResult(
                outcome: .failed,
                contentJSON: Data(#"{"error":"tool_execution_failed"}"#.utf8)
            )
        }
    }

    func admitTypedAssociation(
        _ association: CapabilityAssociation,
        providerProfileID: UUID
    ) throws {
        guard !settingsMutationInProgress, !maintenanceInProgress else {
            throw CapabilityControllerError.settingsBusy
        }
        activeTypedAssociation = association
        activeProviderProfileID = providerProfileID
    }

    func cancelTypedAssociation(turnID: TurnID, generation: Int) async {
        releasePreparation(kind: .typed(turnID: turnID, generation: generation))
        markTypedGenerationCancelled(Self.typedKey(turnID, generation))
        if case .typed(_, let activeTurn, let activeGeneration) = activeTypedAssociation,
           activeTurn == turnID, activeGeneration == generation {
            activeTypedAssociation = nil
        }
        declinePendingApprovals(for: .interrupt)
        await finalizeProviderActivities()
        await stopBridge()
    }

    func finishTypedAssociation(turnID: TurnID, generation: Int) async {
        releasePreparation(kind: .typed(turnID: turnID, generation: generation))
        if case .typed(_, let activeTurn, let activeGeneration) = activeTypedAssociation,
           activeTurn == turnID, activeGeneration == generation {
            activeTypedAssociation = nil
        }
        await finalizeProviderActivities()
        await stopBridge()
    }

    func admitVoiceAssociation(
        sessionID: UUID,
        preparation: CapabilityVoicePreparation
    ) throws {
        guard !settingsMutationInProgress, !maintenanceInProgress else {
            throw CapabilityControllerError.settingsBusy
        }
        let reservation = PreparationReservation(
            token: preparation.token,
            kind: .voice
        )
        try validatePreparation(reservation)
        activeVoiceAssociation = .voice(sessionID: sessionID, generation: 1)
        releasePreparation(reservation)
    }

    func prepareLiveVoice(
        providerProfileID: UUID
    ) async throws -> CapabilityVoicePreparation {
        let reservation = try beginPreparation(kind: .voice)
        do {
            await finalizeProviderActivities()
            try Task.checkCancellation()
            try validatePreparation(reservation)
            activeProviderProfileID = providerProfileID
            try await prepareBridge(
                providerProfileID: providerProfileID,
                isVoice: true
            )
            try Task.checkCancellation()
            try validatePreparation(reservation)
            return CapabilityVoicePreparation(token: reservation.token)
        } catch {
            releasePreparation(reservation)
            throw error
        }
    }

    func finishLiveVoice() async {
        releasePreparation(kind: .voice)
        declinePendingApprovals(for: .close)
        activeVoiceAssociation = nil
        await finalizeProviderActivities()
        await stopBridge()
    }

    func resolveProviderApproval(
        _ request: CapabilityApprovalRequest,
        association: CapabilityAssociation? = nil
    ) async -> CapabilityApprovalDecision {
        let resolvedAssociation = association
            ?? activeVoiceAssociation ?? activeTypedAssociation
        guard let resolvedAssociation,
              !isCancelled(resolvedAssociation)
        else { return .decline }
        do {
            try await recoverPendingTerminalAudits()
        } catch {
            return .decline
        }
        let ownsTemporaryContext = callContexts[request.callID] == nil
        if ownsTemporaryContext,
           let descriptor = descriptor(for: request.capabilityID)
                ?? Self.fallbackDescriptor(request.capabilityID) {
            callContexts[request.callID] = CallContext(
                association: resolvedAssociation,
                descriptor: descriptor,
                visibility: .opaqueProviderActivity
            )
        }
        let decision = await requestApproval(request)
        if ownsTemporaryContext { releaseCallState(request.callID) }
        return decision
    }

    func resolveProviderApproval(
        _ approval: CodexProviderApproval
    ) async -> CapabilityApprovalDecision {
        guard let association = activeVoiceAssociation ?? activeTypedAssociation
        else { return .decline }
        return await resolveProviderApproval(approval, association: association)
    }

    private func resolveProviderApproval(
        _ approval: CodexProviderApproval,
        association: CapabilityAssociation
    ) async -> CapabilityApprovalDecision {
        guard !isCancelled(association)
        else { return .decline }
        do {
            try await recoverPendingTerminalAudits()
        } catch {
            return .decline
        }
        let key = providerCallKey(
            threadID: approval.threadID,
            itemID: approval.itemID
        )
        guard !completedProviderCallKeys.contains(key) else { return .decline }
        let callID = providerCallIDs[key] ?? approval.request.callID
        providerCallIDs[key] = callID
        let request: CapabilityApprovalRequest
        do {
            request = try CapabilityApprovalRequest(
                callID: callID,
                capabilityID: approval.request.capabilityID,
                summary: approval.request.summary,
                policy: approval.request.policy
            )
        } catch {
            return .decline
        }
        if callContexts[callID] == nil,
           let descriptor = descriptor(for: request.capabilityID)
                ?? Self.fallbackDescriptor(request.capabilityID) {
            callContexts[callID] = CallContext(
                association: association,
                descriptor: descriptor,
                visibility: .opaqueProviderActivity
            )
        }
        providerCallPolicies[callID] = request.policy
        approvalCanAllowOnce[callID] = approval.availableDecisions.contains("accept")
        if begunAuditIDs.contains(callID) {
            do {
                try await persistence.requireApproval(
                    callID,
                    request.policy.value
                )
            } catch {
                pendingApprovalUpgrades[callID] = request.policy.value
                approvalDecisions[callID] = .decline
                if let event = try? CapabilityLifecycleEvent(
                    callID: callID,
                    capabilityID: request.capabilityID,
                    summary: request.summary,
                    state: .terminal,
                    outcome: .declined,
                    policy: request.policy
                ) {
                    await recordLifecycle(event)
                }
                return .decline
            }
        }
        let decision = await requestApproval(request)
        if decision == .allowOnce, let context = callContexts[callID] {
            do {
                try await persistBeginAudit(
                    callID: callID,
                    context: context,
                    policy: request.policy
                )
            } catch {
                approvalDecisions[callID] = .decline
                if let event = try? CapabilityLifecycleEvent(
                    callID: callID,
                    capabilityID: request.capabilityID,
                    summary: request.summary,
                    state: .terminal,
                    outcome: .declined,
                    policy: request.policy
                ) {
                    await recordLifecycle(event)
                    if terminalAuditIDs.contains(callID) {
                        completedProviderCallKeys.insert(key)
                        releaseCallState(callID)
                    }
                }
                return .decline
            }
        }
        if decision == .decline,
           let event = try? CapabilityLifecycleEvent(
                callID: callID,
                capabilityID: request.capabilityID,
                summary: request.summary,
                state: .terminal,
                outcome: .declined,
                policy: request.policy
           ) {
            await recordLifecycle(event)
            if terminalAuditIDs.contains(callID) {
                completedProviderCallKeys.insert(key)
                releaseCallState(callID)
            }
        }
        return decision
    }

    func recordProviderActivity(_ activity: CodexCapabilityActivity) async {
        guard let association = activeVoiceAssociation ?? activeTypedAssociation
        else { return }
        await recordProviderActivity(activity, association: association)
    }

    private func recordProviderActivity(
        _ activity: CodexCapabilityActivity,
        association: CapabilityAssociation
    ) async {
        let key = providerCallKey(
            threadID: activity.threadID,
            itemID: activity.itemID
        )
        guard !completedProviderCallKeys.contains(key) else { return }
        let callID = providerCallID(threadID: activity.threadID, itemID: activity.itemID)
        if providerCallStartedAt[callID] == nil {
            providerCallStartedAt[callID] = Date()
        }
        if callContexts[callID] == nil {
            let descriptor = descriptor(for: activity.capabilityID)
                ?? Self.fallbackDescriptor(activity.capabilityID)
            if let descriptor {
                callContexts[callID] = CallContext(
                    association: association,
                    descriptor: descriptor,
                    visibility: .opaqueProviderActivity
                )
            }
        }
        let policy = providerCallPolicies[callID] ?? Self.providerPolicy()
        let event = try? CapabilityLifecycleEvent(
            callID: callID,
            capabilityID: activity.capabilityID,
            summary: activity.summary,
            state: activity.phase == .terminal ? .terminal : .running,
            outcome: activity.outcome,
            policy: policy
        )
        if let event {
            await recordLifecycle(event)
        }
        if activity.phase == .terminal, terminalAuditIDs.contains(callID) {
            completedProviderCallKeys.insert(key)
            releaseCallState(callID)
        }
    }

    func replaceProviderCatalog(_ snapshot: CapabilityCatalogSnapshot) {
        providerDescriptors = Dictionary(
            uniqueKeysWithValues: snapshot.descriptors.map { ($0.id, $0) }
        )
    }

    func settingsSnapshot(
        providerNames: [UUID: String]
    ) async throws -> CapabilitySettingsSnapshot {
        guard let repository = settingsRepository else {
            throw CapabilityControllerError.unavailable
        }
        let serverRecords = try await repository.servers()
        var serverSnapshots: [MCPServerSettingsSnapshot] = []
        for server in serverRecords {
            let enabledIDs = Set(
                try await repository.enabledProviderProfileIDs(serverID: server.id)
            )
            let enabledNames = providerNames.filter { enabledIDs.contains($0.key) }
            let tools = try await repository.catalog(serverID: server.id).map {
                CapabilitySettingsTool(record: $0, providerNames: providerNames)
            }
            serverSnapshots.append(.init(
                server: server,
                providerNames: enabledNames,
                tools: tools,
                secretBindings: try await repository.secretBindings(
                    serverID: server.id
                )
            ))
        }

        let codexTools = providerDescriptors.values
            .filter { $0.source == .codexAccount }
            .sorted { $0.id.description < $1.id.description }
        let appGroups = Dictionary(grouping: codexTools, by: \.serverID)
        let apps = appGroups.keys.sorted().map { serverID in
                CodexAccountAppSettings(
                    id: serverID,
                    displayName: serverID.replacingOccurrences(
                        of: "_", with: " "
                    ).capitalized,
                    tools: (appGroups[serverID] ?? []).map { descriptor in
                        let record = CapabilityToolRecord(
                            descriptor: descriptor,
                            staleState: .current,
                            policyOverride: nil,
                            reconciledAt: Date()
                        )
                        return CapabilitySettingsTool(
                            record: record,
                            providerNames: providerNames,
                            providerMandatedApproval:
                                descriptor.visibility == .providerManaged
                        )
                    }
                )
            }
        return CapabilitySettingsSnapshot(
            codexApps: apps,
            servers: serverSnapshots,
            providerNames: providerNames
        )
    }

    func diagnosticsSnapshot() async -> CapabilityControllerDiagnostics {
        let adapterState = trustedParent.map(Self.adapterProcessState)
            ?? .unavailable
        if trustedParent != nil, adapterState == .noReachableLeasePID {
            if sanitizedLastFailure == nil {
                sanitizedLastFailure = "capability_adapter_failed"
            }
        } else if sanitizedLastFailure == "capability_adapter_failed" {
            sanitizedLastFailure = nil
        }
        return CapabilityControllerDiagnostics(
            controllerState: startupError == nil
                ? (broker == nil ? "Not started" : "Ready")
                : "Unavailable",
            broker: await broker?.lifecycleSnapshot(),
            bridgeRPCServerRunning: rpcServer != nil,
            adapterProcessState: adapterState,
            sanitizedLastFailure: sanitizedLastFailure
        )
    }

    func saveServerSettings(_ draft: MCPServerValidatedDraft) async throws {
        var succeeded = false
        defer {
            if !succeeded {
                sanitizedLastFailure = "capability_settings_failed"
            }
        }
        let repository = try settingsRepositoryOrThrow()
        try beginSettingsMutation()
        defer { finishSettingsMutation() }

        let oldServer = try await repository.server(id: draft.server.id)
        switch draft.mutationMode {
        case .create:
            guard oldServer == nil else {
                throw CapabilityControllerError.serverAlreadyExists
            }
        case .edit(let originalID):
            guard originalID == draft.server.id, oldServer != nil else {
                throw CapabilityControllerError.serverIdentityMismatch
            }
        }
        let oldBindings = try await repository.secretBindings(
            serverID: draft.server.id
        )
        let oldProviderIDs = Set(try await repository.enabledProviderProfileIDs(
            serverID: draft.server.id
        ))
        let oldBindingIdentity = oldBindings.map(Self.secretBindingIdentity).sorted()
        let newBindingIdentity = draft.secrets.map(Self.secretBindingIdentity).sorted()
        let materialChange = oldServer.map {
            $0.transport != draft.server.transport
                || $0.command != draft.server.command
                || $0.endpoint != draft.server.endpoint
                || $0.arguments != draft.server.arguments
                || oldBindingIdentity != newBindingIdentity
                || !draft.secretValues.isEmpty
        } ?? true
        let remainsEnabled = oldServer?.enabled == true
            && draft.server.enabled && !materialChange
        let authoritativeServer = CapabilityServerRecord(
            id: draft.server.id,
            displayName: draft.server.displayName,
            transport: draft.server.transport,
            command: draft.server.command,
            endpoint: draft.server.endpoint,
            arguments: draft.server.arguments,
            enabled: remainsEnabled,
            defaultPolicy: draft.server.defaultPolicy,
            staleState: remainsEnabled ? (oldServer?.staleState ?? .stale) : .stale,
            createdAt: oldServer?.createdAt ?? draft.server.createdAt,
            updatedAt: Date()
        )
        let authoritativeProviderIDs = remainsEnabled
            ? draft.providerProfileIDs : []
        _ = try Self.configuration(
            server: authoritativeServer,
            bindings: draft.secrets,
            providerProfileIDs: authoritativeProviderIDs
        )
        let references = Set(oldBindings.map(\.credentialReference))
            .union(draft.secrets.map(\.credentialReference))
        let oldSecrets = try await secretSnapshot(references)
        do {
            for (reference, value) in draft.secretValues {
                try await settingsSecrets.store(reference, value)
            }
            let desiredReferences = Set(draft.secrets.map(\.credentialReference))
            for reference in references.subtracting(desiredReferences) {
                try await settingsSecrets.delete(reference)
            }
        } catch {
            do {
                try await restoreSecrets(oldSecrets)
            } catch {
                await leaveRuntimeUnavailable()
                throw CapabilitySettingsMutationError.recoveryFailed
            }
            throw CapabilitySettingsMutationError.secretMutationFailed
        }
        var committed = false
        do {
            try await repository.replaceServerConfiguration(
                server: authoritativeServer,
                secretBindings: draft.secrets,
                enabledProviderProfileIDs: authoritativeProviderIDs
            )
            committed = true
            try await reloadRuntimeAuthority()
        } catch {
            let originalError = error
            var recoveryFailed = false
            if committed {
                do {
                    if let oldServer {
                        try await repository.replaceServerConfiguration(
                            server: oldServer,
                            secretBindings: oldBindings,
                            enabledProviderProfileIDs: oldProviderIDs
                        )
                    } else {
                        try await repository.deleteServer(id: draft.server.id)
                    }
                } catch {
                    recoveryFailed = true
                }
            }
            do {
                try await restoreSecrets(oldSecrets)
            } catch {
                recoveryFailed = true
            }
            if recoveryFailed {
                await leaveRuntimeUnavailable()
                throw CapabilitySettingsMutationError.recoveryFailed
            }
            if committed {
                do {
                    try await reloadRuntimeAuthority()
                } catch {
                    await leaveRuntimeUnavailable()
                    throw CapabilitySettingsMutationError.recoveryFailed
                }
            }
            sanitizedLastFailure = "capability_settings_failed"
            throw originalError
        }
        succeeded = true
    }

    func removeServerFromSettings(serverID: String) async throws {
        var succeeded = false
        defer {
            if !succeeded {
                sanitizedLastFailure = "capability_settings_failed"
            }
        }
        let repository = try settingsRepositoryOrThrow()
        try beginSettingsMutation()
        defer { finishSettingsMutation() }
        guard let server = try await repository.server(id: serverID) else {
            throw CapabilityStorageError.serverNotFound
        }
        let bindings = try await repository.secretBindings(serverID: serverID)
        let providerIDs = Set(try await repository.enabledProviderProfileIDs(
            serverID: serverID
        ))
        let catalog = try await repository.catalog(serverID: serverID)
        let secrets = try await secretSnapshot(Set(bindings.map(\.credentialReference)))
        var committed = false
        do {
            for reference in secrets.keys {
                try await settingsSecrets.delete(reference)
            }
            try await repository.deleteServer(id: serverID)
            committed = true
            try await reloadRuntimeAuthority()
        } catch {
            let originalError = error
            var recoveryFailed = false
            if committed {
                do {
                    try await repository.restoreServerConfiguration(
                        server: server,
                        secretBindings: bindings,
                        enabledProviderProfileIDs: providerIDs,
                        catalog: catalog
                    )
                } catch {
                    recoveryFailed = true
                }
            }
            do {
                try await restoreSecrets(secrets)
            } catch {
                recoveryFailed = true
            }
            if recoveryFailed {
                await leaveRuntimeUnavailable()
                throw CapabilitySettingsMutationError.recoveryFailed
            }
            if committed {
                do {
                    try await reloadRuntimeAuthority()
                } catch {
                    await leaveRuntimeUnavailable()
                    throw CapabilitySettingsMutationError.recoveryFailed
                }
            }
            sanitizedLastFailure = "capability_settings_failed"
            throw originalError
        }
        succeeded = true
    }

    func setProviderEnabledFromSettings(
        _ enabled: Bool,
        serverID: String,
        providerProfileID: UUID
    ) async throws {
        let repository = try settingsRepositoryOrThrow()
        try beginSettingsMutation()
        defer { finishSettingsMutation() }
        guard let server = try await repository.server(id: serverID) else {
            sanitizedLastFailure = "capability_settings_failed"
            throw CapabilityStorageError.serverNotFound
        }
        if enabled {
            guard server.enabled, server.staleState == .current else {
                sanitizedLastFailure = "capability_settings_failed"
                throw CapabilityControllerError.serverQualificationRequired
            }
        }
        let previous = Set(try await repository.enabledProviderProfileIDs(
            serverID: serverID
        ))
        var committed = false
        do {
            try await repository.setProviderEnabled(
                enabled,
                serverID: serverID,
                providerProfileID: providerProfileID
            )
            committed = true
            try await reloadRuntimeAuthority()
        } catch {
            guard committed else {
                sanitizedLastFailure = "capability_settings_failed"
                throw error
            }
            do {
                try await restoreProviderSettings(
                    previous, serverID: serverID, repository: repository
                )
                try await reloadRuntimeAuthority()
            } catch {
                await leaveRuntimeUnavailable()
                throw CapabilitySettingsMutationError.recoveryFailed
            }
            sanitizedLastFailure = "capability_settings_failed"
            throw error
        }
    }

    func setServerPolicyFromSettings(
        _ policy: CapabilityPolicy,
        serverID: String
    ) async throws {
        let repository = try settingsRepositoryOrThrow()
        try beginSettingsMutation()
        defer { finishSettingsMutation() }
        guard let previous = try await repository.server(id: serverID) else {
            throw CapabilityStorageError.serverNotFound
        }
        let bindings = try await repository.secretBindings(serverID: serverID)
        let providerIDs = Set(try await repository.enabledProviderProfileIDs(
            serverID: serverID
        ))
        let updated = CapabilityServerRecord(
            id: previous.id,
            displayName: previous.displayName,
            transport: previous.transport,
            command: previous.command,
            endpoint: previous.endpoint,
            arguments: previous.arguments,
            enabled: previous.enabled,
            defaultPolicy: policy,
            staleState: previous.staleState,
            createdAt: previous.createdAt,
            updatedAt: Date()
        )
        var committed = false
        do {
            try await repository.replaceServerConfiguration(
                server: updated,
                secretBindings: bindings,
                enabledProviderProfileIDs: providerIDs
            )
            committed = true
            try await reloadRuntimeAuthority()
        } catch {
            guard committed else {
                sanitizedLastFailure = "capability_settings_failed"
                throw error
            }
            do {
                try await repository.replaceServerConfiguration(
                    server: previous,
                    secretBindings: bindings,
                    enabledProviderProfileIDs: providerIDs
                )
                try await reloadRuntimeAuthority()
            } catch {
                await leaveRuntimeUnavailable()
                throw CapabilitySettingsMutationError.recoveryFailed
            }
            sanitizedLastFailure = "capability_settings_failed"
            throw error
        }
    }

    func setToolPolicyFromSettings(
        _ policy: CapabilityPolicy?,
        toolID: CapabilityID
    ) async throws {
        let repository = try settingsRepositoryOrThrow()
        try beginSettingsMutation()
        defer { finishSettingsMutation() }
        let identity = toolID.rawValue.split(separator: "/", maxSplits: 2)
        guard identity.count == 3 else {
            sanitizedLastFailure = "capability_settings_failed"
            throw CapabilityStorageError.toolNotFound
        }
        let serverID = String(identity[1])
        guard let record = try await repository.catalog(serverID: serverID)
            .first(where: { $0.descriptor.id == toolID })
        else {
            sanitizedLastFailure = "capability_settings_failed"
            throw CapabilityStorageError.toolNotFound
        }
        let previous = record.policyOverride
        var committed = false
        do {
            try await repository.setPolicyOverride(policy, toolID: toolID)
            committed = true
            try await reloadRuntimeAuthority()
        } catch {
            guard committed else {
                sanitizedLastFailure = "capability_settings_failed"
                throw error
            }
            do {
                try await repository.setPolicyOverride(previous, toolID: toolID)
                try await reloadRuntimeAuthority()
            } catch {
                await leaveRuntimeUnavailable()
                throw CapabilitySettingsMutationError.recoveryFailed
            }
            sanitizedLastFailure = "capability_settings_failed"
            throw error
        }
    }

    func testAndEnableServer(
        serverID: String,
        compatibleProviderProfileIDs: Set<UUID>
    ) async throws -> Int {
        let repository = try settingsRepositoryOrThrow()
        try beginSettingsMutation()
        defer { finishSettingsMutation() }
        guard !compatibleProviderProfileIDs.isEmpty else {
            sanitizedLastFailure = "capability_settings_failed"
            throw CapabilityControllerError.providerMismatch
        }
        guard let previous = try await repository.server(id: serverID) else {
            sanitizedLastFailure = "capability_settings_failed"
            throw CapabilityStorageError.serverNotFound
        }
        let bindings = try await repository.secretBindings(serverID: serverID)
        let oldProviderIDs = Set(try await repository.enabledProviderProfileIDs(
            serverID: serverID
        ))
        let oldCatalog = try await repository.catalog(serverID: serverID)
        let enabled = CapabilityServerRecord(
            id: previous.id,
            displayName: previous.displayName,
            transport: previous.transport,
            command: previous.command,
            endpoint: previous.endpoint,
            arguments: previous.arguments,
            enabled: true,
            defaultPolicy: previous.defaultPolicy,
            staleState: .current,
            createdAt: previous.createdAt,
            updatedAt: Date()
        )
        let configuration = try Self.configuration(
            server: enabled,
            bindings: bindings,
            providerProfileIDs: compatibleProviderProfileIDs
        )
        let session: any MCPClientSessionProtocol
        do {
            session = try await makeSession(configuration)
        } catch {
            sanitizedLastFailure = "capability_connection_failed"
            throw error
        }
        let tools: [MCPDiscoveredTool]
        do {
            tools = try await session.listTools()
            await session.disconnect()
        } catch {
            await session.disconnect()
            sanitizedLastFailure = "capability_discovery_failed"
            throw error
        }
        let descriptors: [CapabilityDescriptor]
        do {
            descriptors = try tools.map { tool in
                try CapabilityDescriptor(
                    id: CapabilityID(
                        source: .millerMCP,
                        serverID: serverID,
                        toolName: tool.name
                    ),
                    source: .millerMCP,
                    serverID: serverID,
                    toolName: tool.name,
                    displayName: tool.displayName,
                    summary: tool.summary,
                    inputSchemaJSON: tool.inputSchemaJSON,
                    readOnlyHint: tool.readOnlyHint,
                    providerProfileIDs: compatibleProviderProfileIDs,
                    isAvailable: true
                )
            }
        } catch {
            sanitizedLastFailure = "capability_catalog_failed"
            throw error
        }
        var committed = false
        do {
            try await repository.activateServer(
                server: enabled,
                secretBindings: bindings,
                enabledProviderProfileIDs: compatibleProviderProfileIDs,
                descriptors: descriptors
            )
            committed = true
            try await reloadRuntimeAuthority()
            return tools.count
        } catch {
            guard committed else {
                sanitizedLastFailure = "capability_settings_failed"
                throw error
            }
            do {
                try await repository.restoreServerConfiguration(
                    server: previous,
                    secretBindings: bindings,
                    enabledProviderProfileIDs: oldProviderIDs,
                    catalog: oldCatalog
                )
                try await reloadRuntimeAuthority()
            } catch {
                await leaveRuntimeUnavailable()
                throw CapabilitySettingsMutationError.recoveryFailed
            }
            sanitizedLastFailure = "capability_settings_failed"
            throw error
        }
    }

    func reloadLocalConfiguration() async throws {
        try beginSettingsMutation()
        defer { finishSettingsMutation() }
        try await reloadRuntimeAuthority()
    }

    func deleteCapabilityAuditsFromSettings() async throws {
        let repository = try settingsRepositoryOrThrow()
        try beginSettingsMutation()
        defer { finishSettingsMutation() }
        try await repository.deleteAllAudits()
    }

    private func reloadRuntimeAuthority() async throws {
        await broker?.disconnectAll()
        broker = nil
        descriptors.removeAll()
        serverDisplayNames.removeAll()
        serverPolicies.removeAll()
        toolPolicies.removeAll()
        startupError = nil
        await start(allowDuringAuthorityMutation: true)
        if let startupError { throw startupError }
        await reconcileProviderProjection()
    }

    private func beginSettingsMutation() throws {
        guard !settingsMutationInProgress, !maintenanceInProgress,
              startupReservation == nil,
              preparationReservation == nil,
              activeTypedAssociation == nil,
              activeVoiceAssociation == nil,
              pendingApprovalCount == 0,
              rpcTasks.isEmpty,
              callContexts.isEmpty,
              pendingTerminalAudits.isEmpty,
              begunAuditIDs.isEmpty
        else { throw CapabilityControllerError.settingsBusy }
        settingsMutationInProgress = true
        settingsBusy = true
    }

    private func finishSettingsMutation() {
        settingsMutationInProgress = false
        settingsBusy = maintenanceInProgress
        let waiters = settingsMutationWaiters
        settingsMutationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForSettingsMutation() async {
        guard settingsMutationInProgress else { return }
        await withCheckedContinuation { continuation in
            settingsMutationWaiters.append(continuation)
        }
    }

    private func beginPreparation(
        kind: PreparationKind
    ) throws -> PreparationReservation {
        guard !settingsMutationInProgress, !maintenanceInProgress,
              preparationReservation == nil else {
            throw CapabilityControllerError.settingsBusy
        }
        let reservation = PreparationReservation(token: UUID(), kind: kind)
        preparationReservation = reservation
        return reservation
    }

    private func validatePreparation(
        _ reservation: PreparationReservation
    ) throws {
        guard preparationReservation == reservation else {
            throw CapabilityControllerError.staleGeneration
        }
    }

    private func releasePreparation(_ reservation: PreparationReservation) {
        guard preparationReservation == reservation else { return }
        preparationReservation = nil
    }

    private func releasePreparation(kind: PreparationKind) {
        guard preparationReservation?.kind == kind else { return }
        preparationReservation = nil
    }

    private func settingsRepositoryOrThrow() throws -> SQLiteCapabilityRepository {
        guard let settingsRepository else {
            throw CapabilityControllerError.unavailable
        }
        return settingsRepository
    }

    private func secretSnapshot(
        _ references: Set<UUID>
    ) async throws -> [UUID: StoredSecret] {
        var result: [UUID: StoredSecret] = [:]
        do {
            for reference in references {
                if let value = try await settingsSecrets.load(reference) {
                    result[reference] = .value(value)
                } else {
                    result[reference] = .absent
                }
            }
            return result
        } catch {
            throw CapabilitySettingsMutationError.secretMutationFailed
        }
    }

    private func restoreSecrets(_ snapshot: [UUID: StoredSecret]) async throws {
        var failed = false
        for reference in snapshot.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            do {
                switch snapshot[reference] {
                case .value(let value):
                    try await settingsSecrets.store(reference, value)
                case .absent:
                    try await settingsSecrets.delete(reference)
                case nil:
                    break
                }
            } catch {
                failed = true
            }
        }
        if failed { throw CapabilitySettingsMutationError.recoveryFailed }
    }

    private func restoreProviderSettings(
        _ providerIDs: Set<UUID>,
        serverID: String,
        repository: SQLiteCapabilityRepository
    ) async throws {
        guard let server = try await repository.server(id: serverID) else {
            throw CapabilityStorageError.serverNotFound
        }
        try await repository.replaceServerConfiguration(
            server: server,
            secretBindings: try await repository.secretBindings(serverID: serverID),
            enabledProviderProfileIDs: providerIDs
        )
    }

    private func makeSession(
        _ configuration: MCPServerConfiguration
    ) async throws -> any MCPClientSessionProtocol {
        if let sessionFactory {
            return try await sessionFactory(configuration)
        }
        return try await MCPClientSession.connect(
            configuration: configuration,
            credentialResolver: credentialResolver
        )
    }

    private func leaveRuntimeUnavailable() async {
        await broker?.disconnectAll()
        broker = nil
        descriptors.removeAll()
        startupError = CapabilitySettingsMutationError.recoveryFailed
        sanitizedLastFailure = "capability_settings_failed"
    }

    func configureProviderProjection(
        _ dependencies: CapabilityProviderProjectionDependencies?
    ) {
        providerProjection = dependencies
    }

    func reconcileProviderProjection() async {
        providerProjectionGeneration &+= 1
        let generation = providerProjectionGeneration
        guard let providerProjection else {
            providerDescriptors.removeAll()
            return
        }
        do {
            guard let profile = try await providerProjection.selectedProfile(),
                  profile.kind == .codexOAuth,
                  profile.isSelected
            else {
                guard generation == providerProjectionGeneration else { return }
                providerDescriptors.removeAll()
                return
            }
            await start()
            let local = await broker?.catalog(providerProfileID: profile.id) ?? []
            let snapshot = try await providerProjection.inventory(
                profile,
                local.filter { $0.source == .millerMCP }
            )
            guard generation == providerProjectionGeneration else { return }
            replaceProviderCatalog(snapshot)
        } catch {
            return
        }
    }

    nonisolated func providerCallbacks(
        authority: CapabilityProviderCallbackAuthority? = nil
    ) -> CapabilityProviderCallbacks {
        CapabilityProviderCallbacks(
            activity: { [weak self] activity in
                guard let authority else { return }
                await self?.recordProviderActivity(activity, authority: authority)
            },
            approval: { [weak self] request in
                guard let self, let authority else { return .decline }
                return await self.resolveProviderApproval(
                    request,
                    authority: authority
                )
            },
            approvalDetails: { [weak self] approval in
                guard let self, let authority else { return .decline }
                return await self.resolveProviderApproval(
                    approval,
                    authority: authority
                )
            }
        )
    }

    func capturedProviderCallbacks() -> CapabilityProviderCallbacks {
        providerCallbacks(authority: activeProviderCallbackAuthority)
    }

    private func resolveProviderApproval(
        _ request: CapabilityApprovalRequest,
        authority: CapabilityProviderCallbackAuthority
    ) async -> CapabilityApprovalDecision {
        guard let association = currentAssociation(for: authority)
        else { return .decline }
        let decision = await resolveProviderApproval(
            request,
            association: association
        )
        guard providerAuthorityIsCurrent(authority) else { return .decline }
        return decision
    }

    private func resolveProviderApproval(
        _ approval: CodexProviderApproval,
        authority: CapabilityProviderCallbackAuthority
    ) async -> CapabilityApprovalDecision {
        guard let association = currentAssociation(for: authority)
        else { return .decline }
        let decision = await resolveProviderApproval(
            approval,
            association: association
        )
        guard providerAuthorityIsCurrent(authority) else { return .decline }
        return decision
    }

    private func recordProviderActivity(
        _ activity: CodexCapabilityActivity,
        authority: CapabilityProviderCallbackAuthority
    ) async {
        guard providerAuthorityIsCurrent(authority) else { return }
        guard let association = currentAssociation(for: authority) else { return }
        await recordProviderActivity(
            activity,
            association: association
        )
    }

    private func providerAuthorityIsCurrent(
        _ authority: CapabilityProviderCallbackAuthority
    ) -> Bool {
        guard activeProviderCallbackAuthority == authority,
              let association = authority.isVoice
                ? activeVoiceAssociation : activeTypedAssociation
        else { return false }
        return !isCancelled(association)
    }

    private func currentAssociation(
        for authority: CapabilityProviderCallbackAuthority
    ) -> CapabilityAssociation? {
        guard providerAuthorityIsCurrent(authority) else { return nil }
        return authority.isVoice ? activeVoiceAssociation : activeTypedAssociation
    }

    func resolveApproval(_ decision: CapabilityApprovalDecision) {
        guard let pending = activePending else { return }
        let admitted = decision == .allowOnce
            && !pending.presentation.canAllowOnce ? .decline : decision
        finish(pending, decision: admitted)
    }

    func declinePendingApprovals(for termination: CapabilityApprovalTermination) {
        if termination == .interrupt {
            activeProviderCallbackAuthority = nil
            providerCallbackAuthorityBox?.clear()
            cancelActiveRPCWork()
        }
        let pending = [activePending].compactMap { $0 } + pendingQueue
        activePending = nil
        pendingApproval = nil
        liveVoiceConfirmationMessage = nil
        pendingQueue.removeAll()
        for pending in pending { complete(pending, decision: .decline) }
    }

    func acceptSpokenApproval(callID _: CapabilityCallID) -> Bool { false }

    func prepareRequest(
        _ request: ReasoningRequest,
        providerProfileID: UUID,
        kind: ProviderKind
    ) async throws -> ReasoningRequest {
        let association = CapabilityAssociation.typed(
            conversationID: request.conversationID,
            turnID: request.turnID,
            generation: request.generation
        )
        let reservation = try beginPreparation(
            kind: .typed(turnID: request.turnID, generation: request.generation)
        )
        let capabilityCatalog: CapabilityCatalogSnapshot
        do {
            await finalizeProviderActivities()
            try Task.checkCancellation()
            try validatePreparation(reservation)
            if kind == .codexOAuth {
                try await prepareBridge(
                    providerProfileID: providerProfileID,
                    isVoice: false
                )
                try Task.checkCancellation()
                try validatePreparation(reservation)
            }
            capabilityCatalog = await catalog(providerProfileID: providerProfileID)
            try Task.checkCancellation()
            try validatePreparation(reservation)
            try admitTypedAssociation(
                association,
                providerProfileID: providerProfileID
            )
            releasePreparation(reservation)
        } catch {
            releasePreparation(reservation)
            throw error
        }
        return ReasoningRequest(
            conversationID: request.conversationID,
            turnID: request.turnID,
            generation: request.generation,
            context: request.context,
            userText: request.userText,
            capabilityCatalog: capabilityCatalog,
            voiceHistoryAttachment: request.voiceHistoryAttachment
        )
    }

    private func requestApproval(
        _ request: CapabilityApprovalRequest
    ) async -> CapabilityApprovalDecision {
        guard let context = callContexts[request.callID],
              !isCancelled(context.association)
        else { return .decline }
        let descriptor = context.descriptor
        let presentation = CapabilityApprovalPresentation(
            callID: request.callID,
            origin: Self.origin(descriptor.source),
            server: serverDisplayNames[descriptor.serverID]
                ?? descriptor.serverID,
            tool: descriptor.displayName,
            intent: descriptor.summary.isEmpty
                ? request.summary.text : descriptor.summary,
            policy: request.policy.value,
            requiresVisualConfirmation: true,
            canAllowOnce: approvalCanAllowOnce[request.callID] ?? true
        )
        if let emit = eventEmitters[request.callID] {
            await emit(.capabilityApprovalRequested(request))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeout = Task { [weak self] in
                    guard let approvalTimeout = self?.approvalTimeout else { return }
                    do { try await Task.sleep(for: approvalTimeout) }
                    catch { return }
                    await MainActor.run {
                        self?.resolvePending(
                            callID: request.callID,
                            decision: .decline
                        )
                    }
                }
                let pending = PendingApproval(
                    request: request,
                    presentation: presentation,
                    continuation: continuation,
                    timeout: timeout
                )
                if activePending == nil { present(pending) }
                else { pendingQueue.append(pending) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePending(
                    callID: request.callID,
                    decision: .decline
                )
            }
        }
    }

    private func present(_ pending: PendingApproval) {
        activePending = pending
        pendingApproval = pending.presentation
        let isVoice = callContexts[pending.request.callID]?
            .association.isVoice == true
        liveVoiceConfirmationMessage = isVoice ? "Confirmation required" : nil
        if isVoice {
            confirmationAnnouncer("Confirmation required")
        }
    }

    private func finish(
        _ pending: PendingApproval,
        decision: CapabilityApprovalDecision
    ) {
        guard activePending?.request.callID == pending.request.callID else { return }
        activePending = nil
        pendingApproval = nil
        liveVoiceConfirmationMessage = nil
        complete(pending, decision: decision)
        if !pendingQueue.isEmpty { present(pendingQueue.removeFirst()) }
    }

    private func resolvePending(
        callID: CapabilityCallID,
        decision: CapabilityApprovalDecision
    ) {
        if let pending = activePending,
           pending.request.callID == callID {
            finish(pending, decision: decision)
            return
        }
        guard let index = pendingQueue.firstIndex(where: {
            $0.request.callID == callID
        }) else { return }
        complete(pendingQueue.remove(at: index), decision: decision)
    }

    private func complete(
        _ pending: PendingApproval,
        decision: CapabilityApprovalDecision
    ) {
        pending.timeout.cancel()
        approvalDecisions[pending.request.callID] = decision
        pending.continuation.resume(returning: decision)
    }

    private func recordLifecycle(_ event: CapabilityLifecycleEvent) async {
        guard let context = callContexts[event.callID] else { return }
        if !begunAuditIDs.contains(event.callID) {
            do {
                try await persistBeginAudit(
                    callID: event.callID,
                    context: context,
                    policy: event.policy
                )
            } catch {
                if event.state == .terminal {
                    pendingTerminalAudits[event.callID] =
                        pendingTerminalAudits[event.callID] ?? event
                }
                return
            }
        }
        guard event.state == .terminal else {
            if let emit = eventEmitters[event.callID] {
                await emit(.capabilityLifecycle(event))
            }
            return
        }
        let terminalEvent = pendingTerminalAudits[event.callID] ?? event
        pendingTerminalAudits[event.callID] = terminalEvent
        do {
            try await persistTerminalAudit(terminalEvent, context: context)
        } catch {
            return
        }
    }

    private func persistBeginAudit(
        callID: CapabilityCallID,
        context: CallContext,
        policy: EffectiveCapabilityPolicy
    ) async throws {
        guard !begunAuditIDs.contains(callID) else { return }
        let summary = SanitizedCapabilitySummary(
            context.visibility == .complete
                ? Self.summaryProjection(context.descriptor)
                : .providerDetailsUnavailable
        )
        let record = CapabilityAuditRecord(
            id: callID,
            conversationID: context.association.conversationID,
            turnID: context.association.turnID,
            voiceSessionID: context.association.voiceSessionID,
            source: context.descriptor.source,
            serverID: context.descriptor.serverID,
            toolName: context.descriptor.toolName,
            startedAt: providerCallStartedAt[callID] ?? Date(),
            terminalAt: nil,
            effectivePolicy: policy.value,
            approvalRequested: policy.requiresApproval,
            approvalDecision: nil,
            terminalOutcome: nil,
            summary: summary,
            visibility: context.visibility
        )
        try await persistence.beginAudit(record)
        begunAuditIDs.insert(callID)
    }

    private func persistTerminalAudit(
        _ event: CapabilityLifecycleEvent,
        context: CallContext
    ) async throws {
        guard !terminalAuditIDs.contains(event.callID),
              let outcome = event.outcome
        else {
            pendingTerminalAudits[event.callID] = nil
            return
        }
        if let policy = pendingApprovalUpgrades[event.callID] {
            try await persistence.requireApproval(event.callID, policy)
            pendingApprovalUpgrades[event.callID] = nil
        }
        try await persistence.terminalizeAudit(
            event.callID,
            outcome,
            approvalDecisions[event.callID]
        )
        terminalAuditIDs.insert(event.callID)
        pendingTerminalAudits[event.callID] = nil
        appendActivity(CapabilityActivityRow(
            callID: event.callID,
            origin: Self.origin(context.descriptor.source),
            server: serverDisplayNames[context.descriptor.serverID]
                ?? context.descriptor.serverID,
            tool: context.descriptor.displayName,
            outcome: outcome
        ))
        if let emit = eventEmitters[event.callID] {
            await emit(.capabilityLifecycle(event))
        }
    }

    private func settleTerminalAudit(_ callID: CapabilityCallID) async throws {
        guard !terminalAuditIDs.contains(callID),
              let event = pendingTerminalAudits[callID],
              let context = callContexts[callID]
        else {
            if terminalAuditIDs.contains(callID) { return }
            throw CapabilityControllerError.auditUnavailable
        }
        try await persistTerminalAudit(event, context: context)
    }

    private func recoverPendingTerminalAudits() async throws {
        for callID in Array(pendingTerminalAudits.keys) {
            try await recoverPendingTerminalAudit(callID)
        }
    }

    private func recoverPendingTerminalAuditsBestEffort() async {
        for callID in Array(pendingTerminalAudits.keys) {
            try? await recoverPendingTerminalAudit(callID)
        }
    }

    private func recoverPendingTerminalAudit(
        _ callID: CapabilityCallID
    ) async throws {
        guard let event = pendingTerminalAudits[callID],
              let context = callContexts[callID]
        else { throw CapabilityControllerError.auditUnavailable }
        try await persistBeginAudit(
            callID: callID,
            context: context,
            policy: event.policy
        )
        try await persistTerminalAudit(event, context: context)
        markProviderCallMappingsCompleted(callID)
        releaseCallState(callID)
    }

    private func markProviderCallMappingsCompleted(_ callID: CapabilityCallID) {
        let keys = providerCallIDs.compactMap { key, value in
            value == callID ? key : nil
        }
        completedProviderCallKeys.formUnion(keys)
    }

    private func appendActivity(_ row: CapabilityActivityRow) {
        activityRows.removeAll { $0.callID == row.callID }
        activityRows.append(row)
        if activityRows.count > 100 {
            activityRows.removeFirst(activityRows.count - 100)
        }
    }

    private func releaseCallState(_ callID: CapabilityCallID) {
        callContexts[callID] = nil
        approvalDecisions[callID] = nil
        begunAuditIDs.remove(callID)
        terminalAuditIDs.remove(callID)
        pendingTerminalAudits[callID] = nil
        pendingApprovalUpgrades[callID] = nil
        providerCallPolicies[callID] = nil
        providerCallStartedAt[callID] = nil
        approvalCanAllowOnce[callID] = nil
    }

    private func cancelActiveRPCWork() {
        if case .typed(_, let turnID, let generation) = activeTypedAssociation {
            markTypedGenerationCancelled(Self.typedKey(turnID, generation))
            activeTypedAssociation = nil
        }
        if case .voice(let sessionID, _) = activeVoiceAssociation {
            markVoiceSessionCancelled(sessionID)
            activeVoiceAssociation = nil
        }
        for task in rpcTasks.values { task.cancel() }
    }

    private func prepareBridge(
        providerProfileID: UUID,
        isVoice: Bool
    ) async throws {
        await start()
        guard broker != nil else { throw CapabilityControllerError.unavailable }
        await stopBridge()
        let authority = CapabilityProviderCallbackAuthority(
            generation: UUID(),
            isVoice: isVoice
        )
        activeProviderCallbackAuthority = authority
        providerCallbackAuthorityBox?.install(authority)
        guard let trustedParent, let bridgeBox else { return }
        let server = CapabilityRPCServer(trustedParent: trustedParent) {
            [weak self] request in
            guard let self else { return .failed(nil, code: "broker_unavailable") }
            return await self.handleRPC(request, providerProfileID: providerProfileID)
        }
        let endpoint = try await server.start()
        rpcServer = server
        rpcEndpoint = endpoint
        let snapshot = await catalog(providerProfileID: providerProfileID)
        bridgeBox.install(
            endpoint: endpoint,
            providerProfileID: providerProfileID,
            descriptors: snapshot.descriptors.filter { $0.source == .millerMCP }
        )
    }

    private func stopBridge() async {
        await rpcServer?.stop()
        rpcServer = nil
        rpcEndpoint = nil
        bridgeBox?.clear()
        activeProviderCallbackAuthority = nil
        providerCallbackAuthorityBox?.clear()
    }

    private func handleRPC(
        _ request: CapabilityRPCRequest,
        providerProfileID: UUID
    ) async -> CapabilityRPCResponse {
        switch request {
        case .list(let received):
            guard received == providerProfileID else {
                return .failed(nil, code: "provider_mismatch")
            }
            return .catalog(
                (await catalog(providerProfileID: providerProfileID)).descriptors
                    .filter { $0.source == .millerMCP }
            )
        case .call(let callID, let capabilityID, let argumentsJSON):
            guard let association = activeVoiceAssociation ?? activeTypedAssociation
            else { return .failed(callID, code: "stale_generation") }
            let route: CapabilityInvocationRoute = association.isVoice
                ? .gptLive : .typedCodex
            let task = Task {
                try await execute(
                    callID: callID,
                    capabilityID: capabilityID,
                    argumentsJSON: argumentsJSON,
                    providerProfileID: providerProfileID,
                    association: association,
                    route: route
                )
            }
            rpcTasks[callID] = task
            defer { rpcTasks[callID] = nil }
            do {
                let result = try await task.value
                return .result(
                    callID,
                    contentJSON: result.contentJSON,
                    isError: result.isError
                )
            } catch CapabilityBrokerError.declined {
                return .failed(callID, code: "declined")
            } catch CapabilityBrokerError.timedOut {
                return .failed(callID, code: "timed_out")
            } catch is CancellationError {
                return .failed(callID, code: "cancelled")
            } catch {
                return .failed(callID, code: "call_failed")
            }
        case .cancel(let callID):
            rpcTasks[callID]?.cancel()
            return .failed(callID, code: "cancelled")
        }
    }

    private func descriptor(for id: CapabilityID) -> CapabilityDescriptor? {
        descriptors[id] ?? providerDescriptors[id]
    }

    private func isCancelled(_ association: CapabilityAssociation) -> Bool {
        switch association {
        case .typed(_, let turnID, let generation):
            return cancelledTypedGenerations.contains(
                Self.typedKey(turnID, generation)
            )
        case .voice(let sessionID, _):
            return cancelledVoiceSessionIDs.contains(sessionID)
        }
    }

    private func markVoiceSessionCancelled(_ sessionID: UUID) {
        guard cancelledVoiceSessionIDs.insert(sessionID).inserted else { return }
        cancelledVoiceSessionOrder.append(sessionID)
        if cancelledVoiceSessionOrder.count > 128 {
            cancelledVoiceSessionIDs.remove(cancelledVoiceSessionOrder.removeFirst())
        }
    }

    private static func typedKey(_ turnID: TurnID, _ generation: Int) -> String {
        "\(turnID.description):\(generation)"
    }

    private func providerCallID(threadID: String, itemID: String) -> CapabilityCallID {
        let key = providerCallKey(threadID: threadID, itemID: itemID)
        if let existing = providerCallIDs[key] { return existing }
        let created = CapabilityCallID()
        providerCallIDs[key] = created
        return created
    }

    private func providerCallKey(threadID: String, itemID: String) -> String {
        "\(threadID.utf8.count):\(threadID)\(itemID)"
    }

    private func resetProviderActivityAuthority() {
        providerCallIDs.removeAll()
        providerCallPolicies.removeAll()
        providerCallStartedAt.removeAll()
        completedProviderCallKeys.removeAll()
    }

    private func finalizeProviderActivities() async {
        for callID in Set(providerCallIDs.values) {
            if pendingTerminalAudits[callID] != nil {
                try? await recoverPendingTerminalAudit(callID)
                continue
            }
            guard let context = callContexts[callID] else { continue }
            let event = try? CapabilityLifecycleEvent(
                callID: callID,
                capabilityID: context.descriptor.id,
                summary: CapabilitySummary(text: "Provider activity ended"),
                state: .terminal,
                outcome: .cancelled,
                policy: providerCallPolicies[callID] ?? Self.providerPolicy()
            )
            if let event { await recordLifecycle(event) }
            if terminalAuditIDs.contains(callID) {
                markProviderCallMappingsCompleted(callID)
                releaseCallState(callID)
            }
        }
        retainOnlyUndurableProviderActivityAuthority()
    }

    private func retainOnlyUndurableProviderActivityAuthority() {
        let retainedCallIDs = Set(providerCallIDs.values.filter {
            callContexts[$0] != nil
        })
        guard !retainedCallIDs.isEmpty else {
            resetProviderActivityAuthority()
            return
        }
        providerCallIDs = providerCallIDs.filter {
            retainedCallIDs.contains($0.value)
        }
        providerCallPolicies = providerCallPolicies.filter {
            retainedCallIDs.contains($0.key)
        }
        providerCallStartedAt = providerCallStartedAt.filter {
            retainedCallIDs.contains($0.key)
        }
        completedProviderCallKeys.formIntersection(providerCallIDs.keys)
    }

    private func markTypedGenerationCancelled(_ key: String) {
        guard cancelledTypedGenerations.insert(key).inserted else { return }
        cancelledTypedGenerationOrder.append(key)
        if cancelledTypedGenerationOrder.count > 128 {
            cancelledTypedGenerations.remove(
                cancelledTypedGenerationOrder.removeFirst()
            )
        }
    }

    private static func origin(_ source: CapabilitySource) -> String {
        switch source {
        case .millerMCP: "Miller MCP"
        case .codexAccount: "Codex account"
        case .providerNative: "Provider"
        }
    }

    private static func summaryProjection(
        _ descriptor: CapabilityDescriptor
    ) -> SanitizedCapabilitySummary.Projection {
        if descriptor.readOnlyHint == true { return .readLocalFiles }
        return .changeLocalFiles
    }

    private static func terminalOutcome(
        for result: Result<SanitizedCapabilityResult, Error>
    ) -> CapabilityTerminalOutcome {
        switch result {
        case .success(let value):
            return value.isError ? .failed : .succeeded
        case .failure(let error):
            if error is CancellationError { return .cancelled }
            switch error as? CapabilityBrokerError {
            case .declined: return .declined
            case .timedOut: return .timedOut
            default: return .failed
            }
        }
    }

    private static func providerPolicy() -> EffectiveCapabilityPolicy {
        CapabilityPolicyResolver().resolve(
            serverPolicy: .fullyTrusted,
            readOnlyHint: nil,
            mandatoryProviderApproval: false
        ).effectivePolicy
    }

    private func effectivePolicy(
        for descriptor: CapabilityDescriptor
    ) -> EffectiveCapabilityPolicy {
        CapabilityPolicyResolver().resolve(
            serverPolicy: serverPolicies[descriptor.serverID] ?? .askBeforeChanges,
            toolOverride: toolPolicies[descriptor.id],
            readOnlyHint: descriptor.readOnlyHint
        ).effectivePolicy
    }

    private static func fallbackDescriptor(
        _ id: CapabilityID
    ) -> CapabilityDescriptor? {
        let parts = id.rawValue.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let source = CapabilitySource(rawValue: parts[0])
        else { return nil }
        return try? CapabilityDescriptor(
            id: id,
            source: source,
            serverID: parts[1],
            toolName: parts[2],
            displayName: parts[2],
            summary: "Provider capability activity",
            inputSchemaJSON: Data("{}".utf8),
            readOnlyHint: nil,
            providerProfileIDs: [],
            isAvailable: true,
            visibility: .providerManaged
        )
    }

    private static func runtimeConfiguration(
        repository: SQLiteCapabilityRepository
    ) async throws -> CapabilityRuntimeConfiguration {
        let records = try await repository.servers()
        var servers: [MCPServerConfiguration] = []
        var policies: [CapabilityID: CapabilityPolicy] = [:]
        for record in records {
            let transport: MCPServerTransport
            switch record.transport {
            case .stdio:
                guard let command = record.command else {
                    throw CapabilityControllerError.unavailable
                }
                transport = .stdio(
                    executable: command,
                    arguments: record.arguments
                )
            case .streamableHTTP:
                guard let endpoint = record.endpoint.flatMap(URL.init(string:))
                else { throw CapabilityControllerError.unavailable }
                transport = .http(endpoint: endpoint)
            }
            let bindings = try await repository.secretBindings(
                serverID: record.id
            ).map { binding in
                try MCPSecretBinding(
                    destination: binding.kind == .environment
                        ? .environment : .header,
                    name: binding.name,
                    credentialReference: binding.credentialReference
                )
            }
            servers.append(try MCPServerConfiguration(
                id: record.id,
                displayName: record.displayName,
                transport: transport,
                secrets: bindings,
                enabled: record.enabled,
                defaultPolicy: record.defaultPolicy,
                providerProfileIDs: Set(
                    try await repository.enabledProviderProfileIDs(
                        serverID: record.id
                    )
                )
            ))
            for tool in try await repository.catalog(serverID: record.id) {
                if let override = tool.policyOverride {
                    policies[tool.descriptor.id] = override
                }
            }
        }
        return CapabilityRuntimeConfiguration(
            servers: servers,
            toolPolicies: policies
        )
    }

    private static func configuration(
        server: CapabilityServerRecord,
        bindings: [CapabilitySecretBinding],
        providerProfileIDs: Set<UUID>
    ) throws -> MCPServerConfiguration {
        let transport: MCPServerTransport
        switch server.transport {
        case .stdio:
            guard let command = server.command else {
                throw CapabilityControllerError.unavailable
            }
            transport = .stdio(
                executable: command,
                arguments: server.arguments
            )
        case .streamableHTTP:
            guard let endpoint = server.endpoint.flatMap(URL.init(string:)) else {
                throw CapabilityControllerError.unavailable
            }
            transport = .http(endpoint: endpoint)
        }
        return try MCPServerConfiguration(
            id: server.id,
            displayName: server.displayName,
            transport: transport,
            secrets: try bindings.map { binding in
                try MCPSecretBinding(
                    destination: binding.kind == .environment
                        ? .environment : .header,
                    name: binding.name,
                    credentialReference: binding.credentialReference
                )
            },
            enabled: server.enabled,
            defaultPolicy: server.defaultPolicy,
            providerProfileIDs: providerProfileIDs
        )
    }

    private static func adapterProcessState(
        trustedParent: URL
    ) -> CapabilityAdapterProcessState {
        let leaseURL = CapabilityRPCRuntime.managedRoot(in: trustedParent)
            .appending(path: CapabilityRPCRuntime.processLeaseName)
        let descriptor = open(leaseURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return .noReachableLeasePID }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              (value.st_mode & 0o777) == 0o600,
              value.st_size > 0,
              value.st_size <= 32
        else { return .noReachableLeasePID }
        var bytes = [UInt8](repeating: 0, count: Int(value.st_size))
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count == bytes.count,
              let text = String(bytes: bytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(text),
              pid > 1
        else { return .noReachableLeasePID }
        return kill(pid, 0) == 0 || errno == EPERM
            ? .leasePIDAliveUnverified : .noReachableLeasePID
    }

    private static func secretBindingIdentity(
        _ binding: CapabilitySecretBinding
    ) -> String {
        "\(binding.id.uuidString)|\(binding.kind.rawValue)|\(binding.name)|"
            + binding.credentialReference.uuidString
    }

    private static func persist(
        catalog: CapabilityBrokerCatalog,
        repository: SQLiteCapabilityRepository,
        serverIDs: Set<String>,
        attemptedServerIDs: Set<String>
    ) async throws {
        let grouped = Dictionary(grouping: catalog.descriptors, by: \.serverID)
        for serverID in serverIDs.sorted() {
            if !attemptedServerIDs.contains(serverID)
                || catalog.staleServerIDs.contains(serverID) {
                try await repository.markCatalogStale(serverID: serverID)
            } else {
                try await repository.reconcileCatalog(
                    serverID: serverID,
                    descriptors: grouped[serverID] ?? []
                )
            }
        }
    }
}

actor CapabilityReasoningGateway: ReasoningGateway {
    private let base: any ReasoningGateway
    private let selectedProfile: @Sendable () async throws -> ProviderProfile
    private weak var controller: CapabilityController?

    init(
        base: any ReasoningGateway,
        selectedProfile: @escaping @Sendable () async throws -> ProviderProfile,
        controller: CapabilityController
    ) {
        self.base = base
        self.selectedProfile = selectedProfile
        self.controller = controller
    }

    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        guard let controller else { throw CapabilityControllerError.unavailable }
        let profile = try await selectedProfile()
        let source: AsyncThrowingStream<ReasoningEvent, Error>
        do {
            let prepared = try await controller.prepareRequest(
                request,
                providerProfileID: profile.id,
                kind: profile.kind
            )
            source = try await base.start(prepared)
        } catch {
            await controller.finishTypedAssociation(
                turnID: request.turnID,
                generation: request.generation
            )
            throw error
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        if event.isTerminal {
                            await controller.finishTypedAssociation(
                                turnID: request.turnID,
                                generation: request.generation
                            )
                            continuation.yield(event)
                            continuation.finish()
                            return
                        }
                        continuation.yield(event)
                    }
                    await controller.finishTypedAssociation(
                        turnID: request.turnID,
                        generation: request.generation
                    )
                    continuation.finish()
                } catch {
                    await controller.finishTypedAssociation(
                        turnID: request.turnID,
                        generation: request.generation
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel(_ cancellation: ReasoningCancellation) async {
        await controller?.cancelTypedAssociation(
            turnID: cancellation.turnID,
            generation: cancellation.targetGeneration
        )
        await base.cancel(cancellation)
    }

    func resolveApproval(
        callID: CapabilityCallID,
        decision: CapabilityApprovalDecision
    ) async throws {
        try await base.resolveApproval(callID: callID, decision: decision)
    }
}

private extension ReasoningEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .stopped, .failed: true
        default: false
        }
    }
}
