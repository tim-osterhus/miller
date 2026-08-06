import AVFoundation
import Combine
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
    let beginAudit: @Sendable (CapabilityAuditRecord) async throws -> Void
    let terminalizeAudit: @Sendable (
        CapabilityCallID,
        CapabilityTerminalOutcome,
        CapabilityApprovalDecision?
    ) async throws -> Void

    static let unavailable = Self(
        beginAudit: { _ in },
        terminalizeAudit: { _, _, _ in }
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

    private var broker: CapabilityBroker?
    private var descriptors: [CapabilityID: CapabilityDescriptor] = [:]
    private var serverDisplayNames: [String: String] = [:]
    private var serverPolicies: [String: CapabilityPolicy] = [:]
    private var toolPolicies: [CapabilityID: CapabilityPolicy] = [:]
    private var providerDescriptors: [CapabilityID: CapabilityDescriptor] = [:]
    private var providerProjection: CapabilityProviderProjectionDependencies?
    private var providerProjectionGeneration: UInt64 = 0
    private var startupError: Error?
    private var pendingQueue: [PendingApproval] = []
    private var activePending: PendingApproval?
    private var approvalDecisions: [CapabilityCallID: CapabilityApprovalDecision] = [:]
    private var callContexts: [CapabilityCallID: CallContext] = [:]
    private var begunAuditIDs = Set<CapabilityCallID>()
    private var terminalAuditIDs = Set<CapabilityCallID>()
    private var pendingTerminalAudits: [CapabilityCallID: CapabilityLifecycleEvent] = [:]
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
                beginAudit: { [repository] record in
                    try await repository.beginAudit(record)
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
            confirmationAnnouncer: { [confirmationSpeaker] message in
                confirmationSpeaker.announce(message)
            }
        )
    }

    func start() async {
        guard broker == nil, startupError == nil else { return }
        do {
            let configuration = try await loadConfiguration()
            let broker = try CapabilityBroker(
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
            self.broker = broker
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
            let catalog = await broker.refresh()
            descriptors = Dictionary(
                uniqueKeysWithValues: catalog.descriptors.map { ($0.id, $0) }
            )
        } catch {
            startupError = error
        }
    }

    func shutdown() async {
        declinePendingApprovals(for: .close)
        await finalizeProviderActivities()
        for task in rpcTasks.values { task.cancel() }
        rpcTasks.removeAll()
        eventEmitters.removeAll()
        providerCallIDs.removeAll()
        await rpcServer?.stop()
        rpcServer = nil
        rpcEndpoint = nil
        bridgeBox?.clear()
        await broker?.disconnectAll()
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
    ) {
        activeTypedAssociation = association
        activeProviderProfileID = providerProfileID
    }

    func cancelTypedAssociation(turnID: TurnID, generation: Int) async {
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
        if case .typed(_, let activeTurn, let activeGeneration) = activeTypedAssociation,
           activeTurn == turnID, activeGeneration == generation {
            activeTypedAssociation = nil
        }
        await finalizeProviderActivities()
        await stopBridge()
    }

    func admitVoiceAssociation(sessionID: UUID) {
        activeVoiceAssociation = .voice(sessionID: sessionID, generation: 1)
    }

    func prepareLiveVoice(providerProfileID: UUID) async throws {
        await finalizeProviderActivities()
        activeProviderProfileID = providerProfileID
        try await prepareBridge(
            providerProfileID: providerProfileID,
            isVoice: true
        )
    }

    func finishLiveVoice() async {
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
        if activity.phase == .terminal, let event {
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
        if termination != .timeout {
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
        await finalizeProviderActivities()
        let association = CapabilityAssociation.typed(
            conversationID: request.conversationID,
            turnID: request.turnID,
            generation: request.generation
        )
        if kind == .codexOAuth {
            try await prepareBridge(
                providerProfileID: providerProfileID,
                isVoice: false
            )
        }
        admitTypedAssociation(association, providerProfileID: providerProfileID)
        return ReasoningRequest(
            conversationID: request.conversationID,
            turnID: request.turnID,
            generation: request.generation,
            context: request.context,
            userText: request.userText,
            capabilityCatalog: await catalog(providerProfileID: providerProfileID),
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
                    pendingTerminalAudits[event.callID] = event
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
        pendingTerminalAudits[event.callID] = event
        do {
            try await persistTerminalAudit(event, context: context)
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
        providerCallPolicies[callID] = nil
        providerCallStartedAt[callID] = nil
        approvalCanAllowOnce[callID] = nil
    }

    private func cancelActiveRPCWork() {
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
