import CoreFoundation
import Foundation
import MillerCore

public enum CodexCapabilityProtocolError: Error, Equatable, Sendable {
    case malformedJSON
    case invalidField
    case wrongResponse
    case payloadTooLarge
    case tooManyItems
    case invalidLimit
    case catalogTooLarge
}

public struct CodexAccountApp: Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let isAccessible: Bool
    public let isEnabled: Bool
}

public struct CodexAccountAppTool: Equatable, Sendable {
    public let appID: String
    public let name: String
    public let title: String?
    public let summary: String
    public let isEnabled: Bool
    public let isReadOnly: Bool
}

public struct CodexInstalledApp: Equatable, Sendable {
    public let id: String
    public let isEnabled: Bool
    public let isCallable: Bool
}

public struct CodexMCPTool: Equatable, Sendable {
    public let name: String
    public let title: String?
    public let summary: String
    public let inputSchemaJSON: Data
}

public struct CodexMCPServer: Equatable, Sendable {
    public let name: String
    public let authStatus: String
    public let tools: [CodexMCPTool]
}

public struct CodexCapabilityPage<Item: Equatable & Sendable>: Equatable, Sendable {
    public let items: [Item]
    public let nextCursor: String?
}

public enum CodexCapabilityActivityPhase: String, Equatable, Sendable {
    case started
    case running
    case terminal
}

public enum CodexCapabilityActivityVisibility: String, Equatable, Sendable {
    case opaqueProviderActivity = "opaque_provider_activity"
}

public struct CodexCapabilityActivity: Equatable, Sendable {
    public let threadID: String
    public let turnID: String?
    public let itemID: String
    public let capabilityID: CapabilityID
    public let phase: CodexCapabilityActivityPhase
    public let outcome: CapabilityTerminalOutcome?
    public let summary: CapabilitySummary
    public let visibility: CodexCapabilityActivityVisibility
}

public enum CodexProviderApprovalKind: Equatable, Sendable {
    case commandExecution
    case fileChange
    case toolUserInput
}

public struct CodexProviderApproval: Equatable, Sendable {
    public let responseID: JSONRPCRequestID
    public let itemID: String
    public let threadID: String
    public let turnID: String
    public let kind: CodexProviderApprovalKind
    public let request: CapabilityApprovalRequest
    public let availableDecisions: Set<String>
    public let toolUserInputQuestionID: String?
}

public enum CodexCapabilityDecodedEvent: Equatable, Sendable {
    case activity(CodexCapabilityActivity)
    case approval(CodexProviderApproval)
    case ignored
    case notCapability
}

public typealias CodexCapabilityActivityHandler = @Sendable (
    CodexCapabilityActivity
) async -> Void
public typealias CodexProviderApprovalResolver = @Sendable (
    CapabilityApprovalRequest
) async -> CapabilityApprovalDecision

public struct CodexCapabilityProtocol: Sendable {
    public static let reservedBridgeServerID = "miller-capability-bridge"

    public let maximumFrameBytes: Int
    public let maximumRawItemBytes: Int
    public let maximumIdentifierBytes: Int
    public let maximumTextBytes: Int
    public let maximumItems: Int

    public init(
        maximumFrameBytes: Int = 1_048_576,
        maximumRawItemBytes: Int = 262_144,
        maximumIdentifierBytes: Int = 256,
        maximumTextBytes: Int = 65_536,
        maximumItems: Int = 2_048
    ) {
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumRawItemBytes = maximumRawItemBytes
        self.maximumIdentifierBytes = maximumIdentifierBytes
        self.maximumTextBytes = maximumTextBytes
        self.maximumItems = maximumItems
    }

    public func appsListRequest(
        id: String, cursor: String?, limit: Int
    ) throws -> Data {
        try validateIdentifier(id)
        try validateCursor(cursor)
        try validateLimit(limit)
        return try encode([
            "id": id,
            "method": "app/list",
            "params": [
                "cursor": cursor ?? NSNull(),
                "forceRefetch": false,
                "limit": limit,
                "threadId": NSNull(),
            ] as [String: Any],
        ])
    }

    public func appsReadRequest(id: String, appIDs: [String]) throws -> Data {
        try validateIdentifier(id)
        guard !appIDs.isEmpty, appIDs.count <= 100 else {
            throw CodexCapabilityProtocolError.tooManyItems
        }
        for appID in appIDs { try validateIdentifier(appID) }
        return try encode([
            "id": id,
            "method": "app/read",
            "params": ["appIds": appIDs, "includeTools": true] as [String: Any],
        ])
    }

    public func appsInstalledRequest(id: String) throws -> Data {
        try validateIdentifier(id)
        return try encode([
            "id": id,
            "method": "app/installed",
            "params": ["forceRefresh": false, "threadId": NSNull()] as [String: Any],
        ])
    }

    public func mcpServerStatusListRequest(
        id: String, cursor: String?, limit: Int
    ) throws -> Data {
        try validateIdentifier(id)
        try validateCursor(cursor)
        try validateLimit(limit)
        return try encode([
            "id": id,
            "method": "mcpServerStatus/list",
            "params": [
                "cursor": cursor ?? NSNull(),
                "detail": "toolsAndAuthOnly",
                "limit": limit,
                "threadId": NSNull(),
            ] as [String: Any],
        ])
    }

    public func decodeAppsListResponse(
        _ data: Data, expectedID: String
    ) throws -> CodexCapabilityPage<CodexAccountApp> {
        let result = try responseResult(data, expectedID: expectedID)
        let objects = try objectArray(result["data"])
        guard objects.count <= maximumItems else {
            throw CodexCapabilityProtocolError.tooManyItems
        }
        let items = try objects.map { object in
            CodexAccountApp(
                id: try identifier(object, "id"),
                name: try text(object, "name"),
                summary: try optionalText(object, "description") ?? "Codex account app",
                isAccessible: try boolean(object, "isAccessible", default: false),
                isEnabled: try boolean(object, "isEnabled", default: true)
            )
        }
        return .init(items: items, nextCursor: try nextCursor(result))
    }

    public func decodeAppsReadResponse(
        _ data: Data, expectedID: String
    ) throws -> [CodexAccountAppTool] {
        let result = try responseResult(data, expectedID: expectedID)
        let apps = try objectArray(result["apps"])
        let missing = try stringArray(result["missingAppIds"])
        guard apps.count <= 100, missing.count <= 100 else {
            throw CodexCapabilityProtocolError.tooManyItems
        }
        var tools: [CodexAccountAppTool] = []
        for app in apps {
            let appID = try identifier(app, "id")
            _ = try text(app, "name")
            let summaries = try optionalObjectArray(app["toolSummaries"])
            guard tools.count + summaries.count <= maximumItems else {
                throw CodexCapabilityProtocolError.tooManyItems
            }
            for tool in summaries {
                tools.append(.init(
                    appID: appID,
                    name: try identifier(tool, "name"),
                    title: try optionalText(tool, "title"),
                    summary: try text(tool, "description"),
                    isEnabled: try boolean(tool, "isEnabled", default: true),
                    isReadOnly: try boolean(tool, "isReadOnly", default: false)
                ))
            }
        }
        return tools
    }

    public func decodeAppsInstalledResponse(
        _ data: Data, expectedID: String
    ) throws -> [CodexInstalledApp] {
        let result = try responseResult(data, expectedID: expectedID)
        let apps = try objectArray(result["apps"])
        guard apps.count <= maximumItems else {
            throw CodexCapabilityProtocolError.tooManyItems
        }
        return try apps.map { app in
            CodexInstalledApp(
                id: try identifier(app, "id"),
                isEnabled: try boolean(app, "enabled"),
                isCallable: try boolean(app, "callable")
            )
        }
    }

    public func decodeMCPServerStatusResponse(
        _ data: Data, expectedID: String
    ) throws -> CodexCapabilityPage<CodexMCPServer> {
        let result = try responseResult(data, expectedID: expectedID)
        let servers = try objectArray(result["data"])
        guard servers.count <= maximumItems else {
            throw CodexCapabilityProtocolError.tooManyItems
        }
        var toolCount = 0
        let items = try servers.map { server -> CodexMCPServer in
            let toolObject = try object(server["tools"])
            toolCount += toolObject.count
            guard toolCount <= maximumItems else {
                throw CodexCapabilityProtocolError.tooManyItems
            }
            let tools = try toolObject.keys.sorted().map { key -> CodexMCPTool in
                let value = try object(toolObject[key])
                let name = try identifier(value, "name")
                guard name == key else { throw CodexCapabilityProtocolError.invalidField }
                let schema = try boundedJSONObject(value["inputSchema"])
                return .init(
                    name: name,
                    title: try optionalText(value, "title"),
                    summary: try optionalText(value, "description") ?? "Codex MCP tool",
                    inputSchemaJSON: schema
                )
            }
            _ = try objectArray(server["resources"])
            _ = try objectArray(server["resourceTemplates"])
            return .init(
                name: try identifier(server, "name"),
                authStatus: try enumText(
                    server, "authStatus",
                    values: ["unsupported", "notLoggedIn", "bearerToken", "oAuth"]
                ),
                tools: tools
            )
        }
        return .init(items: items, nextCursor: try nextCursor(result))
    }

    public func projectCatalog(
        apps: [CodexAccountApp],
        appDetails: [CodexAccountAppTool],
        installedApps: [CodexInstalledApp],
        mcpServers: [CodexMCPServer],
        codexProviderProfileID: UUID,
        existingMillerCapabilities: [CapabilityDescriptor]
    ) throws -> CapabilityCatalogSnapshot {
        guard apps.count <= maximumItems, appDetails.count <= maximumItems,
              installedApps.count <= maximumItems, mcpServers.count <= maximumItems
        else { throw CodexCapabilityProtocolError.catalogTooLarge }
        let appByID = try uniqueMap(apps, key: \.id)
        let installedByID = try uniqueMap(installedApps, key: \.id)
        var descriptors: [CapabilityDescriptor] = []
        var seen = Set<CapabilityID>()
        let detailAppIDs = Set(appDetails.map(\.appID))

        for app in apps where !detailAppIDs.contains(app.id) {
            let runtime = installedByID[app.id]
            let descriptor = try descriptor(
                source: .codexAccount,
                server: app.id,
                tool: "app",
                displayName: app.name,
                summary: app.summary,
                schema: Data("{}".utf8),
                readOnly: nil,
                profileID: codexProviderProfileID,
                accessible: app.isAccessible,
                enabled: app.isEnabled && (runtime?.isEnabled ?? false),
                callable: false,
                visibility: .providerManaged
            )
            guard seen.insert(descriptor.id).inserted else {
                throw CodexCapabilityProtocolError.invalidField
            }
            descriptors.append(descriptor)
        }
        for tool in appDetails {
            guard let app = appByID[tool.appID] else { continue }
            let runtime = installedByID[tool.appID]
            let descriptor = try descriptor(
                source: .codexAccount,
                server: tool.appID,
                tool: tool.name,
                displayName: tool.title ?? tool.name,
                summary: tool.summary,
                schema: Data("{}".utf8),
                readOnly: tool.isReadOnly,
                profileID: codexProviderProfileID,
                accessible: app.isAccessible,
                enabled: app.isEnabled && tool.isEnabled && (runtime?.isEnabled ?? false),
                callable: app.isAccessible && tool.isEnabled
                    && (runtime?.isCallable ?? false),
                visibility: .providerManaged
            )
            guard seen.insert(descriptor.id).inserted else {
                throw CodexCapabilityProtocolError.invalidField
            }
            descriptors.append(descriptor)
        }

        let existingByProjectedName = Dictionary(
            grouping: existingMillerCapabilities.filter { $0.source == .millerMCP },
            by: \.bridgeProjectedToolName
        )
        for server in mcpServers {
            if normalizedComponent(server.name) == Self.reservedBridgeServerID {
                for tool in server.tools {
                    guard let matches = existingByProjectedName[tool.name],
                          matches.count == 1,
                          let descriptor = matches.first
                    else { continue }
                    if seen.insert(descriptor.id).inserted { descriptors.append(descriptor) }
                }
                continue
            }
            let callable = server.authStatus != "notLoggedIn"
            for tool in server.tools {
                let descriptor = try descriptor(
                    source: .codexAccount,
                    server: server.name,
                    tool: tool.name,
                    displayName: tool.title ?? tool.name,
                    summary: tool.summary,
                    schema: tool.inputSchemaJSON,
                    readOnly: nil,
                    profileID: codexProviderProfileID,
                    accessible: callable,
                    enabled: true,
                    callable: callable,
                    visibility: .providerManaged
                )
                guard seen.insert(descriptor.id).inserted else {
                    throw CodexCapabilityProtocolError.invalidField
                }
                descriptors.append(descriptor)
            }
        }
        guard descriptors.count <= maximumItems else {
            throw CodexCapabilityProtocolError.catalogTooLarge
        }
        return try CapabilityCatalogSnapshot(descriptors.sorted {
            $0.id.rawValue < $1.id.rawValue
        })
    }

    public func decodeActivity(
        _ data: Data,
        existingMillerCapabilities: [CapabilityDescriptor] = []
    ) throws -> CodexCapabilityDecodedEvent {
        guard data.count <= maximumFrameBytes else {
            throw CodexCapabilityProtocolError.payloadTooLarge
        }
        let root = try decodedObject(data)
        guard let method = root["method"] as? String else { return .notCapability }
        if method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval"
        {
            guard data.count <= maximumRawItemBytes else {
                throw CodexCapabilityProtocolError.payloadTooLarge
            }
            return .approval(try providerApproval(method: method, root: root))
        }
        if method == "item/tool/requestUserInput" {
            guard data.count <= maximumRawItemBytes else {
                throw CodexCapabilityProtocolError.payloadTooLarge
            }
            guard let approval = try toolUserInputApproval(root) else {
                return .ignored
            }
            return .approval(approval)
        }
        guard method == "item/started" || method == "item/completed"
                || method == "thread/realtime/itemAdded"
        else { return .notCapability }
        guard data.count <= maximumRawItemBytes else { return .ignored }
        guard let params = root["params"] as? [String: Any],
              let item = params["item"] as? [String: Any]
        else {
            return method == "thread/realtime/itemAdded" ? .notCapability : .ignored
        }
        guard item["type"] != nil else {
            return method == "thread/realtime/itemAdded" ? .notCapability : .ignored
        }
        let type = try text(item, "type")
        guard type == "mcpToolCall" || type == "webSearch" else {
            return method == "thread/realtime/itemAdded" ? .notCapability : .ignored
        }
        switch method {
        case "item/started":
            _ = try integer64(params, "startedAtMs")
        case "item/completed":
            _ = try integer64(params, "completedAtMs")
        default:
            break
        }
        let threadID = try identifier(params, "threadId")
        let turnID = method == "thread/realtime/itemAdded"
            ? try optionalIdentifier(params, "turnId")
            : try identifier(params, "turnId")
        let itemID = try identifier(item, "id")
        let capabilityID: CapabilityID
        let summary: String
        if type == "webSearch" {
            _ = try text(item, "query")
            capabilityID = try CapabilityID(
                source: .providerNative, serverID: "codex", toolName: "websearch"
            )
            summary = "Opaque Codex web search activity"
        } else {
            guard item["server"] is String, item["tool"] is String else {
                return .notCapability
            }
            let server = try identifier(item, "server")
            let tool = try identifier(item, "tool")
            guard item["arguments"] != nil else {
                throw CodexCapabilityProtocolError.invalidField
            }
            let status = try enumText(
                item, "status", values: ["inProgress", "completed", "failed"]
            )
            switch method {
            case "item/started":
                guard status == "inProgress" else {
                    throw CodexCapabilityProtocolError.invalidField
                }
            case "item/completed":
                guard status == "completed" || status == "failed" else {
                    throw CodexCapabilityProtocolError.invalidField
                }
            default:
                break
            }
            if normalizedComponent(server) == Self.reservedBridgeServerID {
                let matches = existingMillerCapabilities.filter {
                    $0.source == .millerMCP && $0.bridgeProjectedToolName == tool
                }
                guard matches.count == 1, let match = matches.first else {
                    return .ignored
                }
                capabilityID = match.id
            } else if let appContext = item["appContext"] as? [String: Any] {
                capabilityID = try CapabilityID(
                    source: .codexAccount,
                    serverID: try identifier(appContext, "connectorId"),
                    toolName: try optionalIdentifier(appContext, "actionName") ?? tool
                )
            } else {
                capabilityID = try CapabilityID(
                    source: .codexAccount, serverID: server, toolName: tool
                )
            }
            summary = "Opaque Codex capability activity"
        }
        let status = item["status"] as? String
        let terminal = method == "item/completed"
            || status == "completed" || status == "failed"
        let outcome: CapabilityTerminalOutcome? = terminal
            ? (status == "failed" ? .failed : .succeeded) : nil
        let phase: CodexCapabilityActivityPhase = terminal
            ? .terminal : (method == "item/started" ? .started : .running)
        return .activity(.init(
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            capabilityID: capabilityID,
            phase: phase,
            outcome: outcome,
            summary: try CapabilitySummary(text: summary),
            visibility: .opaqueProviderActivity
        ))
    }

    public func approvalResponse(
        _ approval: CodexProviderApproval,
        decision: CapabilityApprovalDecision
    ) throws -> Data {
        let preferred = decision == .allowOnce ? "accept" : "decline"
        let selected: String
        if approval.availableDecisions.contains(preferred) {
            selected = preferred
        } else if approval.availableDecisions.contains("decline") {
            selected = "decline"
        } else if approval.availableDecisions.contains("cancel") {
            selected = "cancel"
        } else {
            throw CodexCapabilityProtocolError.invalidField
        }
        return try approvalDecisionResponse(approval, decision: selected)
    }

    public func cancelApprovalResponse(_ approval: CodexProviderApproval) throws -> Data {
        if approval.availableDecisions.contains("cancel") {
            return try approvalDecisionResponse(approval, decision: "cancel")
        }
        guard approval.availableDecisions.contains("decline") else {
            throw CodexCapabilityProtocolError.invalidField
        }
        return try approvalDecisionResponse(approval, decision: "decline")
    }

    private func providerApproval(
        method: String, root: [String: Any]
    ) throws -> CodexProviderApproval {
        guard let params = root["params"] as? [String: Any] else {
            throw CodexCapabilityProtocolError.invalidField
        }
        let responseID = try requestID(root)
        let threadID = try identifier(params, "threadId")
        let turnID = try identifier(params, "turnId")
        let itemID = try identifier(params, "itemId")
        _ = try integer64(params, "startedAtMs")
        let kind: CodexProviderApprovalKind
        let toolName: String
        switch method {
        case "item/commandExecution/requestApproval":
            kind = .commandExecution
            toolName = "command-execution"
        case "item/fileChange/requestApproval":
            kind = .fileChange
            toolName = "file-change"
        default:
            throw CodexCapabilityProtocolError.invalidField
        }
        let policy = CapabilityPolicyResolver().resolve(
            serverPolicy: .askBeforeChanges,
            readOnlyHint: false,
            mandatoryProviderApproval: true
        ).effectivePolicy
        let request = try CapabilityApprovalRequest(
            callID: CapabilityCallID(),
            capabilityID: CapabilityID(
                source: .providerNative, serverID: "codex", toolName: toolName
            ),
            summary: CapabilitySummary(text: "Codex requires approval"),
            policy: policy
        )
        let availableDecisions: Set<String>
        if params["availableDecisions"] == nil {
            availableDecisions = ["accept", "decline", "cancel"]
        } else {
            availableDecisions = try supportedApprovalDecisions(
                params["availableDecisions"],
                admitsCommandAmendments: kind == .commandExecution
            )
        }
        return .init(
            responseID: responseID,
            itemID: itemID,
            threadID: threadID,
            turnID: turnID,
            kind: kind,
            request: request,
            availableDecisions: availableDecisions,
            toolUserInputQuestionID: nil
        )
    }

    private func toolUserInputApproval(
        _ root: [String: Any]
    ) throws -> CodexProviderApproval? {
        guard let params = root["params"] as? [String: Any] else {
            throw CodexCapabilityProtocolError.invalidField
        }
        let responseID = try requestID(root)
        let threadID = try identifier(params, "threadId")
        let turnID = try identifier(params, "turnId")
        let itemID = try identifier(params, "itemId")
        if let value = params["autoResolutionMs"], !(value is NSNull) {
            _ = try unsigned64(params, "autoResolutionMs")
        }
        let questions = try objectArray(params["questions"])
        guard questions.count <= 3 else {
            throw CodexCapabilityProtocolError.invalidField
        }
        guard !questions.isEmpty else { return nil }

        var approvalQuestion: (id: String, labels: [String])?
        for question in questions {
            _ = try text(question, "header")
            let questionID = try identifier(question, "id")
            _ = try boolean(question, "isOther", default: false)
            _ = try boolean(question, "isSecret", default: false)
            _ = try text(question, "question")

            var labels: [String] = []
            if let rawOptions = question["options"], !(rawOptions is NSNull) {
                let options = try objectArray(rawOptions)
                guard options.count <= 16 else {
                    throw CodexCapabilityProtocolError.tooManyItems
                }
                labels = try options.map { option in
                    _ = try text(option, "description")
                    return try text(option, "label")
                }
            }
            if questionID.hasPrefix("mcp_tool_call_approval_") {
                guard approvalQuestion == nil else {
                    throw CodexCapabilityProtocolError.invalidField
                }
                approvalQuestion = (questionID, labels)
            }
        }

        guard let approvalQuestion else { return nil }
        let expectedQuestionID = "mcp_tool_call_approval_\(itemID)"
        let expectedLabels: Set<String> = [
            "Approve Once", "Approve this Session", "Deny", "Cancel",
        ]
        guard questions.count == 1,
              approvalQuestion.id == expectedQuestionID,
              approvalQuestion.labels.count == expectedLabels.count,
              Set(approvalQuestion.labels) == expectedLabels,
              try boolean(questions[0], "isOther", default: false) == false,
              try boolean(questions[0], "isSecret", default: false) == false
        else { throw CodexCapabilityProtocolError.invalidField }

        let policy = CapabilityPolicyResolver().resolve(
            serverPolicy: .askBeforeChanges,
            readOnlyHint: false,
            mandatoryProviderApproval: true
        ).effectivePolicy
        let request = try CapabilityApprovalRequest(
            callID: CapabilityCallID(),
            capabilityID: CapabilityID(
                source: .providerNative,
                serverID: "codex",
                toolName: "tool-user-input"
            ),
            summary: CapabilitySummary(text: "Codex connector requires approval"),
            policy: policy
        )
        return .init(
            responseID: responseID,
            itemID: itemID,
            threadID: threadID,
            turnID: turnID,
            kind: .toolUserInput,
            request: request,
            availableDecisions: ["accept", "decline", "cancel"],
            toolUserInputQuestionID: approvalQuestion.id
        )
    }

    private func approvalDecisionResponse(
        _ approval: CodexProviderApproval, decision: String
    ) throws -> Data {
        guard ["accept", "decline", "cancel"].contains(decision) else {
            throw CodexCapabilityProtocolError.invalidField
        }
        let id = try encodedRequestID(approval.responseID)
        if approval.kind == .toolUserInput {
            guard let questionID = approval.toolUserInputQuestionID else {
                throw CodexCapabilityProtocolError.invalidField
            }
            try validateIdentifier(questionID)
            let answer: String
            switch decision {
            case "accept": answer = "Approve Once"
            case "decline": answer = "Deny"
            case "cancel": answer = "Cancel"
            default: throw CodexCapabilityProtocolError.invalidField
            }
            return try encode([
                "id": id,
                "result": [
                    "answers": [questionID: ["answers": [answer]]],
                ] as [String: Any],
            ])
        }
        return try encode(["id": id, "result": ["decision": decision]])
    }

    private func encodedRequestID(_ responseID: JSONRPCRequestID) throws -> Any {
        switch responseID {
        case .string(let value):
            try validateIdentifier(value)
            return value
        case .integer(let value):
            return value
        }
    }

    private func descriptor(
        source: CapabilitySource,
        server: String,
        tool: String,
        displayName: String,
        summary: String,
        schema: Data,
        readOnly: Bool?,
        profileID: UUID,
        accessible: Bool,
        enabled: Bool,
        callable: Bool,
        visibility: CapabilityVisibility
    ) throws -> CapabilityDescriptor {
        let serverID = normalizedComponent(server)
        let toolName = normalizedComponent(tool)
        return try CapabilityDescriptor(
            id: CapabilityID(source: source, serverID: serverID, toolName: toolName),
            source: source,
            serverID: serverID,
            toolName: toolName,
            displayName: utf8Prefix(displayName, maximumBytes: 256),
            summary: utf8Prefix(summary, maximumBytes: 1_024),
            inputSchemaJSON: schema,
            readOnlyHint: readOnly,
            providerProfileIDs: [profileID],
            isAvailable: true,
            isAccessible: accessible,
            isEnabled: enabled,
            isCallable: callable,
            visibility: visibility
        )
    }

    private func uniqueMap<Value>(
        _ values: [Value],
        key: KeyPath<Value, String>
    ) throws -> [String: Value] {
        var result: [String: Value] = [:]
        for value in values {
            let identifier = value[keyPath: key]
            guard result.updateValue(value, forKey: identifier) == nil else {
                throw CodexCapabilityProtocolError.invalidField
            }
        }
        return result
    }

    private func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var count = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard count + bytes <= maximumBytes else { break }
            result.append(character)
            count += bytes
        }
        return result
    }

    private func responseResult(
        _ data: Data, expectedID: String
    ) throws -> [String: Any] {
        try validateIdentifier(expectedID)
        let root = try decodedObject(data)
        guard root["id"] as? String == expectedID,
              root["error"] == nil,
              let result = root["result"] as? [String: Any]
        else { throw CodexCapabilityProtocolError.wrongResponse }
        return result
    }

    private func decodedObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumFrameBytes else {
            throw CodexCapabilityProtocolError.payloadTooLarge
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { throw CodexCapabilityProtocolError.malformedJSON }
            return object
        } catch let error as CodexCapabilityProtocolError {
            throw error
        } catch {
            throw CodexCapabilityProtocolError.malformedJSON
        }
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexCapabilityProtocolError.invalidField
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumFrameBytes else {
            throw CodexCapabilityProtocolError.payloadTooLarge
        }
        return data + Data([0x0A])
    }

    private func validateLimit(_ value: Int) throws {
        guard (1...256).contains(value) else {
            throw CodexCapabilityProtocolError.invalidLimit
        }
    }

    private func validateCursor(_ value: String?) throws {
        if let value { try validateIdentifier(value) }
    }

    private func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumIdentifierBytes,
              !value.utf8.contains(0)
        else { throw CodexCapabilityProtocolError.invalidField }
    }

    private func identifier(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw CodexCapabilityProtocolError.invalidField
        }
        try validateIdentifier(value)
        return value
    }

    private func optionalIdentifier(
        _ object: [String: Any], _ key: String
    ) throws -> String? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            throw CodexCapabilityProtocolError.invalidField
        }
        try validateIdentifier(value)
        return value
    }

    private func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String,
              value.utf8.count <= maximumTextBytes,
              !value.utf8.contains(0)
        else { throw CodexCapabilityProtocolError.invalidField }
        return value
    }

    private func optionalText(
        _ object: [String: Any], _ key: String
    ) throws -> String? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            throw CodexCapabilityProtocolError.invalidField
        }
        guard value.utf8.count <= maximumTextBytes, !value.utf8.contains(0) else {
            throw CodexCapabilityProtocolError.payloadTooLarge
        }
        return value
    }

    private func boolean(
        _ object: [String: Any], _ key: String, default defaultValue: Bool? = nil
    ) throws -> Bool {
        guard let raw = object[key] else {
            if let defaultValue { return defaultValue }
            throw CodexCapabilityProtocolError.invalidField
        }
        guard CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID(),
              let value = raw as? Bool
        else { throw CodexCapabilityProtocolError.invalidField }
        return value
    }

    private func enumText(
        _ object: [String: Any], _ key: String, values: Set<String>
    ) throws -> String {
        let value = try text(object, key)
        guard values.contains(value) else {
            throw CodexCapabilityProtocolError.invalidField
        }
        return value
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw CodexCapabilityProtocolError.invalidField
        }
        return value
    }

    private func objectArray(_ value: Any?) throws -> [[String: Any]] {
        guard let values = value as? [Any] else {
            throw CodexCapabilityProtocolError.invalidField
        }
        return try values.map(object)
    }

    private func optionalObjectArray(_ value: Any?) throws -> [[String: Any]] {
        guard let value, !(value is NSNull) else { return [] }
        return try objectArray(value)
    }

    private func stringArray(_ value: Any?) throws -> [String] {
        guard let values = value as? [Any] else {
            throw CodexCapabilityProtocolError.invalidField
        }
        return try values.map { value in
            guard let value = value as? String else {
                throw CodexCapabilityProtocolError.invalidField
            }
            try validateIdentifier(value)
            return value
        }
    }

    private func supportedApprovalDecisions(
        _ value: Any?,
        admitsCommandAmendments: Bool
    ) throws -> Set<String> {
        guard let values = value as? [Any],
              !values.isEmpty,
              values.count <= maximumItems
        else { throw CodexCapabilityProtocolError.invalidField }
        var supported = Set<String>()
        for value in values {
            if let decision = value as? String {
                try validateIdentifier(decision)
                guard [
                    "accept", "acceptForSession", "decline", "cancel",
                ].contains(decision) else {
                    throw CodexCapabilityProtocolError.invalidField
                }
                if decision != "acceptForSession" {
                    supported.insert(decision)
                }
                continue
            }
            guard admitsCommandAmendments,
                  let choice = value as? [String: Any],
                  choice.count == 1,
                  let kind = choice.keys.first,
                  let amendment = choice[kind] as? [String: Any]
            else { throw CodexCapabilityProtocolError.invalidField }
            switch kind {
            case "acceptWithExecpolicyAmendment":
                guard amendment.count == 1,
                      let rules = amendment["execpolicy_amendment"] as? [Any],
                      !rules.isEmpty,
                      rules.count <= maximumItems
                else { throw CodexCapabilityProtocolError.invalidField }
                for rule in rules {
                    guard let rule = rule as? String,
                          rule.utf8.count <= maximumTextBytes,
                          !rule.utf8.contains(0)
                    else { throw CodexCapabilityProtocolError.invalidField }
                }
            case "applyNetworkPolicyAmendment":
                guard amendment.count == 1,
                      let policy = amendment["network_policy_amendment"]
                        as? [String: Any],
                      policy.count == 2
                else { throw CodexCapabilityProtocolError.invalidField }
                _ = try enumText(policy, "action", values: ["allow", "deny"])
                _ = try text(policy, "host")
            default:
                throw CodexCapabilityProtocolError.invalidField
            }
        }
        guard !supported.isEmpty else {
            throw CodexCapabilityProtocolError.invalidField
        }
        return supported
    }

    private func nextCursor(_ result: [String: Any]) throws -> String? {
        try optionalIdentifier(result, "nextCursor")
    }

    private func boundedJSONObject(_ value: Any?) throws -> Data {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw CodexCapabilityProtocolError.invalidField
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 65_536 else {
            throw CodexCapabilityProtocolError.payloadTooLarge
        }
        return data
    }

    private func requestID(_ root: [String: Any]) throws -> JSONRPCRequestID {
        if let value = root["id"] as? String {
            try validateIdentifier(value)
            return .string(value)
        }
        if root["id"] is NSNumber {
            return .integer(try integer64(root, "id"))
        }
        throw CodexCapabilityProtocolError.invalidField
    }

    private func integer64(_ object: [String: Any], _ key: String) throws -> Int64 {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { throw CodexCapabilityProtocolError.invalidField }
        let value = number.int64Value
        guard number.compare(NSNumber(value: value)) == .orderedSame
        else { throw CodexCapabilityProtocolError.invalidField }
        return value
    }

    private func unsigned64(_ object: [String: Any], _ key: String) throws -> UInt64 {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = UInt64(number.stringValue),
              number.compare(NSNumber(value: value)) == .orderedSame
        else { throw CodexCapabilityProtocolError.invalidField }
        return value
    }

    private func normalizedComponent(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if (33...126).contains(scalar.value), scalar != "/" {
                return Character(String(scalar))
            }
            return "-"
        }
        let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if !value.isEmpty, value.utf8.count <= 96 { return value }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "id-\(String(hash, radix: 16))"
    }
}
