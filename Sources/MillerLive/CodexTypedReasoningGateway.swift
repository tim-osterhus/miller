import Foundation
import MillerCore

public typealias CodexTypedClientFactory = @Sendable () throws -> CodexAppServerClient

public actor CodexTypedReasoningGateway: ReasoningGateway {
    private struct ActiveRun {
        let requestID: String
        let turnID: TurnID
        let generation: Int
        let client: CodexAppServerClient
        let skillRoot: URL?
        let workspaceRoot: URL
        var cancelled: Bool
    }

    private let makeClient: CodexTypedClientFactory
    private let credential: @Sendable () async throws -> CodexOAuthCredential
    private let model: @Sendable () async throws -> String
    private let cwd: String
    private let timeout: Duration
    private var activeRun: ActiveRun?

    public init(
        makeClient: @escaping CodexTypedClientFactory,
        credential: @escaping @Sendable () async throws -> CodexOAuthCredential,
        model: @escaping @Sendable () async throws -> String,
        cwd: String,
        timeout: Duration = .seconds(120)
    ) {
        self.makeClient = makeClient
        self.credential = credential
        self.model = model
        self.cwd = cwd
        self.timeout = timeout
    }

    public func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        guard activeRun == nil else {
            throw CodexAppServerClientError.sessionAlreadyActive
        }
        let skillParent = URL(fileURLWithPath: cwd, isDirectory: true)
        do {
            try Self.removeStaleSkillRoots(parent: skillParent)
        } catch {
            return Self.cleanupFailureStream()
        }
        let client = try makeClient()
        let requestID = UUID().uuidString.lowercased()
        let workspaceRoot: URL
        do {
            workspaceRoot = try Self.makeRequestWorkspace(
                parent: skillParent, requestID: requestID
            )
        } catch {
            throw error
        }
        activeRun = ActiveRun(
            requestID: requestID,
            turnID: request.turnID,
            generation: request.generation,
            client: client,
            skillRoot: nil,
            workspaceRoot: workspaceRoot,
            cancelled: false
        )
        let credential: CodexOAuthCredential
        let model: String
        do {
            credential = try await self.credential()
            try requireActive(requestID: requestID)
            model = try await self.model()
            try requireActive(requestID: requestID)
        } catch {
            if activeRun?.requestID == requestID { activeRun = nil }
            try? Self.removeRequestWorkspace(workspaceRoot, parent: skillParent)
            throw error
        }
        let context = request.context.map {
            CodexTypedContextMessage(role: $0.role.rawValue, text: $0.text)
        }
        var currentText = request.userText
        if let attachment = request.voiceHistoryAttachment {
            currentText += "\n\nExplicitly selected voice-history attachment:\n"
                + attachment.text
        }
        if let notice = request.portableSkillAttachment?.omissionNotice {
            currentText += "\n\nPortable skill notice: \(notice)"
        }
        let skillRuntime: (root: URL, inputs: [CodexTypedSkillInput])?
        do {
            skillRuntime = try Self.materializeSkills(
                request.portableSkillAttachment,
                parent: workspaceRoot,
                requestID: requestID
            )
        } catch {
            activeRun = nil
            try? Self.removeRequestWorkspace(workspaceRoot, parent: skillParent)
            throw error
        }
        let source = client.typedEvents(
            requestID: requestID,
            credential: credential,
            model: model,
            cwd: workspaceRoot.path,
            context: context,
            userText: currentText,
            skillRoot: skillRuntime?.root.path,
            skills: skillRuntime?.inputs ?? [],
            timeout: timeout
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.accepted)
            if request.portableSkillAttachment?.omittedCount ?? 0 > 0 {
                continuation.yield(.status(.portableSkillsOmitted))
            }
            let task = Task {
                await self.consume(
                    source,
                    run: ActiveRun(
                        requestID: requestID,
                        turnID: request.turnID,
                        generation: request.generation,
                        client: client,
                        skillRoot: skillRuntime?.root,
                        workspaceRoot: workspaceRoot,
                        cancelled: false
                    ),
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in
                Task {
                    await client.interruptTyped()
                    task.cancel()
                }
            }
        }
    }

    public func cancel(_ cancellation: ReasoningCancellation) async {
        guard var run = activeRun,
              run.turnID == cancellation.turnID,
              run.generation == cancellation.targetGeneration
        else { return }
        run.cancelled = true
        activeRun = run
        await run.client.interruptTyped()
    }

    private func consume(
        _ source: AsyncThrowingStream<CodexTypedMessage, Error>,
        run: ActiveRun,
        continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation
    ) async {
        var ordinal = 0
        var eventCount = 0
        var responseScalars = 0
        var activityCalls: [String: CapabilityCallID] = [:]
        do {
            for try await message in source {
                guard isActive(run) else {
                    if cleanupSkillRoot(run, continuation: continuation) {
                        continuation.finish()
                    } else {
                        finishCleanupFailure(continuation)
                    }
                    return
                }
                eventCount += 1
                guard eventCount <= 1_024 else {
                    throw CodexTypedProtocolError.tooManyItems
                }
                switch message {
                case .turnStarted:
                    break
                case .assistantTextDelta(_, _, _, let text):
                    responseScalars += text.unicodeScalars.count
                    guard responseScalars <= 256_000 else {
                        throw CodexTypedProtocolError.textTooLarge
                    }
                    continuation.yield(.textDelta(ordinal: ordinal, text: text))
                    ordinal += 1
                case .assistantMessageCompleted:
                    break
                case let .capabilityActivity(_, _, itemID, kind, phase):
                    let callID = activityCalls[itemID] ?? CapabilityCallID()
                    activityCalls[itemID] = callID
                    continuation.yield(.capabilityLifecycle(
                        try Self.lifecycle(callID: callID, kind: kind, phase: phase)
                    ))
                    if phase != .started { activityCalls[itemID] = nil }
                case .turnCompleted(_, _, .completed):
                    activeRun = nil
                    if cleanupSkillRoot(run, continuation: continuation) {
                        continuation.yield(.completed)
                    } else {
                        continuation.yield(Self.cleanupFailureEvent)
                    }
                    continuation.finish()
                    return
                case .turnCompleted(_, _, .interrupted):
                    activeRun = nil
                    if cleanupSkillRoot(run, continuation: continuation) {
                        continuation.yield(.stopped)
                    } else {
                        continuation.yield(Self.cleanupFailureEvent)
                    }
                    continuation.finish()
                    return
                case .turnCompleted(_, _, .failed):
                    activeRun = nil
                    if cleanupSkillRoot(run, continuation: continuation) {
                        continuation.yield(.failed(
                            code: "provider_unavailable",
                            message: "The reasoning provider is unavailable."
                        ))
                    } else {
                        continuation.yield(Self.cleanupFailureEvent)
                    }
                    continuation.finish()
                    return
                default:
                    throw CodexTypedProtocolError.invalidSequence
                }
            }
            if Task.isCancelled {
                await run.client.interruptTyped()
                activeRun = nil
                if cleanupSkillRoot(run, continuation: continuation) {
                    continuation.finish()
                } else {
                    finishCleanupFailure(continuation)
                }
                return
            }
            activeRun = nil
            if cleanupSkillRoot(run, continuation: continuation) {
                continuation.finish(throwing: CodexAppServerClientError.missingTerminal)
            } else {
                finishCleanupFailure(continuation)
            }
        } catch is CancellationError {
            await run.client.interruptTyped()
            activeRun = nil
            if cleanupSkillRoot(run, continuation: continuation) {
                continuation.finish()
            } else {
                finishCleanupFailure(continuation)
            }
        } catch {
            activeRun = nil
            if cleanupSkillRoot(run, continuation: continuation) {
                continuation.finish(throwing: error)
            } else {
                finishCleanupFailure(continuation)
            }
        }
    }

    private static func materializeSkills(
        _ attachment: PortableSkillAttachment?,
        parent: URL,
        requestID: String
    ) throws -> (root: URL, inputs: [CodexTypedSkillInput])? {
        guard let attachment, !attachment.skills.isEmpty else { return nil }
        let root = parent.appending(path: "portable-skills-\(requestID)")
        guard root.deletingLastPathComponent().standardizedFileURL
                == parent.standardizedFileURL
        else { throw CodexTypedProtocolError.invalidField }
        try FileManager.default.createDirectory(
            at: root.appending(path: "skills"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let inputs = try attachment.skills.map { skill in
                guard !skill.id.isEmpty, skill.id.utf8.count <= 96,
                      skill.id.unicodeScalars.allSatisfy({
                          $0.isASCII && ($0.properties.isAlphabetic
                              || (48...57).contains($0.value) || $0 == "-" || $0 == "_")
                      })
                else { throw CodexTypedProtocolError.invalidField }
                let directory = root.appending(path: "skills/\(skill.id)")
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let file = directory.appending(path: "SKILL.md")
                try Data(skill.markdown.utf8).write(to: file, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                return CodexTypedSkillInput(name: skill.name, path: file.path)
            }
            return (root, inputs)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func cleanupSkillRoot(
        _ run: ActiveRun,
        continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation
    ) -> Bool {
        var success = true
        if let root = run.skillRoot {
            do {
                try Self.removeSkillRoot(root, parent: run.workspaceRoot)
            } catch {
                success = false
            }
        }
        do {
            try Self.removeRequestWorkspace(
                run.workspaceRoot,
                parent: URL(fileURLWithPath: cwd, isDirectory: true)
            )
        } catch {
            success = false
        }
        guard success else {
            continuation.yield(.status(.portableSkillCleanupPending))
            return false
        }
        return true
    }

    private func finishCleanupFailure(
        _ continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation
    ) {
        continuation.yield(Self.cleanupFailureEvent)
        continuation.finish()
    }

    private static let cleanupFailureEvent = ReasoningEvent.failed(
        code: "cleanup_pending",
        message: "Private skill cleanup is pending."
    )

    private static func removeSkillRoot(_ root: URL, parent: URL) throws {
        let trustedParent = parent.standardizedFileURL
        let candidate = root.standardizedFileURL
        guard candidate.deletingLastPathComponent() == trustedParent,
              candidate.lastPathComponent.hasPrefix("portable-skills-")
        else { throw CodexTypedProtocolError.invalidField }
        let values = try candidate.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CodexTypedProtocolError.invalidField
        }
        try FileManager.default.removeItem(at: candidate)
    }

    private static func removeStaleSkillRoots(parent: URL) throws {
        let trustedParent = parent.standardizedFileURL
        guard FileManager.default.fileExists(atPath: trustedParent.path) else { return }
        let values = try trustedParent.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CodexTypedProtocolError.invalidField
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: trustedParent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter { $0.lastPathComponent.hasPrefix("portable-skills-") }
        for child in children {
            try removeSkillRoot(child, parent: trustedParent)
        }
    }

    private static func makeRequestWorkspace(parent: URL, requestID: String) throws -> URL {
        let trustedParent = parent.standardizedFileURL
        guard trustedParent.isFileURL,
              trustedParent.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: trustedParent.path)
        else { throw CodexTypedProtocolError.invalidField }
        let root = trustedParent.appendingPathComponent(
            "miller-typed-request.\(requestID)", isDirectory: true
        )
        guard root.deletingLastPathComponent().standardizedFileURL == trustedParent
        else { throw CodexTypedProtocolError.invalidField }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private static func removeRequestWorkspace(_ root: URL, parent: URL) throws {
        let trustedParent = parent.standardizedFileURL
        let candidate = root.standardizedFileURL
        guard candidate.deletingLastPathComponent() == trustedParent,
              candidate.lastPathComponent.hasPrefix("miller-typed-request.")
        else { throw CodexTypedProtocolError.invalidField }
        let values = try candidate.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CodexTypedProtocolError.invalidField
        }
        try FileManager.default.removeItem(at: candidate)
    }

    private static func cleanupFailureStream()
        -> AsyncThrowingStream<ReasoningEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.yield(.accepted)
            continuation.yield(.status(.portableSkillCleanupPending))
            continuation.yield(cleanupFailureEvent)
            continuation.finish()
        }
    }

    private func isActive(_ run: ActiveRun) -> Bool {
        activeRun?.requestID == run.requestID
            && activeRun?.turnID == run.turnID
            && activeRun?.generation == run.generation
    }

    private func requireActive(requestID: String) throws {
        guard activeRun?.requestID == requestID,
              activeRun?.cancelled == false
        else { throw CancellationError() }
    }

    private static func lifecycle(
        callID: CapabilityCallID,
        kind: CodexTypedCapabilityKind,
        phase: CodexTypedCapabilityPhase
    ) throws -> CapabilityLifecycleEvent {
        let source: CapabilitySource = kind == .webSearch ? .providerNative : .codexAccount
        let capabilityID = try CapabilityID(
            source: source,
            serverID: "codex",
            toolName: kind.rawValue
        )
        let policy = try JSONDecoder().decode(
            EffectiveCapabilityPolicy.self,
            from: Data(#"{"value":"ask_before_changes","requiresApproval":true,"reason":"provider_approval_required"}"#.utf8)
        )
        let outcome: CapabilityTerminalOutcome?
        switch phase {
        case .started: outcome = nil
        case .completed: outcome = .succeeded
        case .failed: outcome = .failed
        }
        return try CapabilityLifecycleEvent(
            callID: callID,
            capabilityID: capabilityID,
            summary: CapabilitySummary(text: "Opaque Codex \(kind.rawValue) activity"),
            state: phase == .started ? .running : .terminal,
            outcome: outcome,
            policy: policy
        )
    }
}
