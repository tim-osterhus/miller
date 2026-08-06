import Foundation
import MillerCore

public enum CapabilityBrokerError: Error, Equatable, Sendable {
    case capabilityUnavailable
    case duplicateCallID
    case invalidArguments
    case argumentsTooLarge
    case declined
    case timedOut
    case callFailed
}

public struct CapabilityBrokerCatalog: Equatable, Sendable {
    public let descriptors: [CapabilityDescriptor]
    public let staleServerIDs: Set<String>

    public init(
        descriptors: [CapabilityDescriptor],
        staleServerIDs: Set<String>
    ) {
        self.descriptors = descriptors
        self.staleServerIDs = staleServerIDs
    }
}

public typealias MCPClientSessionFactory = @Sendable (
    MCPServerConfiguration
) async throws -> any MCPClientSessionProtocol

public typealias CapabilityApprovalHandler = @Sendable (
    CapabilityApprovalRequest
) async -> CapabilityApprovalDecision

public typealias CapabilityAuditHandler = @Sendable (
    CapabilityLifecycleEvent
) async -> Void

private struct SessionLease: Sendable {
    let token: UUID
    let session: any MCPClientSessionProtocol
}

private struct PendingConnection: Sendable {
    let token: UUID
    let lifecycleGeneration: UInt64
    let task: Task<any MCPClientSessionProtocol, Error>
}

public actor CapabilityBroker {
    public nonisolated static let maximumCatalogRows = 2_048

    private let configurations: [String: MCPServerConfiguration]
    private var toolPolicies: [CapabilityID: CapabilityPolicy]
    private let sessionFactory: MCPClientSessionFactory
    private let approval: CapabilityApprovalHandler
    private let audit: CapabilityAuditHandler
    private let policyResolver = CapabilityPolicyResolver()
    private let globalGate = AsyncCapacityGate(limit: 4)
    private let serverGates: [String: AsyncCapacityGate]

    private var sessions: [String: SessionLease] = [:]
    private var pendingConnections: [String: PendingConnection] = [:]
    private var lifecycleGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var successfulCatalogs: [String: [CapabilityDescriptor]] = [:]
    private var visibleCatalog: [CapabilityID: CapabilityDescriptor] = [:]
    private var visibleStaleServerIDs = Set<String>()
    private var activeCallIDs = Set<CapabilityCallID>()
    private var completedCallIDs = Set<CapabilityCallID>()

    public init(
        configurations: [MCPServerConfiguration],
        toolPolicies: [CapabilityID: CapabilityPolicy] = [:],
        credentialResolver: @escaping MCPCredentialResolver = { _ in
            throw CapabilityBrokerError.callFailed
        },
        sessionFactory: MCPClientSessionFactory? = nil,
        approval: @escaping CapabilityApprovalHandler,
        audit: @escaping CapabilityAuditHandler
    ) throws {
        try MCPServerConfiguration.validateUnique(configurations)
        self.configurations = Dictionary(
            uniqueKeysWithValues: configurations.map { ($0.id, $0) }
        )
        self.toolPolicies = toolPolicies
        self.approval = approval
        self.audit = audit
        self.serverGates = Dictionary(
            uniqueKeysWithValues: configurations.map {
                ($0.id, AsyncCapacityGate(limit: 1))
            }
        )
        self.sessionFactory = sessionFactory ?? { configuration in
            try await MCPClientSession.connect(
                configuration: configuration,
                credentialResolver: credentialResolver
            )
        }
    }

    public func setToolPolicy(
        _ policy: CapabilityPolicy?,
        for capabilityID: CapabilityID
    ) {
        toolPolicies[capabilityID] = policy
    }

    public func refresh() async -> CapabilityBrokerCatalog {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let baselineCatalogs = successfulCatalogs
        var stagedCatalogs = baselineCatalogs
        var descriptors: [CapabilityDescriptor] = []
        var staleServerIDs = Set<String>()

        for configuration in configurations.values.sorted(by: { $0.id < $1.id }) {
            guard configuration.enabled,
                  !configuration.providerProfileIDs.isEmpty
            else { continue }
            var attemptedLease: SessionLease?
            do {
                let lease = try await session(for: configuration)
                attemptedLease = lease
                let tools = try await boundedAsync(
                    timeout: configuration.bounds.startupTimeout,
                    timeoutError: MCPClientSessionError.startupTimedOut
                ) {
                    try await lease.session.listTools()
                }
                guard tools.count <= configuration.bounds.maximumTools else {
                    throw MCPClientSessionError.tooManyTools
                }
                var serverDescriptors: [CapabilityDescriptor] = []
                var capabilityIDs = Set<CapabilityID>()
                serverDescriptors.reserveCapacity(tools.count)
                for tool in tools {
                    guard tool.inputSchemaJSON.count <= configuration.bounds.maximumSchemaBytes,
                          Self.isJSONObject(tool.inputSchemaJSON)
                    else { throw MCPClientSessionError.schemaTooLarge }
                    let id = try CapabilityID(
                        source: .millerMCP,
                        serverID: configuration.id,
                        toolName: tool.name
                    )
                    guard capabilityIDs.insert(id).inserted else {
                        throw MCPClientSessionError.invalidTool
                    }
                    serverDescriptors.append(try CapabilityDescriptor(
                        id: id,
                        source: .millerMCP,
                        serverID: configuration.id,
                        toolName: tool.name,
                        displayName: Self.bound(tool.displayName, bytes: 256),
                        summary: Self.bound(tool.summary, bytes: 1_024),
                        inputSchemaJSON: tool.inputSchemaJSON,
                        readOnlyHint: tool.readOnlyHint,
                        providerProfileIDs: configuration.providerProfileIDs,
                        isAvailable: true
                    ))
                }
                serverDescriptors.sort { $0.id.rawValue < $1.id.rawValue }
                stagedCatalogs[configuration.id] = serverDescriptors
                descriptors.append(contentsOf: serverDescriptors)
            } catch {
                if let attemptedLease,
                   Self.isTerminalTransportFailure(error)
                {
                    await discardSession(attemptedLease)
                }
                staleServerIDs.insert(configuration.id)
                if let last = baselineCatalogs[configuration.id] {
                    descriptors.append(contentsOf: last.compactMap(Self.unavailable))
                }
            }
        }

        descriptors.sort { $0.id.rawValue < $1.id.rawValue }
        guard generation == refreshGeneration else {
            return currentCatalog()
        }
        guard descriptors.count <= Self.maximumCatalogRows else {
            let enabledServerIDs = Set(configurations.values.compactMap {
                $0.enabled && !$0.providerProfileIDs.isEmpty ? $0.id : nil
            })
            let unavailable = visibleCatalog.values.compactMap(Self.unavailable)
                .sorted { $0.id.rawValue < $1.id.rawValue }
            visibleCatalog = Dictionary(
                uniqueKeysWithValues: unavailable.map { ($0.id, $0) }
            )
            visibleStaleServerIDs = enabledServerIDs
            return CapabilityBrokerCatalog(
                descriptors: unavailable, staleServerIDs: enabledServerIDs
            )
        }
        successfulCatalogs = stagedCatalogs
        visibleCatalog = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.id, $0) }
        )
        visibleStaleServerIDs = staleServerIDs
        return CapabilityBrokerCatalog(
            descriptors: descriptors,
            staleServerIDs: staleServerIDs
        )
    }

    public func catalog(providerProfileID: UUID) -> [CapabilityDescriptor] {
        visibleCatalog.values
            .filter { $0.isAvailable(to: providerProfileID) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func call(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        argumentsJSON: Data,
        providerProfileID: UUID
    ) async throws -> SanitizedCapabilityResult {
        guard let descriptor = visibleCatalog[capabilityID],
              descriptor.isAvailable(to: providerProfileID),
              let configuration = configurations[descriptor.serverID],
              configuration.enabled
        else { throw CapabilityBrokerError.capabilityUnavailable }
        guard argumentsJSON.count <= configuration.bounds.maximumArgumentBytes else {
            throw CapabilityBrokerError.argumentsTooLarge
        }
        guard Self.isJSONObject(argumentsJSON) else {
            throw CapabilityBrokerError.invalidArguments
        }

        let resolution = policyResolver.resolve(
            serverPolicy: configuration.defaultPolicy,
            toolOverride: toolPolicies[capabilityID],
            readOnlyHint: descriptor.readOnlyHint
        )
        guard let serverGate = serverGates[configuration.id] else {
            throw CapabilityBrokerError.capabilityUnavailable
        }

        // Completed IDs are retained for this broker's lifetime so replay never
        // becomes valid again. This intentionally trades linear identity memory
        // for an unbounded process-lifetime call budget and exact replay safety.
        try reserve(callID: callID)
        defer { complete(callID: callID) }
        await emit(
            callID: callID, capabilityID: capabilityID,
            code: "tool_call_started", state: .started,
            outcome: nil, policy: resolution.effectivePolicy
        )

        switch resolution.decision {
        case .decline:
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: "tool_call_policy_disabled", state: .terminal,
                outcome: .declined, policy: resolution.effectivePolicy
            )
            throw CapabilityBrokerError.declined
        case .requestApproval:
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: "tool_call_approval_required", state: .awaitingApproval,
                outcome: nil, policy: resolution.effectivePolicy
            )
            let request = try CapabilityApprovalRequest(
                callID: callID,
                capabilityID: capabilityID,
                summary: CapabilitySummary(text: "tool_call_approval_required"),
                policy: resolution.effectivePolicy
            )
            guard await approval(request) == .allowOnce else {
                await emit(
                    callID: callID, capabilityID: capabilityID,
                    code: "tool_call_declined", state: .terminal,
                    outcome: .declined, policy: resolution.effectivePolicy
                )
                throw CapabilityBrokerError.declined
            }
        case .executeAutomatically:
            break
        }

        var callLease: SessionLease?
        do {
            try await serverGate.acquire()
        } catch {
            await emitCancellation(
                callID: callID, capabilityID: capabilityID,
                policy: resolution.effectivePolicy
            )
            throw error
        }
        do {
            try await globalGate.acquire()
        } catch {
            await serverGate.release()
            await emitCancellation(
                callID: callID, capabilityID: capabilityID,
                policy: resolution.effectivePolicy
            )
            throw error
        }

        do {
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: "tool_call_running", state: .running,
                outcome: nil, policy: resolution.effectivePolicy
            )
            let lease = try await session(for: configuration)
            callLease = lease
            let raw = try await boundedAsync(
                timeout: configuration.bounds.callTimeout,
                timeoutError: CapabilityBrokerError.timedOut
            ) {
                try await lease.session.callTool(
                    name: descriptor.toolName,
                    argumentsJSON: argumentsJSON
                )
            }
            let result = try CapabilityResultSanitizer(
                maximumResultBytes: configuration.bounds.maximumResultBytes
            ).project(contentJSON: raw.contentJSON, isError: raw.isError)
            await globalGate.release()
            await serverGate.release()
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: result.auditSummary.text, state: .terminal,
                outcome: result.isError ? .failed : .succeeded,
                policy: resolution.effectivePolicy
            )
            return result
        } catch is CancellationError {
            await globalGate.release()
            await serverGate.release()
            if let lease = callLease {
                await discardSession(lease)
            }
            await emitCancellation(
                callID: callID, capabilityID: capabilityID,
                policy: resolution.effectivePolicy
            )
            throw CancellationError()
        } catch CapabilityBrokerError.timedOut {
            await globalGate.release()
            await serverGate.release()
            if let lease = callLease {
                await discardSession(lease)
            }
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: "tool_call_timed_out", state: .terminal,
                outcome: .timedOut, policy: resolution.effectivePolicy
            )
            throw CapabilityBrokerError.timedOut
        } catch {
            await globalGate.release()
            await serverGate.release()
            if let lease = callLease {
                await discardSession(lease)
            }
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: "tool_call_failed", state: .terminal,
                outcome: .failed, policy: resolution.effectivePolicy
            )
            throw CapabilityBrokerError.callFailed
        }
    }

    public func disconnectAll() async {
        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        let pending = pendingConnections.values.map(\.task)
        pendingConnections.removeAll()
        let sessions = self.sessions.values.map(\.session)
        self.sessions.removeAll()
        successfulCatalogs.removeAll()
        visibleCatalog.removeAll()
        visibleStaleServerIDs.removeAll()
        for task in pending { task.cancel() }
        await disconnectConcurrently(sessions, maximumParallel: 4)
    }

    private func session(
        for configuration: MCPServerConfiguration
    ) async throws -> SessionLease {
        if let existing = sessions[configuration.id] { return existing }
        let pending: PendingConnection
        if let existing = pendingConnections[configuration.id] {
            pending = existing
        } else {
            let token = UUID()
            let factory = sessionFactory
            let task = Task { try await factory(configuration) }
            pending = PendingConnection(
                token: token,
                lifecycleGeneration: lifecycleGeneration,
                task: task
            )
            pendingConnections[configuration.id] = pending
        }

        let created: any MCPClientSessionProtocol
        do {
            created = try await pending.task.value
        } catch {
            if pendingConnections[configuration.id]?.token == pending.token {
                pendingConnections.removeValue(forKey: configuration.id)
            }
            throw error
        }

        if let installed = sessions[configuration.id], installed.token == pending.token {
            return installed
        }
        guard pendingConnections[configuration.id]?.token == pending.token,
              pending.lifecycleGeneration == lifecycleGeneration
        else {
            await created.disconnect()
            throw CancellationError()
        }
        pendingConnections.removeValue(forKey: configuration.id)
        guard created.serverID == configuration.id else {
            await created.disconnect()
            throw CapabilityBrokerError.callFailed
        }
        let lease = SessionLease(token: pending.token, session: created)
        sessions[configuration.id] = lease
        return lease
    }

    private func discardSession(_ lease: SessionLease) async {
        guard sessions[lease.session.serverID]?.token == lease.token else { return }
        sessions.removeValue(forKey: lease.session.serverID)
        await lease.session.disconnect()
    }

    private func reserve(callID: CapabilityCallID) throws {
        guard !activeCallIDs.contains(callID), !completedCallIDs.contains(callID) else {
            throw CapabilityBrokerError.duplicateCallID
        }
        activeCallIDs.insert(callID)
    }

    private func complete(callID: CapabilityCallID) {
        guard activeCallIDs.remove(callID) != nil else { return }
        completedCallIDs.insert(callID)
    }

    private func currentCatalog() -> CapabilityBrokerCatalog {
        CapabilityBrokerCatalog(
            descriptors: visibleCatalog.values.sorted {
                $0.id.rawValue < $1.id.rawValue
            },
            staleServerIDs: visibleStaleServerIDs
        )
    }

    private func emitCancellation(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        policy: EffectiveCapabilityPolicy
    ) async {
        await emit(
            callID: callID, capabilityID: capabilityID,
            code: "tool_call_cancelled", state: .terminal,
            outcome: .cancelled, policy: policy
        )
    }

    private func emit(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        code: String,
        state: CapabilityLifecycleState,
        outcome: CapabilityTerminalOutcome?,
        policy: EffectiveCapabilityPolicy
    ) async {
        guard let summary = try? CapabilitySummary(text: code),
              let event = try? CapabilityLifecycleEvent(
                callID: callID, capabilityID: capabilityID,
                summary: summary, state: state,
                outcome: outcome, policy: policy
              )
        else { return }
        await audit(event)
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        guard data.count <= 256 * 1_024,
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return value is [String: Any]
    }

    private static func bound(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        for scalar in text.unicodeScalars {
            let candidate = result + String(scalar)
            guard candidate.utf8.count <= bytes else { break }
            result = candidate
        }
        return result
    }

    static func unavailable(
        _ descriptor: CapabilityDescriptor
    ) -> CapabilityDescriptor? {
        try? CapabilityDescriptor(
            id: descriptor.id,
            source: descriptor.source,
            serverID: descriptor.serverID,
            toolName: descriptor.toolName,
            displayName: descriptor.displayName,
            summary: descriptor.summary,
            inputSchemaJSON: descriptor.inputSchemaJSON,
            readOnlyHint: descriptor.readOnlyHint,
            providerProfileIDs: descriptor.providerProfileIDs,
            isAvailable: false,
            isAccessible: descriptor.isAccessible,
            isEnabled: descriptor.isEnabled,
            isCallable: descriptor.isCallable,
            visibility: descriptor.visibility
        )
    }

    private static func isTerminalTransportFailure(_ error: any Error) -> Bool {
        guard let error = error as? MCPClientSessionError else { return false }
        switch error {
        case .connectionClosed, .notConnected:
            return true
        default:
            return false
        }
    }
}

private func disconnectConcurrently(
    _ sessions: [any MCPClientSessionProtocol],
    maximumParallel: Int
) async {
    await withTaskGroup(of: Void.self) { group in
        var iterator = sessions.makeIterator()
        for _ in 0..<min(maximumParallel, sessions.count) {
            guard let session = iterator.next() else { break }
            group.addTask { await session.disconnect() }
        }
        while await group.next() != nil {
            if let session = iterator.next() {
                group.addTask { await session.disconnect() }
            }
        }
    }
}

private actor AsyncCapacityGate {
    private let limit: Int
    private var active = 0

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        while active >= limit {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
        try Task.checkCancellation()
        active += 1
    }

    func release() {
        precondition(active > 0)
        active -= 1
    }
}
