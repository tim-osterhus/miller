import Foundation
import MillerCore

public enum CapabilityBrokerError: Error, Equatable, Sendable {
    case capabilityUnavailable
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

public actor CapabilityBroker {
    private let configurations: [String: MCPServerConfiguration]
    private var toolPolicies: [CapabilityID: CapabilityPolicy]
    private let sessionFactory: MCPClientSessionFactory
    private let approval: CapabilityApprovalHandler
    private let audit: CapabilityAuditHandler
    private let policyResolver = CapabilityPolicyResolver()
    private let globalGate = AsyncCapacityGate(limit: 4)
    private let serverGates: [String: AsyncCapacityGate]

    private var sessions: [String: any MCPClientSessionProtocol] = [:]
    private var successfulCatalogs: [String: [CapabilityDescriptor]] = [:]
    private var visibleCatalog: [CapabilityID: CapabilityDescriptor] = [:]

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
        var descriptors: [CapabilityDescriptor] = []
        var staleServerIDs = Set<String>()

        for configuration in configurations.values.sorted(by: { $0.id < $1.id }) {
            guard configuration.enabled,
                  !configuration.providerProfileIDs.isEmpty
            else { continue }
            do {
                let session = try await session(for: configuration)
                let tools = try await boundedAsync(
                    timeout: configuration.bounds.startupTimeout,
                    timeoutError: MCPClientSessionError.startupTimedOut
                ) {
                    try await session.listTools()
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
                successfulCatalogs[configuration.id] = serverDescriptors
                descriptors.append(contentsOf: serverDescriptors)
            } catch {
                staleServerIDs.insert(configuration.id)
                if let last = successfulCatalogs[configuration.id] {
                    descriptors.append(contentsOf: last.compactMap {
                        try? CapabilityDescriptor(
                            id: $0.id,
                            source: $0.source,
                            serverID: $0.serverID,
                            toolName: $0.toolName,
                            displayName: $0.displayName,
                            summary: $0.summary,
                            inputSchemaJSON: $0.inputSchemaJSON,
                            readOnlyHint: $0.readOnlyHint,
                            providerProfileIDs: $0.providerProfileIDs,
                            isAvailable: false
                        )
                    })
                }
                await discardSession(serverID: configuration.id)
            }
        }

        descriptors.sort { $0.id.rawValue < $1.id.rawValue }
        visibleCatalog = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.id, $0) }
        )
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

        guard let serverGate = serverGates[configuration.id] else {
            throw CapabilityBrokerError.capabilityUnavailable
        }
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
            let session = try await session(for: configuration)
            let raw = try await boundedAsync(
                timeout: configuration.bounds.callTimeout,
                timeoutError: CapabilityBrokerError.timedOut
            ) {
                try await session.callTool(
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
            await discardSession(serverID: configuration.id)
            await emitCancellation(
                callID: callID, capabilityID: capabilityID,
                policy: resolution.effectivePolicy
            )
            throw CancellationError()
        } catch CapabilityBrokerError.timedOut {
            await globalGate.release()
            await serverGate.release()
            await discardSession(serverID: configuration.id)
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: "tool_call_timed_out", state: .terminal,
                outcome: .timedOut, policy: resolution.effectivePolicy
            )
            throw CapabilityBrokerError.timedOut
        } catch {
            await globalGate.release()
            await serverGate.release()
            await discardSession(serverID: configuration.id)
            await emit(
                callID: callID, capabilityID: capabilityID,
                code: "tool_call_failed", state: .terminal,
                outcome: .failed, policy: resolution.effectivePolicy
            )
            throw CapabilityBrokerError.callFailed
        }
    }

    public func disconnectAll() async {
        let sessions = self.sessions.values
        self.sessions.removeAll()
        for session in sessions { await session.disconnect() }
    }

    private func session(
        for configuration: MCPServerConfiguration
    ) async throws -> any MCPClientSessionProtocol {
        if let existing = sessions[configuration.id] { return existing }
        let created = try await sessionFactory(configuration)
        guard created.serverID == configuration.id else {
            await created.disconnect()
            throw CapabilityBrokerError.callFailed
        }
        sessions[configuration.id] = created
        return created
    }

    private func discardSession(serverID: String) async {
        if let session = sessions.removeValue(forKey: serverID) {
            await session.disconnect()
        }
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
