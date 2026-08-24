import Foundation

@testable import MillerLive

enum LiveTextCompatibilityFrameError: Error, Equatable, Sendable {
    case frameTooLarge
    case malformed
    case invalid
    case payloadTooLarge
}

enum LiveTextCompatibilityAcknowledgement: Equatable, Sendable {
    case success(id: String)
    case failure(id: String, code: Int)

    var id: String {
        switch self {
        case let .success(id), let .failure(id, _): id
        }
    }
}

struct LiveTextCompatibilityInitialItem: Equatable, Sendable {
    let role: String
    let text: String
}

enum LiveTextCompatibilityFrame {
    static let maximumFrameBytes = 4_096
    static let maximumTextBytes = 768

    static func appendTextRequest(
        id: String,
        threadID: String,
        text: String,
        role: String
    ) throws -> Data {
        guard !id.isEmpty, id.utf8.count <= 128,
              !threadID.isEmpty, threadID.utf8.count <= 128,
              !text.isEmpty, text.utf8.count <= maximumTextBytes,
              ["user", "developer", "assistant"].contains(role)
        else { throw LiveTextCompatibilityFrameError.payloadTooLarge }
        return try encode([
            "id": id,
            "method": "thread/realtime/appendText",
            "params": [
                "role": role,
                "text": text,
                "threadId": threadID,
            ] as [String: Any],
        ])
    }

    static func realtimeStartRequest(
        id: String,
        threadID: String,
        initialItems: [LiveTextCompatibilityInitialItem] = []
    ) throws -> Data {
        let encodedItems = initialItems.map {
            ["role": $0.role, "text": $0.text]
        }
        guard initialItems.allSatisfy({
            ["user", "developer", "assistant"].contains($0.role)
                && !$0.text.isEmpty
                && $0.text.utf8.count <= maximumTextBytes
        }) else { throw LiveTextCompatibilityFrameError.payloadTooLarge }
        return try encode([
            "id": id,
            "method": "thread/realtime/start",
            "params": [
                "initialItems": encodedItems,
                "model": GPTLiveModel.codex.rawValue,
                "outputModality": "audio",
                "prompt": "synthetic-prompt",
                "realtimeSessionId": NSNull(),
                "threadId": threadID,
                "transport": ["type": "websocket"],
                "version": "v3",
                "voice": NSNull(),
            ] as [String: Any],
        ])
    }

    static func stopRequest(id: String, threadID: String) -> Data {
        (try? encodeUnchecked([
            "id": id,
            "method": "thread/realtime/stop",
            "params": ["threadId": threadID],
        ])) ?? Data()
    }

    static func malformedAppendTextRequest(id: String, threadID: String) -> Data {
        rawAppendTextRequest(
            id: id,
            threadID: threadID,
            text: "synthetic-input",
            role: nil
        )
    }

    static func oversizedAppendTextRequest(id: String, threadID: String) -> Data {
        rawAppendTextRequest(
            id: id,
            threadID: threadID,
            text: String(repeating: "x", count: maximumTextBytes + 1),
            role: "user"
        )
    }

    static func decodeAcknowledgement(
        _ data: Data
    ) throws -> LiveTextCompatibilityAcknowledgement {
        guard data.count <= maximumFrameBytes else {
            throw LiveTextCompatibilityFrameError.frameTooLarge
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw LiveTextCompatibilityFrameError.malformed }
        guard let root = object as? [String: Any],
              let id = root["id"] as? String
        else { throw LiveTextCompatibilityFrameError.malformed }
        if let result = root["result"] {
            guard root.keys.sorted() == ["id", "result"],
                  let result = result as? [String: Any], result.isEmpty
            else { throw LiveTextCompatibilityFrameError.invalid }
            return .success(id: id)
        }
        guard root.keys.sorted() == ["error", "id"],
              let error = root["error"] as? [String: Any],
              error.keys.sorted() == ["code", "message"],
              let code = error["code"] as? Int,
              let message = error["message"] as? String,
              !message.isEmpty,
              message.utf8.count <= maximumTextBytes
        else { throw LiveTextCompatibilityFrameError.invalid }
        return .failure(id: id, code: code)
    }

    private static func rawAppendTextRequest(
        id: String,
        threadID: String,
        text: String,
        role: String?
    ) -> Data {
        var params: [String: Any] = ["text": text, "threadId": threadID]
        if let role { params["role"] = role }
        return (try? encodeUnchecked([
            "id": id,
            "method": "thread/realtime/appendText",
            "params": params,
        ])) ?? Data()
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        let data = try encodeUnchecked(object)
        guard data.count <= maximumFrameBytes else {
            throw LiveTextCompatibilityFrameError.frameTooLarge
        }
        return data
    }

    private static func encodeUnchecked(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
    }
}

enum LiveTextCompatibilityAppendDisposition: Equatable, Sendable {
    case registered
    case accepted
    case rejected(code: Int)
    case late
    case cancelled
    case duplicate
}

struct LiveTextCompatibilityLedger: Sendable {
    private var pending = Set<String>()
    private var expired = Set<String>()
    private var cancelled = Set<String>()
    private var completed = Set<String>()

    mutating func register(_ id: String) -> LiveTextCompatibilityAppendDisposition {
        guard pending.insert(id).inserted else { return .duplicate }
        return .registered
    }

    mutating func expire(_ id: String) {
        pending.remove(id)
        expired.insert(id)
    }

    mutating func cancel(_ id: String) {
        pending.remove(id)
        cancelled.insert(id)
    }

    mutating func observe(
        _ acknowledgement: LiveTextCompatibilityAcknowledgement
    ) -> LiveTextCompatibilityAppendDisposition {
        let id = acknowledgement.id
        if completed.contains(id) { return .duplicate }
        if expired.contains(id) { return .late }
        if cancelled.contains(id) { return .cancelled }
        guard pending.remove(id) != nil else { return .duplicate }
        completed.insert(id)
        switch acknowledgement {
        case .success:
            return .accepted
        case let .failure(_, code):
            return .rejected(code: code)
        }
    }
}

enum LiveTextCompatibilityScenario: String, CaseIterable, Equatable, Sendable {
    case accepted
    case rejected
    case malformed
    case oversized
    case late
    case cancelled
    case duplicate
}

enum LiveTextCompatibilityObservation: Equatable, Sendable {
    case startAcknowledged
    case realtimeStarted
    case assistantOutputActive
    case appendPending
    case appendAcknowledged
    case appendRejected
    case appendLate
    case appendCancelled
    case duplicateFrame
    case echo
    case stopAcknowledged
    case closed
}

struct LiveTextCompatibilityProbeResult: Equatable, Sendable {
    let scenario: LiveTextCompatibilityScenario
    let outcome: LiveTextCompatibilityAppendDisposition
    let observations: [LiveTextCompatibilityObservation]
    let temporaryRootWasRemoved: Bool
    let childWasStopped: Bool
}

enum LiveTextCompatibilityExternalStage: Equatable, Sendable {
    case initialized
    case threadStartAccepted
    case threadStartRejected(code: Int)
    case threadStartClosed
    case threadStartErrored
    case threadStartUnexpected
    case realtimeStartAccepted
    case realtimeStartRejected(code: Int)
    case realtimeStartErrored
    case appendTextAccepted
    case appendTextRejected(code: Int)
}

struct LiveTextCompatibilityExternalProbeResult: Equatable, Sendable {
    let stage: LiveTextCompatibilityExternalStage
    let temporaryRootWasRemoved: Bool
    let childWasStopped: Bool
}

enum LiveTextCompatibilityHarness {
    static let maximumThreadIDBytes = 128

    static func dynamicThreadID(
        from message: CodexAppServerMessage
    ) throws -> String {
        guard case let .threadStartResponse(_, threadID) = message,
              !threadID.isEmpty
        else { throw LiveTextCompatibilityFrameError.invalid }
        guard threadID.utf8.count <= maximumThreadIDBytes else {
            throw LiveTextCompatibilityFrameError.payloadTooLarge
        }
        guard UUID(uuidString: threadID) != nil else {
            throw LiveTextCompatibilityFrameError.invalid
        }
        return threadID
    }

    static func installedVersion(executableURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LiveTextCompatibilityFrameError.invalid
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func probeInstalledRuntime(
        executableURL: URL,
        temporaryParent: URL
    ) async throws -> LiveTextCompatibilityExternalProbeResult {
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: executableURL,
            arguments: ["app-server", "--listen", "stdio://", "--strict-config"],
            temporaryParentURL: temporaryParent,
            terminationGrace: .milliseconds(100)
        ))
        let root = process.temporaryRootURL
        var stage: LiveTextCompatibilityExternalStage = .initialized
        do {
            let stream = try process.start()
            var iterator = stream.makeAsyncIterator()
            let codec = CodexAppServerProtocol()
            try process.send(try codec.initializeRequest(id: "external:initialize"))
            let initialize = try await nextControlMessage(&iterator, codec: codec)
            guard case .initializeResponse(id: "external:initialize") = initialize else {
                throw LiveTextCompatibilityFrameError.invalid
            }
            try process.send(try codec.initializedNotification())
            try process.send(try codec.threadStartRequest(
                id: "external:thread-start",
                cwd: root.path
            ))
            let threadStart = try await nextControlMessage(&iterator, codec: codec)
            if case let .requestError(_, code, _) = threadStart {
                stage = .threadStartRejected(code: code)
            } else if case .threadStartResponse(
                id: "external:thread-start", threadID: _
            ) = threadStart {
                let threadID = try dynamicThreadID(from: threadStart)
                stage = .threadStartAccepted
                try process.send(try LiveTextCompatibilityFrame.realtimeStartRequest(
                    id: "external:start",
                    threadID: threadID,
                    initialItems: [.init(role: "user", text: "synthetic-history")]
                ))
                let realtimeStart = try await nextControlMessage(&iterator, codec: codec)
                if case let .requestError(_, code, _) = realtimeStart {
                    stage = .realtimeStartRejected(code: code)
                } else if case .emptyResponse(id: "external:start") = realtimeStart {
                    let realtimeStarted = try await nextControlMessage(&iterator, codec: codec)
                    if case .error(threadID: threadID, message: _) = realtimeStarted {
                        stage = .realtimeStartErrored
                    } else if case .started(threadID: threadID, version: .v3) = realtimeStarted {
                        stage = .realtimeStartAccepted
                        try process.send(try LiveTextCompatibilityFrame.appendTextRequest(
                            id: "external:append",
                            threadID: threadID,
                            text: "synthetic-input",
                            role: "user"
                        ))
                        let append = try await nextControlMessage(&iterator, codec: codec)
                        if case let .requestError(_, code, _) = append {
                            stage = .appendTextRejected(code: code)
                        } else if case .emptyResponse(id: "external:append") = append {
                            stage = .appendTextAccepted
                        }
                    } else {
                        throw LiveTextCompatibilityFrameError.invalid
                    }
                }
            } else if case .closed = threadStart {
                stage = .threadStartClosed
            } else if case .error = threadStart {
                stage = .threadStartErrored
            } else {
                stage = .threadStartUnexpected
            }
            await process.stop()
        } catch {
            await process.stop()
            throw error
        }
        return .init(
            stage: stage,
            temporaryRootWasRemoved: !FileManager.default.fileExists(atPath: root.path),
            childWasStopped: !process.isRunning
        )
    }

    static func probe(
        scenario: LiveTextCompatibilityScenario,
        fixture: URL,
        temporaryParent: URL
    ) async throws -> LiveTextCompatibilityProbeResult {
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, "live-text-compatibility-\(scenario.rawValue)"],
            temporaryParentURL: temporaryParent,
            terminationGrace: .milliseconds(100)
        ))
        let root = process.temporaryRootURL
        var outcome: LiveTextCompatibilityAppendDisposition = .duplicate
        var observations: [LiveTextCompatibilityObservation] = []
        do {
            let stream = try process.start()
            var iterator = stream.makeAsyncIterator()
            let codec = CodexAppServerProtocol()
            try process.send(try codec.initializeRequest(id: "probe:initialize"))
            _ = try await nextMessage(&iterator, codec: codec) { message in
                if case .initializeResponse(id: "probe:initialize") = message { return true }
                return false
            }
            try process.send(try codec.initializedNotification())
            try process.send(Data(
                Data(#"{ "id":"probe:login","method":"account/login/start","params":{"accessToken":"synthetic-token","chatgptAccountId":"synthetic-account"} }"#.utf8)
                    + Data([0x0A])
            ))
            _ = try await nextMessage(&iterator, codec: codec) { message in
                if case .loginResponse(id: "probe:login") = message { return true }
                return false
            }
            try process.send(try codec.threadStartRequest(
                id: "probe:thread-start", cwd: temporaryParent.path
            ))
            let threadStart = try await nextMessage(&iterator, codec: codec) { message in
                if case .threadStartResponse(id: "probe:thread-start", threadID: _) = message {
                    return true
                }
                return false
            }
            let threadID = try dynamicThreadID(from: threadStart)
            try process.send(try LiveTextCompatibilityFrame.realtimeStartRequest(
                id: "probe:start",
                threadID: threadID,
                initialItems: [.init(role: "user", text: "synthetic-history")]
            ))
            _ = try await nextMessage(&iterator, codec: codec) { message in
                if case .emptyResponse(id: "probe:start") = message { return true }
                return false
            }
            observations.append(.startAcknowledged)
            _ = try await nextMessage(&iterator, codec: codec) { message in
                if case .started(threadID: threadID, version: .v3) = message { return true }
                return false
            }
            observations.append(.realtimeStarted)
            _ = try await nextMessage(&iterator, codec: codec) { message in
                if case .transcriptDelta(
                    threadID: threadID, role: "assistant", delta: "synthetic-active"
                ) = message { return true }
                return false
            }
            observations.append(.assistantOutputActive)

            let appendID = "probe:\(scenario.rawValue):append"
            var ledger = LiveTextCompatibilityLedger()
            guard ledger.register(appendID) == .registered else {
                throw LiveTextCompatibilityFrameError.invalid
            }
            let appendFrame: Data
            switch scenario {
            case .malformed:
                appendFrame = LiveTextCompatibilityFrame.malformedAppendTextRequest(
                    id: appendID, threadID: threadID
                )
            case .oversized:
                appendFrame = LiveTextCompatibilityFrame.oversizedAppendTextRequest(
                    id: appendID, threadID: threadID
                )
            default:
                appendFrame = try LiveTextCompatibilityFrame.appendTextRequest(
                    id: appendID,
                    threadID: threadID,
                    text: "synthetic-input",
                    role: "user"
                )
            }
            try process.send(appendFrame)
            observations.append(.appendPending)
            if scenario == .cancelled {
                ledger.cancel(appendID)
                observations.append(.appendCancelled)
                try process.send(LiveTextCompatibilityFrame.stopRequest(
                    id: "probe:cancelled:stop", threadID: threadID
                ))
                outcome = .cancelled
            } else if scenario == .late {
                try await Task.sleep(for: .milliseconds(20))
                ledger.expire(appendID)
                let acknowledgement = try await nextAcknowledgement(&iterator, codec: codec)
                outcome = ledger.observe(acknowledgement)
                observations.append(.appendLate)
                try process.send(LiveTextCompatibilityFrame.stopRequest(
                    id: "probe:late:stop", threadID: threadID
                ))
            } else {
                let acknowledgement = try await nextAcknowledgement(&iterator, codec: codec)
                outcome = ledger.observe(acknowledgement)
                switch outcome {
                case .accepted:
                    observations.append(.appendAcknowledged)
                case .rejected:
                    observations.append(.appendRejected)
                default:
                    break
                }
                if scenario == .duplicate {
                    let duplicate = try await nextAcknowledgement(&iterator, codec: codec)
                    guard ledger.observe(duplicate) == .duplicate else {
                        throw LiveTextCompatibilityFrameError.invalid
                    }
                    observations.append(.duplicateFrame)
                }
                if scenario == .accepted {
                    _ = try await nextMessage(&iterator, codec: codec) { message in
                        if case .transcriptDone(
                            threadID: threadID, role: "user", text: "synthetic-echo"
                        ) = message { return true }
                        return false
                    }
                    observations.append(.echo)
                }
                try process.send(LiveTextCompatibilityFrame.stopRequest(
                    id: "probe:\(scenario.rawValue):stop", threadID: threadID
                ))
            }
            _ = try await nextMessage(&iterator, codec: codec) { message in
                if case .emptyResponse = message { return true }
                return false
            }
            observations.append(.stopAcknowledged)
            _ = try await nextMessage(&iterator, codec: codec) { message in
                if case .closed(threadID: threadID, reason: "stopped") = message {
                    return true
                }
                return false
            }
            observations.append(.closed)
            await process.stop()
        } catch {
            await process.stop()
            throw error
        }
        return .init(
            scenario: scenario,
            outcome: outcome,
            observations: observations,
            temporaryRootWasRemoved: !FileManager.default.fileExists(atPath: root.path),
            childWasStopped: !process.isRunning
        )
    }

    private static func nextAcknowledgement(
        _ iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator,
        codec: CodexAppServerProtocol
    ) async throws -> LiveTextCompatibilityAcknowledgement {
        while let data = try await iterator.next() {
            if let acknowledgement = try? LiveTextCompatibilityFrame.decodeAcknowledgement(data) {
                return acknowledgement
            }
            _ = try codec.decode(data)
        }
        throw LiveProcessError.helperExited
    }

    private static func nextMessage(
        _ iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator,
        codec: CodexAppServerProtocol,
        where predicate: (CodexAppServerMessage) -> Bool
    ) async throws -> CodexAppServerMessage {
        while let data = try await iterator.next() {
            let message = try codec.decode(data)
            if predicate(message) { return message }
        }
        throw LiveProcessError.helperExited
    }

    private static func nextControlMessage(
        _ iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator,
        codec: CodexAppServerProtocol
    ) async throws -> CodexAppServerMessage {
        while let data = try await iterator.next() {
            let message = try codec.decode(data)
            switch message {
            case .requestError, .initializeResponse, .threadStartResponse,
                 .emptyResponse, .started, .error, .closed:
                return message
            default:
                continue
            }
        }
        throw LiveProcessError.helperExited
    }
}
