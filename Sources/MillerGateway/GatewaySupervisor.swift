import Foundation

public struct GatewayProviderProfile: Sendable {
    public let kind: String
    public let baseURL: String?
    public let model: String
    public let credentialReference: UUID

    public init(
        kind: String,
        baseURL: String?,
        model: String,
        credentialReference: UUID
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.credentialReference = credentialReference
    }

    var fields: [String: JSONValue] {
        [
            "kind": .string(kind),
            "base_url": baseURL.map(JSONValue.string) ?? .null,
            "model": .string(model),
            "credential_ref": .string(
                credentialReference.uuidString.lowercased()
            ),
        ]
    }
}

public struct GatewayProviderReadiness: Equatable, Sendable {
    public let status: String
    public let errorCode: String?

    public init(status: String, errorCode: String?) {
        self.status = status
        self.errorCode = errorCode
    }
}

public struct GatewayModelChoice: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct GatewayModelCatalog: Equatable, Sendable {
    public let providerKind: String
    public let defaultModel: String
    public let models: [GatewayModelChoice]

    public init(
        providerKind: String,
        defaultModel: String,
        models: [GatewayModelChoice]
    ) {
        self.providerKind = providerKind
        self.defaultModel = defaultModel
        self.models = models
    }
}

public struct GatewayAuthenticationOperation: Equatable, Sendable {
    public let requestID: UUID
    public let operationID: UUID
    public let generation: Int
    public let credentialReference: UUID

    public init(
        requestID: UUID,
        operationID: UUID,
        generation: Int,
        credentialReference: UUID
    ) {
        self.requestID = requestID
        self.operationID = operationID
        self.generation = generation
        self.credentialReference = credentialReference
    }
}

public enum GatewayAuthenticationEvent: Sendable {
    case openURL(GatewayAuthenticationOperation, URL)
    case credentialCandidate(GatewayAuthenticationOperation, Data)
    case completed(GatewayAuthenticationOperation)
    case stopped(GatewayAuthenticationOperation)
    case failed(GatewayAuthenticationOperation, code: String)
}

public actor GatewaySupervisor {
    private struct ReasoningPending {
        let turnID: String
        let generation: Int
        let continuation: AsyncThrowingStream<GatewayRecord, Error>.Continuation
    }

    private struct ControlPending {
        enum Kind {
            case readiness
            case models
            case authentication(GatewayAuthenticationOperation)
        }

        let kind: Kind
        let continuation: AsyncThrowingStream<GatewayRecord, Error>.Continuation
    }

    private enum Pending {
        case reasoning(ReasoningPending)
        case control(ControlPending)

        var continuation: AsyncThrowingStream<GatewayRecord, Error>.Continuation {
            switch self {
            case let .reasoning(value): value.continuation
            case let .control(value): value.continuation
            }
        }
    }

    private let configuration: GatewayProcess.Configuration
    private let readinessTimeout: Duration
    private let cancellationTimeout: Duration
    private let crashBudget: Int
    private let crashWindow: Duration
    private var process: GatewayProcess?
    private var validator = GatewaySessionValidator()
    private var pending: [String: Pending] = [:]
    private var generation = 0
    private var nextControlGeneration = 0
    private var failures: [ContinuousClock.Instant] = []
    private let clock = ContinuousClock()

    public private(set) var restartCount = 0
    public private(set) var isReady = false

    public init(
        configuration: GatewayProcess.Configuration,
        readinessTimeout: Duration = .seconds(5),
        cancellationTimeout: Duration = .seconds(2),
        crashBudget: Int = 3,
        crashWindow: Duration = .seconds(300)
    ) {
        self.configuration = configuration
        self.readinessTimeout = readinessTimeout
        self.cancellationTimeout = cancellationTimeout
        self.crashBudget = crashBudget
        self.crashWindow = crashWindow
    }

    public func openReasoning(
        requestID: String,
        turnID: String,
        generation requestGeneration: Int,
        fields: [String: JSONValue]
    ) async throws -> AsyncThrowingStream<GatewayRecord, Error> {
        guard pending.isEmpty else {
            throw GatewayProtocolError.invalidSequence
        }
        try await ensureReady()
        guard let sessionID = validator.sessionID, let process else {
            throw GatewayProtocolError.processUnavailable
        }
        let record = try GatewayRecord.make(
            type: "reasoning.start",
            sessionID: sessionID,
            requestID: requestID,
            fields: fields
        )
        let stream = try makeStream()
        try validator.register(
            requestID: requestID,
            turnID: turnID,
            generation: requestGeneration
        )
        pending[requestID] = .reasoning(.init(
            turnID: turnID,
            generation: requestGeneration,
            continuation: stream.continuation
        ))
        do {
            try process.send(record)
        } catch {
            pending.removeValue(forKey: requestID)
            stream.continuation.finish(throwing: error)
            throw error
        }
        return stream.source
    }

    public func providerReadiness(
        profile: GatewayProviderProfile
    ) async throws -> GatewayProviderReadiness {
        let requestID = UUID()
        let source = try await openControl(
            requestID: requestID,
            type: "provider.readiness",
            fields: [
                "provider_profile": .object(profile.fields),
                "credential_ref": .string(
                    profile.credentialReference.uuidString.lowercased()
                ),
            ],
            kind: .readiness
        )
        for try await record in source {
            guard record.type == "provider.readiness_result",
                  let status = record["status"]?.stringValue
            else {
                throw GatewayProtocolError.invalidSequence
            }
            return .init(
                status: status,
                errorCode: record["error_code"]?.stringValue
            )
        }
        throw GatewayProtocolError.invalidSequence
    }

    public func codexModelCatalog() async throws -> GatewayModelCatalog {
        let requestID = UUID()
        let source = try await openControl(
            requestID: requestID,
            type: "provider.models",
            fields: ["provider_kind": .string("codex_oauth")],
            kind: .models
        )
        for try await record in source {
            guard record.type == "provider.models_result",
                  record["provider_kind"]?.stringValue == "codex_oauth",
                  let defaultModel = record["default_model"]?.stringValue,
                  let modelsValue = record["models"]
            else {
                throw GatewayProtocolError.invalidSequence
            }
            let models = try Self.modelChoices(from: modelsValue)
            guard models.filter({ $0.id == defaultModel }).count == 1 else {
                throw GatewayProtocolError.invalidSequence
            }
            return GatewayModelCatalog(
                providerKind: "codex_oauth",
                defaultModel: defaultModel,
                models: models
            )
        }
        throw GatewayProtocolError.invalidSequence
    }

    public func beginAuthentication(
        reference: UUID,
        providerKind: String
    ) async throws -> AsyncThrowingStream<GatewayAuthenticationEvent, Error> {
        try await openAuthentication(
            type: "auth.begin",
            reference: reference,
            additionalFields: ["provider_kind": .string(providerKind)]
        )
    }

    public func refreshAuthentication(
        reference: UUID
    ) async throws -> AsyncThrowingStream<GatewayAuthenticationEvent, Error> {
        try await openAuthentication(
            type: "auth.refresh",
            reference: reference,
            additionalFields: [:]
        )
    }

    public func acknowledgeAuthentication(
        _ operation: GatewayAuthenticationOperation,
        persisted: Bool
    ) async throws {
        guard let sessionID = validator.sessionID,
              let process,
              case let .control(control)? = pending[
                  operation.requestID.uuidString.lowercased()
              ],
              case let .authentication(active) = control.kind,
              active == operation
        else {
            throw GatewayProtocolError.invalidSequence
        }
        let record = try GatewayRecord.make(
            type: persisted ? "auth.persisted" : "auth.persist_failed",
            sessionID: sessionID,
            requestID: operation.requestID.uuidString.lowercased(),
            fields: authenticationFields(operation)
        )
        try process.send(record)
    }

    public func cancelAuthentication(
        _ operation: GatewayAuthenticationOperation
    ) async throws {
        guard let sessionID = validator.sessionID,
              let process,
              case let .control(control)? = pending[
                  operation.requestID.uuidString.lowercased()
              ],
              case let .authentication(active) = control.kind,
              active == operation
        else {
            throw GatewayProtocolError.invalidSequence
        }
        let record = try GatewayRecord.make(
            type: "auth.cancel",
            sessionID: sessionID,
            requestID: operation.requestID.uuidString.lowercased(),
            fields: [
                "operation_id": .string(
                    operation.operationID.uuidString.lowercased()
                ),
                "target_generation": .integer(operation.generation),
            ]
        )
        try process.send(record)
    }

    public func restoreCredential(
        reference: UUID,
        credential: Data
    ) async throws {
        try await runAuthenticationControl(
            type: "auth.restore",
            reference: reference,
            credential: credential
        )
    }

    public func clearCredential(reference: UUID) async throws {
        try await runAuthenticationControl(
            type: "auth.clear",
            reference: reference,
            credential: nil
        )
    }

    public func cancel(turnID: String, targetGeneration: Int) async {
        guard let entry = pending.first(where: {
            guard case let .reasoning(operation) = $0.value else { return false }
            return operation.turnID == turnID && operation.generation == targetGeneration
        }), case let .reasoning(operation) = entry.value,
              let sessionID = validator.sessionID, let process
        else {
            return
        }
        do {
            let record = try GatewayRecord.make(
                type: "reasoning.cancel",
                sessionID: sessionID,
                requestID: entry.key,
                fields: [
                    "turn_id": .string(turnID),
                    "target_generation": .integer(targetGeneration),
                ]
            )
            try process.send(record)
        } catch {
            await handleFailure(
                GatewayProtocolError.processUnavailable,
                generation: generation
            )
            return
        }
        let processGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: self?.cancellationTimeout ?? .seconds(2))
            await self?.expireCancellation(
                requestID: entry.key,
                operation: operation,
                processGeneration: processGeneration
            )
        }
    }

    public func shutdown() async {
        generation += 1
        let old = process
        process = nil
        isReady = false
        finishPending(throwing: GatewayProtocolError.processUnavailable)
        await old?.stop()
    }

    private func openAuthentication(
        type: String,
        reference: UUID,
        additionalFields: [String: JSONValue]
    ) async throws -> AsyncThrowingStream<GatewayAuthenticationEvent, Error> {
        let operation = GatewayAuthenticationOperation(
            requestID: UUID(),
            operationID: UUID(),
            generation: nextControlGeneration,
            credentialReference: reference
        )
        nextControlGeneration += 1
        var fields = authenticationFields(operation)
        fields.merge(additionalFields) { _, new in new }
        let source = try await openControl(
            requestID: operation.requestID,
            type: type,
            fields: fields,
            kind: .authentication(operation)
        )
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await record in source {
                        continuation.yield(
                            try Self.authenticationEvent(
                                record,
                                operation: operation
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runAuthenticationControl(
        type: String,
        reference: UUID,
        credential: Data?
    ) async throws {
        let operation = GatewayAuthenticationOperation(
            requestID: UUID(),
            operationID: UUID(),
            generation: nextControlGeneration,
            credentialReference: reference
        )
        nextControlGeneration += 1
        var fields = authenticationFields(operation)
        if let credential {
            fields["credential"] = try credentialObject(from: credential)
        }
        let source = try await openControl(
            requestID: operation.requestID,
            type: type,
            fields: fields,
            kind: .authentication(operation)
        )
        for try await record in source {
            switch try Self.authenticationEvent(record, operation: operation) {
            case .completed:
                return
            case let .failed(_, code):
                throw GatewayProtocolError.authenticationFailed(code)
            case .stopped:
                throw GatewayProtocolError.invalidSequence
            case .openURL, .credentialCandidate:
                throw GatewayProtocolError.invalidSequence
            }
        }
        throw GatewayProtocolError.invalidSequence
    }

    private func openControl(
        requestID: UUID,
        type: String,
        fields: [String: JSONValue],
        kind: ControlPending.Kind
    ) async throws -> AsyncThrowingStream<GatewayRecord, Error> {
        guard pending.isEmpty else {
            throw GatewayProtocolError.invalidSequence
        }
        try await ensureReady()
        guard let sessionID = validator.sessionID, let process else {
            throw GatewayProtocolError.processUnavailable
        }
        let requestKey = requestID.uuidString.lowercased()
        let record = try GatewayRecord.make(
            type: type,
            sessionID: sessionID,
            requestID: requestKey,
            fields: fields
        )
        let stream = try makeStream()
        pending[requestKey] = .control(.init(
            kind: kind,
            continuation: stream.continuation
        ))
        do {
            try process.send(record)
        } catch {
            pending.removeValue(forKey: requestKey)
            stream.continuation.finish(throwing: error)
            throw error
        }
        return stream.source
    }

    private func ensureReady() async throws {
        pruneFailures()
        guard failures.count < crashBudget else {
            throw GatewayProtocolError.retryCircuitOpen
        }
        if isReady { return }
        if process == nil {
            try await startProcess()
        }
        let deadline = clock.now.advanced(by: readinessTimeout)
        while !isReady, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard isReady else {
            let activeGeneration = generation
            await handleFailure(
                GatewayProtocolError.readinessTimeout,
                generation: activeGeneration
            )
            throw GatewayProtocolError.readinessTimeout
        }
    }

    private func startProcess() async throws {
        generation += 1
        let processGeneration = generation
        let child = GatewayProcess(configuration: configuration)
        let stream = try child.start()
        process = child
        validator = GatewaySessionValidator()
        isReady = false
        Task { [weak self] in
            do {
                for try await record in stream {
                    await self?.receive(
                        record,
                        processGeneration: processGeneration
                    )
                }
                await self?.handleFailure(
                    GatewayProtocolError.processUnavailable,
                    generation: processGeneration
                )
            } catch let error as GatewayProtocolError {
                await self?.handleFailure(error, generation: processGeneration)
            } catch {
                await self?.handleFailure(
                    GatewayProtocolError.processUnavailable,
                    generation: processGeneration
                )
            }
        }
    }

    private func receive(
        _ record: GatewayRecord,
        processGeneration: Int
    ) async {
        guard processGeneration == generation else { return }
        do {
            if record.type == "gateway.ready" {
                try validator.accept(record)
                isReady = true
                return
            }
            guard let requestID = record.requestID,
                  let operation = pending[requestID]
            else {
                throw GatewayProtocolError.invalidSequence
            }
            switch operation {
            case let .reasoning(reasoning):
                try validator.accept(record)
                reasoning.continuation.yield(record)
                if Self.reasoningTerminalTypes.contains(record.type) {
                    reasoning.continuation.finish()
                    pending.removeValue(forKey: requestID)
                }
            case let .control(control):
                try validate(record, control: control)
                control.continuation.yield(record)
                if Self.controlTerminalTypes.contains(record.type) {
                    control.continuation.finish()
                    pending.removeValue(forKey: requestID)
                }
            }
        } catch let error as GatewayProtocolError {
            await handleFailure(error, generation: processGeneration)
        } catch {
            await handleFailure(
                GatewayProtocolError.invalidSequence,
                generation: processGeneration
            )
        }
    }

    private func validate(
        _ record: GatewayRecord,
        control: ControlPending
    ) throws {
        guard record.sessionID == validator.sessionID else {
            throw GatewayProtocolError.invalidSequence
        }
        switch control.kind {
        case .readiness:
            guard record.type == "provider.readiness_result" else {
                throw GatewayProtocolError.invalidSequence
            }
        case .models:
            guard record.type == "provider.models_result",
                  record["provider_kind"]?.stringValue == "codex_oauth"
            else {
                throw GatewayProtocolError.invalidSequence
            }
        case let .authentication(operation):
            guard [
                "auth.open_url", "auth.credential_candidate", "auth.completed",
                "auth.stopped", "auth.failed",
            ].contains(record.type),
            record["operation_id"]?.stringValue
                == operation.operationID.uuidString.lowercased(),
            record["generation"]?.integerValue == operation.generation
            else {
                throw GatewayProtocolError.invalidSequence
            }
            if let reference = record["credential_ref"]?.stringValue,
               reference != operation.credentialReference.uuidString.lowercased()
            {
                throw GatewayProtocolError.invalidSequence
            }
        }
    }

    private func expireCancellation(
        requestID: String,
        operation: ReasoningPending,
        processGeneration: Int
    ) async {
        guard generation == processGeneration,
              pending[requestID] != nil
        else {
            return
        }
        operation.continuation.finish(
            throwing: GatewayProtocolError.cancellationTimeout
        )
        pending.removeValue(forKey: requestID)
        await handleFailure(
            GatewayProtocolError.cancellationTimeout,
            generation: processGeneration
        )
    }

    private func handleFailure(
        _ error: GatewayProtocolError,
        generation failedGeneration: Int
    ) async {
        guard failedGeneration == generation else { return }
        generation += 1
        isReady = false
        failures.append(clock.now)
        pruneFailures()
        finishPending(throwing: error)
        let old = process
        process = nil
        await old?.stop()
        restartCount += 1
        if failures.count < crashBudget {
            try? await startProcess()
        }
    }

    private func finishPending(throwing error: Error) {
        for operation in pending.values {
            operation.continuation.finish(throwing: error)
        }
        pending.removeAll()
    }

    private func pruneFailures() {
        let cutoff = clock.now.advanced(by: .zero - crashWindow)
        failures.removeAll { $0 < cutoff }
    }

    private func makeStream() throws -> (
        source: AsyncThrowingStream<GatewayRecord, Error>,
        continuation: AsyncThrowingStream<GatewayRecord, Error>.Continuation
    ) {
        var captured: AsyncThrowingStream<GatewayRecord, Error>.Continuation?
        let source = AsyncThrowingStream<GatewayRecord, Error> {
            captured = $0
        }
        guard let captured else {
            throw GatewayProtocolError.processUnavailable
        }
        return (source, captured)
    }

    private func authenticationFields(
        _ operation: GatewayAuthenticationOperation
    ) -> [String: JSONValue] {
        [
            "operation_id": .string(operation.operationID.uuidString.lowercased()),
            "generation": .integer(operation.generation),
            "credential_ref": .string(
                operation.credentialReference.uuidString.lowercased()
            ),
        ]
    }

    private func credentialObject(from data: Data) throws -> JSONValue {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GatewayProtocolError.invalidField
        }
        guard let object = value as? [String: Any] else {
            throw GatewayProtocolError.invalidField
        }
        return try JSONValue(foundation: object)
    }

    private static func modelChoices(
        from value: JSONValue
    ) throws -> [GatewayModelChoice] {
        guard case let .array(values) = value else {
            throw GatewayProtocolError.invalidField
        }
        return try values.map { value in
            guard case let .object(choice) = value,
                  Set(choice.keys) == ["id", "name"],
                  let id = choice["id"]?.stringValue,
                  let name = choice["name"]?.stringValue
            else {
                throw GatewayProtocolError.invalidField
            }
            return GatewayModelChoice(id: id, name: name)
        }
    }

    private static func authenticationEvent(
        _ record: GatewayRecord,
        operation: GatewayAuthenticationOperation
    ) throws -> GatewayAuthenticationEvent {
        switch record.type {
        case "auth.open_url":
            guard let raw = record["url"]?.stringValue,
                  let url = URL(string: raw),
                  url.scheme == "https" || isLoopbackHTTP(url)
            else {
                throw GatewayProtocolError.invalidField
            }
            return .openURL(operation, url)
        case "auth.credential_candidate":
            guard let credential = record["credential"] else {
                throw GatewayProtocolError.invalidField
            }
            let data = try JSONSerialization.data(
                withJSONObject: credential.foundationValue,
                options: [.sortedKeys]
            )
            return .credentialCandidate(operation, data)
        case "auth.completed":
            return .completed(operation)
        case "auth.stopped":
            return .stopped(operation)
        case "auth.failed":
            return .failed(
                operation,
                code: record["error_code"]?.stringValue ?? "authentication_failed"
            )
        default:
            throw GatewayProtocolError.invalidSequence
        }
    }

    private static func isLoopbackHTTP(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static let reasoningTerminalTypes: Set<String> = [
        "reasoning.completed", "reasoning.stopped", "reasoning.failed",
    ]

    private static let controlTerminalTypes: Set<String> = [
        "provider.readiness_result", "provider.models_result", "auth.completed",
        "auth.stopped", "auth.failed",
    ]
}
