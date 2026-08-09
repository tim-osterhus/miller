import CoreFoundation
import Foundation

public enum CodexTypedProtocolError: Error, Equatable, Sendable {
    case malformedJSON
    case invalidField
    case identifierTooLarge
    case textTooLarge
    case tooManyItems
    case invalidSequence
    case featureUnavailable
    case providerFailed
    case initializeRejected
    case authenticationRequired
}

public enum MillerAppServerClientInfo: Sendable {
    public static let name = "miller"
    public static let title = "Miller"
    public static let version = "0.1.1"
}

public struct CodexTypedContextMessage: Equatable, Sendable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct CodexTypedSkillInput: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum CodexTypedTurnOutcome: String, Equatable, Sendable {
    case completed
    case interrupted
    case failed
}

public enum CodexTypedCapabilityKind: String, Equatable, Sendable {
    case webSearch
    case mcpToolCall
    case appToolCall
}

public enum CodexTypedCapabilityPhase: String, Equatable, Sendable {
    case started
    case completed
    case failed
}

public struct CodexTypedThreadAuthority: Equatable, Sendable {
    public let permissionProfileID: String
    public let cwd: String
    public let runtimeWorkspaceRoots: [String]
    public let sandboxType: String
    public let networkAccess: Bool
    public let ephemeral: Bool

    public init(
        permissionProfileID: String,
        cwd: String,
        runtimeWorkspaceRoots: [String],
        sandboxType: String,
        networkAccess: Bool,
        ephemeral: Bool
    ) {
        self.permissionProfileID = permissionProfileID
        self.cwd = cwd
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
        self.sandboxType = sandboxType
        self.networkAccess = networkAccess
        self.ephemeral = ephemeral
    }
}

public enum CodexTypedMessage: Equatable, Sendable {
    case initializeResponse(id: String)
    case loginResponse(id: String)
    case threadStartResponse(
        id: String, threadID: String, authority: CodexTypedThreadAuthority
    )
    case threadStarted(threadID: String)
    case turnStartResponse(id: String, turnID: String)
    case turnStarted(threadID: String, turnID: String)
    case assistantTextDelta(
        threadID: String, turnID: String, itemID: String, text: String
    )
    case assistantMessageCompleted(
        threadID: String, turnID: String, itemID: String, text: String
    )
    case capabilityActivity(
        threadID: String,
        turnID: String,
        itemID: String,
        kind: CodexTypedCapabilityKind,
        phase: CodexTypedCapabilityPhase
    )
    case turnCompleted(
        threadID: String, turnID: String, outcome: CodexTypedTurnOutcome
    )
    case emptyResponse(id: String)
    case featureResponse(id: String)
    case credentialRefresh(id: JSONRPCRequestID, previousAccountID: String?)
    case unsupportedApproval(id: JSONRPCRequestID)
    case unsupportedPermissionsApproval(id: JSONRPCRequestID)
    case requestError(id: String, code: Int)
    case ignored
}

public struct CodexTypedProtocol: Sendable {
    public static let permissionProfileID = "miller-typed-read-only"
    public static let permissionProfileArguments = [
        "-c", "default_permissions=\"\(permissionProfileID)\"",
        "-c", "permissions.\(permissionProfileID).description=\"Miller isolated typed turn\"",
        "-c", "permissions.\(permissionProfileID).filesystem={ \":minimal\" = \"read\", \":workspace_roots\" = { \".\" = \"read\" } }",
        "-c", "permissions.\(permissionProfileID).network.enabled=false",
    ]

    public let maximumFrameBytes: Int
    public let maximumIdentifierBytes: Int
    public let maximumTextBytes: Int
    public let maximumItems: Int

    public init(
        maximumFrameBytes: Int = 1_048_576,
        maximumIdentifierBytes: Int = 256,
        maximumTextBytes: Int = 65_536,
        maximumItems: Int = 1_024
    ) {
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumIdentifierBytes = maximumIdentifierBytes
        self.maximumTextBytes = maximumTextBytes
        self.maximumItems = maximumItems
    }

    public func initializeRequest(id: String) throws -> Data {
        try validateIdentifier(id)
        return try encode([
            "method": "initialize",
            "id": id,
            "params": [
                // External ChatGPT token authentication is experimental in App Server 0.146.
                "capabilities": ["experimentalApi": true],
                "clientInfo": [
                    "name": MillerAppServerClientInfo.name,
                    "title": MillerAppServerClientInfo.title,
                    "version": MillerAppServerClientInfo.version,
                ],
            ],
        ])
    }

    public func initializedNotification() throws -> Data {
        try encode(["method": "initialized", "params": [:] as [String: Any]])
    }

    public func threadStartRequest(
        id: String,
        model: String,
        cwd: String
    ) throws -> Data {
        try validateIdentifier(id)
        try validateText(model)
        try validateAbsolutePath(cwd)
        return try encode([
            "method": "thread/start",
            "id": id,
            "params": [
                "model": model,
                "cwd": cwd,
                "ephemeral": true,
                "approvalPolicy": "never",
            ] as [String: Any],
        ])
    }

    public func threadResumeRequest(id: String, threadID: String) throws -> Data {
        try validateIdentifier(id)
        try validateIdentifier(threadID)
        return try encode([
            "method": "thread/resume", "id": id,
            "params": ["threadId": threadID],
        ])
    }

    public func turnStartRequest(
        id: String,
        threadID: String,
        cwd: String,
        context: [CodexTypedContextMessage],
        userText: String,
        skills: [CodexTypedSkillInput] = []
    ) throws -> Data {
        try validateIdentifier(id)
        try validateIdentifier(threadID)
        try validateAbsolutePath(cwd)
        guard context.count <= 40 else { throw CodexTypedProtocolError.tooManyItems }
        var scalarCount = userText.unicodeScalars.count
        guard scalarCount <= 65_536 else { throw CodexTypedProtocolError.textTooLarge }
        for message in context {
            guard message.role == "user" || message.role == "assistant" else {
                throw CodexTypedProtocolError.invalidField
            }
            scalarCount += message.text.unicodeScalars.count
            guard scalarCount <= 97_536 else { throw CodexTypedProtocolError.textTooLarge }
        }
        let prompt = Self.prompt(context: context, userText: userText)
        guard prompt.utf8.count <= 256 * 1_024 else {
            throw CodexTypedProtocolError.textTooLarge
        }
        guard skills.count <= 128 else { throw CodexTypedProtocolError.tooManyItems }
        let skillInputs: [[String: Any]] = try skills.map { skill in
            try validateText(skill.name)
            try validateAbsolutePath(skill.path)
            return ["type": "skill", "name": skill.name, "path": skill.path]
        }
        return try encode([
            "method": "turn/start",
            "id": id,
            "params": [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]] + skillInputs,
                "cwd": cwd,
                "approvalPolicy": "never",
            ],
        ])
    }

    public func skillsExtraRootsSetRequest(id: String, roots: [String]) throws -> Data {
        try validateIdentifier(id)
        guard roots.count <= 8 else { throw CodexTypedProtocolError.tooManyItems }
        try roots.forEach(validateAbsolutePath)
        return try encode([
            "method": "skills/extraRoots/set", "id": id,
            "params": ["extraRoots": roots],
        ])
    }

    public func skillsListRequest(id: String, cwd: String) throws -> Data {
        try validateIdentifier(id)
        try validateAbsolutePath(cwd)
        return try encode([
            "method": "skills/list", "id": id,
            "params": ["cwds": [cwd], "forceReload": true],
        ])
    }

    public func turnInterruptRequest(
        id: String,
        threadID: String,
        turnID: String
    ) throws -> Data {
        try validateIdentifier(id)
        try validateIdentifier(threadID)
        try validateIdentifier(turnID)
        return try encode([
            "method": "turn/interrupt", "id": id,
            "params": ["threadId": threadID, "turnId": turnID],
        ])
    }

    public func declineUnsupportedApproval(
        id: JSONRPCRequestID
    ) throws -> Data {
        let encodedID: Any
        switch id {
        case .string(let value):
            try validateIdentifier(value)
            encodedID = value
        case .integer(let value):
            encodedID = value
        }
        return try encode([
            "id": encodedID,
            "result": ["decision": "decline"],
        ])
    }

    public func declineUnsupportedPermissionsApproval(
        id: JSONRPCRequestID
    ) throws -> Data {
        let encodedID: Any
        switch id {
        case .string(let value):
            try validateIdentifier(value)
            encodedID = value
        case .integer(let value):
            encodedID = value
        }
        return try encode([
            "id": encodedID,
            "result": [
                "permissions": [:] as [String: Any],
                "scope": "turn",
                "strictAutoReview": true,
            ] as [String: Any],
        ])
    }

    public func featureProbeRequests(
        requestPrefix: String,
        cwd: String
    ) throws -> [Data] {
        try validateIdentifier(requestPrefix)
        try validateAbsolutePath(cwd)
        return try [
            encode([
                "method": "app/list", "id": "\(requestPrefix):apps",
                "params": ["cursor": NSNull(), "limit": 1],
            ]),
            encode([
                "method": "mcpServerStatus/list", "id": "\(requestPrefix):mcp",
                "params": [
                    "cursor": NSNull(), "limit": 1,
                    "detail": "toolsAndAuthOnly",
                ],
            ]),
            encode([
                "method": "skills/list", "id": "\(requestPrefix):skills",
                "params": ["cwds": [cwd], "forceReload": false],
            ]),
        ]
    }

    public func decode(_ data: Data) throws -> CodexTypedMessage {
        guard data.count <= maximumFrameBytes else {
            throw CodexTypedProtocolError.textTooLarge
        }
        let root: [String: Any]
        do {
            root = try requireObject(JSONSerialization.jsonObject(with: data))
        } catch let error as CodexTypedProtocolError {
            throw error
        } catch {
            throw CodexTypedProtocolError.malformedJSON
        }
        if let method = root["method"] as? String {
            return try decodeNotification(method: method, root: root)
        }
        let id = try identifier(root, key: "id")
        if let error = root["error"] as? [String: Any] {
            let code = try integer(error, key: "code")
            return .requestError(id: id, code: code)
        }
        let result = try requireObject(root["result"])
        if id.hasSuffix(":initialize") { return .initializeResponse(id: id) }
        if id.hasSuffix(":login") { return .loginResponse(id: id) }
        if id.hasSuffix(":thread") || id.hasSuffix(":thread-start") {
            let thread = try requireObject(result["thread"])
            return .threadStartResponse(
                id: id,
                threadID: try identifier(thread, key: "id"),
                authority: try threadAuthority(result: result, thread: thread)
            )
        }
        if id.hasSuffix(":turn-start") {
            return .turnStartResponse(
                id: id,
                turnID: try identifier(try requireObject(result["turn"]), key: "id")
            )
        }
        if id.hasSuffix(":apps") || id.hasSuffix(":mcp")
            || id.hasSuffix(":skills") || id.hasSuffix(":skills-roots")
            || id.hasSuffix(":skills-list")
        {
            return .featureResponse(id: id)
        }
        guard result.isEmpty else { return .featureResponse(id: id) }
        return .emptyResponse(id: id)
    }

    public func decodeCapability(
        _ data: Data
    ) throws -> CodexCapabilityDecodedEvent {
        try CodexCapabilityProtocol(
            maximumFrameBytes: maximumFrameBytes,
            maximumRawItemBytes: min(maximumFrameBytes, 262_144),
            maximumIdentifierBytes: maximumIdentifierBytes,
            maximumTextBytes: maximumTextBytes,
            maximumItems: maximumItems
        ).decodeActivity(data)
    }

    private func decodeNotification(
        method: String,
        root: [String: Any]
    ) throws -> CodexTypedMessage {
        let supportedMethods = [
            "thread/started", "turn/started", "item/agentMessage/delta",
            "item/started", "item/completed", "turn/completed",
            "account/chatgptAuthTokens/refresh",
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
        ]
        guard supportedMethods.contains(method) else { return .ignored }
        guard let params = root["params"] as? [String: Any] else {
            throw CodexTypedProtocolError.invalidField
        }
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            return .unsupportedApproval(id: try requestID(root))
        case "item/permissions/requestApproval":
            return .unsupportedPermissionsApproval(id: try requestID(root))
        case "account/chatgptAuthTokens/refresh":
            guard params["reason"] as? String == "unauthorized" else {
                throw CodexTypedProtocolError.invalidField
            }
            let previousAccountID = params["previousAccountId"] as? String
            if let previousAccountID { try validateIdentifier(previousAccountID) }
            return .credentialRefresh(
                id: try requestID(root),
                previousAccountID: previousAccountID
            )
        case "thread/started":
            return .threadStarted(
                threadID: try identifier(try requireObject(params["thread"]), key: "id")
            )
        case "turn/started":
            let turn = try requireObject(params["turn"])
            return .turnStarted(
                threadID: try identifier(params, key: "threadId"),
                turnID: try identifier(turn, key: "id")
            )
        case "item/agentMessage/delta":
            return .assistantTextDelta(
                threadID: try identifier(params, key: "threadId"),
                turnID: try identifier(params, key: "turnId"),
                itemID: try identifier(params, key: "itemId"),
                text: try text(params, key: "delta")
            )
        case "item/started", "item/completed":
            let item = try requireObject(params["item"])
            let type = try text(item, key: "type")
            if type == "agentMessage", method == "item/completed" {
                return .assistantMessageCompleted(
                    threadID: try identifier(params, key: "threadId"),
                    turnID: try identifier(params, key: "turnId"),
                    itemID: try identifier(item, key: "id"),
                    text: try text(item, key: "text")
                )
            }
            let kind: CodexTypedCapabilityKind?
            if type == "mcpToolCall",
               item["appContext"] is [String: Any] || item["pluginId"] is String
            {
                kind = .appToolCall
            } else {
                kind = CodexTypedCapabilityKind(rawValue: type)
            }
            if let kind {
                let phase: CodexTypedCapabilityPhase
                if method == "item/started" {
                    phase = .started
                } else if type == "mcpToolCall", item["status"] as? String == "failed" {
                    phase = .failed
                } else {
                    phase = .completed
                }
                return .capabilityActivity(
                    threadID: try identifier(params, key: "threadId"),
                    turnID: try identifier(params, key: "turnId"),
                    itemID: try identifier(item, key: "id"),
                    kind: kind,
                    phase: phase
                )
            }
            return .ignored
        case "turn/completed":
            let turn = try requireObject(params["turn"])
            let items = try requireArray(turn["items"])
            guard items.count <= maximumItems else {
                throw CodexTypedProtocolError.tooManyItems
            }
            guard let outcome = CodexTypedTurnOutcome(
                rawValue: try text(turn, key: "status")
            ) else { throw CodexTypedProtocolError.invalidField }
            return .turnCompleted(
                threadID: try identifier(params, key: "threadId"),
                turnID: try identifier(turn, key: "id"),
                outcome: outcome
            )
        default:
            return .ignored
        }
    }

    private func encode(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw CodexTypedProtocolError.invalidField
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= maximumFrameBytes else {
            throw CodexTypedProtocolError.textTooLarge
        }
        return data + Data([0x0A])
    }

    private func identifier(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw CodexTypedProtocolError.invalidField
        }
        try validateIdentifier(value)
        return value
    }

    private func text(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw CodexTypedProtocolError.invalidField
        }
        try validateText(value)
        return value
    }

    private func threadAuthority(
        result: [String: Any],
        thread: [String: Any]
    ) throws -> CodexTypedThreadAuthority {
        guard result["approvalPolicy"] as? String == "never" else {
            throw CodexTypedProtocolError.invalidField
        }
        let profile = try requireObject(result["activePermissionProfile"])
        let profileID = try identifier(profile, key: "id")
        guard profileID == Self.permissionProfileID else {
            throw CodexTypedProtocolError.invalidField
        }
        let cwd = try text(result, key: "cwd")
        try validateAbsolutePath(cwd)
        guard try text(thread, key: "cwd") == cwd,
              thread["ephemeral"] as? Bool == true
        else { throw CodexTypedProtocolError.invalidField }

        let roots = try requireArray(result["runtimeWorkspaceRoots"]).map { value in
            guard let path = value as? String else {
                throw CodexTypedProtocolError.invalidField
            }
            try validateAbsolutePath(path)
            return path
        }
        guard roots == [cwd] else { throw CodexTypedProtocolError.invalidField }

        let sandbox = try requireObject(result["sandbox"])
        guard sandbox["type"] as? String == "readOnly",
              sandbox["networkAccess"] as? Bool == false
        else { throw CodexTypedProtocolError.invalidField }
        return .init(
            permissionProfileID: profileID,
            cwd: cwd,
            runtimeWorkspaceRoots: roots,
            sandboxType: "readOnly",
            networkAccess: false,
            ephemeral: true
        )
    }

    private func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty else { throw CodexTypedProtocolError.invalidField }
        guard value.utf8.count <= maximumIdentifierBytes else {
            throw CodexTypedProtocolError.identifierTooLarge
        }
        guard !value.utf8.contains(0) else { throw CodexTypedProtocolError.invalidField }
    }

    private func validateText(_ value: String) throws {
        guard value.utf8.count <= maximumTextBytes else {
            throw CodexTypedProtocolError.textTooLarge
        }
        guard !value.utf8.contains(0) else { throw CodexTypedProtocolError.invalidField }
    }

    private func validateAbsolutePath(_ value: String) throws {
        guard value.hasPrefix("/"), !value.contains("\0") else {
            throw CodexTypedProtocolError.invalidField
        }
        try validateText(value)
    }

    private func requireObject(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw CodexTypedProtocolError.invalidField
        }
        return value
    }

    private func requireArray(_ value: Any?) throws -> [Any] {
        guard let value = value as? [Any] else {
            throw CodexTypedProtocolError.invalidField
        }
        return value
    }

    private func integer(_ object: [String: Any], key: String) throws -> Int {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { throw CodexTypedProtocolError.invalidField }
        return number.intValue
    }

    private func requestID(_ object: [String: Any]) throws -> JSONRPCRequestID {
        if let value = object["id"] as? String {
            try validateIdentifier(value)
            return .string(value)
        }
        guard let number = object["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { throw CodexTypedProtocolError.invalidField }
        return .integer(number.int64Value)
    }

    private static func prompt(
        context: [CodexTypedContextMessage],
        userText: String
    ) -> String {
        guard !context.isEmpty else { return userText }
        let prior = context.map { message in
            "\(message.role == "user" ? "User" : "Miller"): \(message.text)"
        }.joined(separator: "\n\n")
        return """
        Continue this Miller conversation using only the bounded durable context below.

        \(prior)

        User: \(userText)
        """
    }
}

public struct CodexTypedTerminalSequence: Sendable {
    private var threadID: String?
    private var turnID: String?
    private var terminal = false

    public init() {}

    @discardableResult
    public mutating func accept(_ message: CodexTypedMessage) throws -> Bool {
        guard !terminal else { throw CodexTypedProtocolError.invalidSequence }
        switch message {
        case let .turnStarted(threadID, turnID):
            guard self.turnID == nil else { throw CodexTypedProtocolError.invalidSequence }
            self.threadID = threadID
            self.turnID = turnID
        case let .assistantTextDelta(threadID, turnID, _, _),
             let .assistantMessageCompleted(threadID, turnID, _, _),
             let .capabilityActivity(threadID, turnID, _, _, _):
            try requireActive(threadID: threadID, turnID: turnID)
        case let .turnCompleted(threadID, turnID, _):
            try requireActive(threadID: threadID, turnID: turnID)
            terminal = true
            return true
        case .ignored:
            break
        default:
            throw CodexTypedProtocolError.invalidSequence
        }
        return false
    }

    private func requireActive(threadID: String, turnID: String) throws {
        guard self.threadID == threadID, self.turnID == turnID else {
            throw CodexTypedProtocolError.invalidSequence
        }
    }
}
