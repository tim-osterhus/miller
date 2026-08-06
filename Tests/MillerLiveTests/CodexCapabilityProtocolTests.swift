import Foundation
import MillerCore
@testable import MillerLive
import Testing

@Suite
struct CodexCapabilityProtocolTests {
    private let profileID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    @Test
    func encodesBoundedInventoryRequests() throws {
        let codec = CodexCapabilityProtocol(maximumFrameBytes: 4_096)

        let list = try object(codec.appsListRequest(
            id: "inventory:apps", cursor: "page-2", limit: 100
        ))
        #expect(list["method"] as? String == "app/list")
        #expect((list["params"] as? [String: Any])?["cursor"] as? String == "page-2")

        let read = try object(codec.appsReadRequest(
            id: "inventory:read", appIDs: ["gmail", "drive"]
        ))
        #expect(read["method"] as? String == "app/read")
        #expect((read["params"] as? [String: Any])?["includeTools"] as? Bool == true)

        let installed = try object(codec.appsInstalledRequest(id: "inventory:installed"))
        #expect(installed["method"] as? String == "app/installed")

        let mcp = try object(codec.mcpServerStatusListRequest(
            id: "inventory:mcp", cursor: nil, limit: 100
        ))
        #expect(mcp["method"] as? String == "mcpServerStatus/list")
        #expect((mcp["params"] as? [String: Any])?["detail"] as? String == "toolsAndAuthOnly")

        #expect(throws: CodexCapabilityProtocolError.tooManyItems) {
            try codec.appsReadRequest(
                id: "inventory:read", appIDs: (0...100).map { "app-\($0)" }
            )
        }
        #expect(throws: CodexCapabilityProtocolError.invalidLimit) {
            try codec.appsListRequest(id: "inventory:apps", cursor: nil, limit: 0)
        }
    }

    @Test
    func projectsAppsAndInstalledRuntimeStateAsCodexOnlyProviderManagedCapabilities() throws {
        let codec = CodexCapabilityProtocol()
        let apps = try codec.decodeAppsListResponse(frame([
            "id": "inventory:apps",
            "result": [
                "data": [[
                    "id": "gmail", "name": "Gmail",
                    "description": "Search mail", "isAccessible": true,
                    "isEnabled": true, "credential": "must-not-survive",
                ]],
                "nextCursor": "next-app-page",
            ] as [String: Any],
        ]), expectedID: "inventory:apps")
        let details = try codec.decodeAppsReadResponse(frame([
            "id": "inventory:read",
            "result": [
                "apps": [[
                    "id": "gmail", "name": "Gmail", "description": "Mail",
                    "toolSummaries": [[
                        "name": "search", "title": "Search Gmail",
                        "description": "Search messages", "isEnabled": true,
                        "isReadOnly": true,
                    ]],
                ]],
                "missingAppIds": [],
            ] as [String: Any],
        ]), expectedID: "inventory:read")
        let installed = try codec.decodeAppsInstalledResponse(frame([
            "id": "inventory:installed",
            "result": ["apps": [[
                "id": "gmail", "enabled": true, "callable": true,
                "runtimeName": "Gmail",
            ]]],
        ]), expectedID: "inventory:installed")

        let catalog = try codec.projectCatalog(
            apps: apps.items,
            appDetails: details,
            installedApps: installed,
            mcpServers: [],
            codexProviderProfileID: profileID,
            existingMillerCapabilities: []
        )

        let descriptor = try #require(catalog.descriptors.first)
        #expect(descriptor.id.rawValue == "codex_account/gmail/search")
        #expect(descriptor.source == .codexAccount)
        #expect(descriptor.providerProfileIDs == [profileID])
        #expect(descriptor.isAccessible)
        #expect(descriptor.isEnabled)
        #expect(descriptor.isCallable)
        #expect(descriptor.visibility == .providerManaged)
        #expect(descriptor.isAvailable(to: profileID))
        #expect(!String(decoding: descriptor.inputSchemaJSON, as: UTF8.self).contains("credential"))
        #expect(apps.nextCursor == "next-app-page")
    }

    @Test
    func unavailableAppsRemainVisibleButNotCallable() throws {
        let codec = CodexCapabilityProtocol()
        let apps = try codec.decodeAppsListResponse(frame([
            "id": "apps", "result": ["data": [[
                "id": "drive", "name": "Drive", "isAccessible": false,
                "isEnabled": true,
            ]], "nextCursor": NSNull()] as [String: Any],
        ]), expectedID: "apps")

        let catalog = try codec.projectCatalog(
            apps: apps.items, appDetails: [], installedApps: [], mcpServers: [],
            codexProviderProfileID: profileID, existingMillerCapabilities: []
        )

        let descriptor = try #require(catalog.descriptors.first)
        #expect(!descriptor.isAccessible)
        #expect(!descriptor.isCallable)
        #expect(!descriptor.isAvailable(to: profileID))

        let noInventedTool = try codec.projectCatalog(
            apps: [.init(
                id: "mail", name: "Mail", summary: "No returned tools",
                isAccessible: true, isEnabled: true
            )],
            appDetails: [],
            installedApps: [.init(
                id: "mail", isEnabled: true, isCallable: true
            )],
            mcpServers: [],
            codexProviderProfileID: profileID,
            existingMillerCapabilities: []
        )
        #expect(noInventedTool.descriptors.first?.isCallable == false)
    }

    @Test
    func rejectsDuplicateInventoryIdentityInsteadOfTrappingOrGuessing() throws {
        let codec = CodexCapabilityProtocol()
        let duplicate = CodexAccountApp(
            id: "gmail",
            name: "Gmail",
            summary: "Mail",
            isAccessible: true,
            isEnabled: true
        )

        #expect(throws: CodexCapabilityProtocolError.invalidField) {
            try codec.projectCatalog(
                apps: [duplicate, duplicate],
                appDetails: [],
                installedApps: [],
                mcpServers: [],
                codexProviderProfileID: profileID,
                existingMillerCapabilities: []
            )
        }

        let appTool = CodexAccountAppTool(
            appID: "gmail", name: "search", title: nil, summary: "Search",
            isEnabled: true, isReadOnly: true
        )
        #expect(throws: CodexCapabilityProtocolError.invalidField) {
            try codec.projectCatalog(
                apps: [duplicate], appDetails: [appTool, appTool],
                installedApps: [.init(
                    id: "gmail", isEnabled: true, isCallable: true
                )],
                mcpServers: [], codexProviderProfileID: profileID,
                existingMillerCapabilities: []
            )
        }

        let mcpTool = CodexMCPTool(
            name: "search", title: nil, summary: "Search",
            inputSchemaJSON: Data("{}".utf8)
        )
        #expect(throws: CodexCapabilityProtocolError.invalidField) {
            try codec.projectCatalog(
                apps: [], appDetails: [], installedApps: [],
                mcpServers: [
                    .init(name: "gmail", authStatus: "loggedIn", tools: [mcpTool]),
                    .init(name: "gmail", authStatus: "loggedIn", tools: [mcpTool]),
                ],
                codexProviderProfileID: profileID,
                existingMillerCapabilities: []
            )
        }
    }

    @Test
    func projectedDisplayAndSummaryBoundsAreUTF8ByteBounds() throws {
        let codec = CodexCapabilityProtocol()
        let app = CodexAccountApp(
            id: "unicode",
            name: String(repeating: "🛰️", count: 300),
            summary: String(repeating: "🌊", count: 600),
            isAccessible: true,
            isEnabled: true
        )
        let installed = CodexInstalledApp(
            id: "unicode", isEnabled: true, isCallable: true
        )

        let catalog = try codec.projectCatalog(
            apps: [app],
            appDetails: [],
            installedApps: [installed],
            mcpServers: [],
            codexProviderProfileID: profileID,
            existingMillerCapabilities: []
        )

        let descriptor = try #require(catalog.descriptors.first)
        #expect(descriptor.displayName.utf8.count <= 256)
        #expect(descriptor.summary.utf8.count <= 1_024)
    }

    @Test
    func reservedBridgeIsExcludedAndReconciledToExistingMillerIdentity() throws {
        let codec = CodexCapabilityProtocol()
        let existing = try CapabilityDescriptor(
            id: CapabilityID(rawValue: "miller_mcp/calendar/list"),
            source: .millerMCP, serverID: "calendar", toolName: "list",
            displayName: "List events", summary: "Lists events",
            inputSchemaJSON: Data("{}".utf8), readOnlyHint: true,
            providerProfileIDs: [profileID], isAvailable: true
        )
        let page = try codec.decodeMCPServerStatusResponse(frame([
            "id": "mcp", "result": [
                "data": [[
                    "name": "miller-capability-bridge", "authStatus": "unsupported",
                    "tools": [existing.bridgeProjectedToolName: [
                        "name": existing.bridgeProjectedToolName,
                        "description": "Duplicate",
                        "inputSchema": ["type": "object"],
                    ]],
                    "resources": [], "resourceTemplates": [],
                ]],
                "nextCursor": NSNull(),
            ] as [String: Any],
        ]), expectedID: "mcp")

        let catalog = try codec.projectCatalog(
            apps: [], appDetails: [], installedApps: [], mcpServers: page.items,
            codexProviderProfileID: profileID,
            existingMillerCapabilities: [existing]
        )

        #expect(catalog.descriptors == [existing])
        #expect(!catalog.descriptors.contains { $0.source == .codexAccount })

        let activity = try codec.decodeActivity(frame([
            "method": "item/started",
            "params": [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "startedAtMs": 1,
                "item": [
                    "type": "mcpToolCall",
                    "id": "bridge-call-1",
                    "server": CodexCapabilityProtocol.reservedBridgeServerID,
                    "tool": existing.bridgeProjectedToolName,
                    "status": "inProgress",
                    "arguments": [:] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]), existingMillerCapabilities: [existing])
        guard case .activity(let projected) = activity else {
            Issue.record("Expected reconciled bridge activity")
            return
        }
        #expect(projected.capabilityID == existing.id)
    }

    @Test
    func lifecycleProjectionIsSanitizedOpaqueAndIgnoresUnknownFutureItems() throws {
        let codec = CodexCapabilityProtocol(maximumRawItemBytes: 512)
        let started = try codec.decodeActivity(frame([
            "method": "item/started",
            "params": [
                "threadId": "thread-1", "turnId": "turn-1", "startedAtMs": 1,
                "item": [
                    "type": "mcpToolCall", "id": "call-1", "server": "gmail",
                    "tool": "search", "status": "inProgress",
                    "arguments": ["query": "private query"],
                    "appContext": ["connectorId": "gmail", "actionName": "search"],
                ] as [String: Any],
            ] as [String: Any],
        ]))
        guard case .activity(let activity) = started else {
            Issue.record("Expected sanitized activity"); return
        }
        #expect(activity.capabilityID.rawValue == "codex_account/gmail/search")
        #expect(activity.phase == .started)
        #expect(activity.visibility == .opaqueProviderActivity)
        #expect(!activity.summary.text.contains("private query"))

        let completed = try codec.decodeActivity(frame([
            "method": "item/completed",
            "params": [
                "threadId": "thread-1", "turnId": "turn-1", "completedAtMs": 2,
                "item": [
                    "type": "webSearch", "id": "web-1",
                    "query": "private query", "results": [["secret": "result"]],
                ],
            ],
        ]))
        guard case .activity(let web) = completed else {
            Issue.record("Expected web activity"); return
        }
        #expect(web.capabilityID.rawValue == "provider_native/codex/websearch")
        #expect(web.phase == .terminal)
        #expect(web.outcome == .succeeded)
        #expect(web.visibility == .opaqueProviderActivity)
        #expect(!web.summary.text.contains("private"))

        #expect(try codec.decodeActivity(frame([
            "method": "item/started",
            "params": ["threadId": "t", "turnId": "u", "item": [
                "type": "futureTool", "id": "future-1", "opaque": "ignored",
            ]],
        ])) == .ignored)

        let oversized = try frame([
            "method": "item/started",
            "params": ["threadId": "t", "turnId": "u", "item": [
                "type": "futureTool", "id": "future-1",
                "opaque": String(repeating: "x", count: 600),
            ]],
        ])
        #expect(try codec.decodeActivity(oversized) == .ignored)

        let largeOrdinaryMessage = try frame([
            "method": "item/agentMessage/delta",
            "params": ["delta": String(repeating: "x", count: 600)],
        ])
        #expect(try codec.decodeActivity(largeOrdinaryMessage) == .notCapability)

        for method in ["item/started", "item/completed"] {
            #expect(throws: CodexCapabilityProtocolError.invalidField) {
                try codec.decodeActivity(frame([
                    "method": method,
                    "params": [
                        "threadId": "thread-1",
                        "item": [
                            "type": "webSearch", "id": "web-missing-turn",
                            "query": "private",
                        ],
                    ],
                ]))
            }
        }
        guard case .activity(let realtimeWithoutTurn) = try codec.decodeActivity(frame([
            "method": "thread/realtime/itemAdded",
            "params": [
                "threadId": "thread-1",
                "item": [
                    "type": "webSearch", "id": "web-realtime",
                    "query": "private",
                ],
            ],
        ])) else {
            Issue.record("Expected realtime activity without a turn")
            return
        }
        #expect(realtimeWithoutTurn.turnID == nil)

        for method in ["item/started", "item/completed"] {
            #expect(throws: CodexCapabilityProtocolError.invalidField) {
                try codec.decodeActivity(frame([
                    "method": method,
                    "params": [
                        "threadId": "thread-1", "turnId": "turn-1",
                        "item": [
                            "type": "webSearch", "id": "web-missing-time",
                            "query": "private",
                        ],
                    ],
                ]))
            }
        }

        for (method, status) in [
            ("item/started", "completed"),
            ("item/completed", "inProgress"),
        ] {
            var params: [String: Any] = [
                "threadId": "thread-1", "turnId": "turn-1",
                "item": [
                    "type": "mcpToolCall", "id": "contradiction",
                    "server": "gmail", "tool": "search",
                    "status": status, "arguments": [:],
                ] as [String: Any],
            ]
            params[method == "item/started" ? "startedAtMs" : "completedAtMs"] = 3
            #expect(throws: CodexCapabilityProtocolError.invalidField) {
                try codec.decodeActivity(frame([
                    "method": method,
                    "params": params,
                ]))
            }
        }
    }

    @Test
    func providerApprovalUsesMillerContractAndResponseChannel() throws {
        let codec = CodexCapabilityProtocol()
        let decoded = try codec.decodeActivity(frame([
            "id": "approval-1",
            "method": "item/commandExecution/requestApproval",
            "params": [
                "threadId": "thread-1", "turnId": "turn-1",
                "itemId": "command-1", "startedAtMs": 1,
                "command": "do-not-retain --secret", "reason": "Needs access",
            ] as [String: Any],
        ]))
        guard case .approval(let approval) = decoded else {
            Issue.record("Expected provider approval"); return
        }
        #expect(approval.request.policy.requiresApproval)
        #expect(approval.request.policy.reason == "provider_approval_required")
        #expect(!approval.request.summary.text.contains("secret"))

        let allow = try object(codec.approvalResponse(
            approval, decision: .allowOnce
        ))
        #expect(allow["id"] as? String == "approval-1")
        #expect((allow["result"] as? [String: Any])?["decision"] as? String == "accept")

        let decline = try object(codec.approvalResponse(
            approval, decision: .decline
        ))
        #expect((decline["result"] as? [String: Any])?["decision"] as? String == "decline")

        let cancel = try object(codec.cancelApprovalResponse(approval))
        #expect((cancel["result"] as? [String: Any])?["decision"] as? String == "cancel")

        let declineOnly = try codec.decodeActivity(frame([
            "id": "approval-2",
            "method": "item/fileChange/requestApproval",
            "params": [
                "threadId": "thread-1", "turnId": "turn-1",
                "itemId": "file-1", "startedAtMs": 2,
                "availableDecisions": ["decline", "cancel"],
            ] as [String: Any],
        ]))
        guard case .approval(let restricted) = declineOnly else {
            Issue.record("Expected restricted approval"); return
        }
        let restrictedResponse = try object(codec.approvalResponse(
            restricted, decision: .allowOnce
        ))
        #expect(
            (restrictedResponse["result"] as? [String: Any])?["decision"] as? String
                == "decline"
        )

        let mixed = try codec.decodeActivity(frame([
            "id": "approval-mixed",
            "method": "item/commandExecution/requestApproval",
            "params": [
                "threadId": "thread-1", "turnId": "turn-1",
                "itemId": "command-mixed", "startedAtMs": 3,
                "availableDecisions": [
                    "accept",
                    [
                        "acceptWithExecpolicyAmendment": [
                            "execpolicy_amendment": ["prefix_rule(pattern=[\"git\", \"status\"], decision=\"allow\")"],
                        ],
                    ],
                    [
                        "applyNetworkPolicyAmendment": [
                            "network_policy_amendment": [
                                "action": "allow", "host": "example.com",
                            ],
                        ],
                    ],
                    "decline",
                ] as [Any],
            ] as [String: Any],
        ]))
        guard case .approval(let mixedApproval) = mixed else {
            Issue.record("Expected mixed command approval")
            return
        }
        #expect(mixedApproval.availableDecisions == ["accept", "decline"])
        let mixedResponse = try object(codec.approvalResponse(
            mixedApproval, decision: .allowOnce
        ))
        #expect(
            (mixedResponse["result"] as? [String: Any])?["decision"] as? String
                == "accept"
        )

        #expect(throws: CodexCapabilityProtocolError.invalidField) {
            try codec.decodeActivity(frame([
                "id": 1.5,
                "method": "item/fileChange/requestApproval",
                "params": [
                    "threadId": "thread-1", "turnId": "turn-1",
                    "itemId": "file-1", "startedAtMs": 2,
                ] as [String: Any],
            ]))
        }

        #expect(throws: CodexCapabilityProtocolError.invalidField) {
            try codec.decodeActivity(Data(
                #"{"id":9223372036854775808,"method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"file-1","startedAtMs":2}}"#.utf8
            ))
        }

        #expect(throws: CodexCapabilityProtocolError.invalidField) {
            try codec.decodeActivity(frame([
                "method": "item/started",
                "params": [
                    "threadId": "thread-1", "turnId": "turn-1", "startedAtMs": 1,
                    "item": [
                        "type": "mcpToolCall", "id": "call-1",
                        "server": "gmail", "tool": "search",
                        "status": "inProgress",
                    ],
                ],
            ]))
        }
    }

    @Test
    func connectorToolApprovalUsesRealBoundedAnswersShape() throws {
        let codec = CodexCapabilityProtocol()
        let questionID = "mcp_tool_call_approval_call-717"
        let variants = [
            ["Allow", "Cancel"],
            ["Allow", "Allow for this session", "Cancel"],
            [
                "Allow", "Allow for this session",
                "Allow and don't ask me again", "Cancel",
            ],
        ]
        for labels in variants {
            let options = labels.map {
                ["description": "Codex option", "label": $0]
            }
            let decoded = try codec.decodeActivity(frame([
                "id": 110,
                "method": "item/tool/requestUserInput",
                "params": [
                    "itemId": "call-717",
                    "questions": [[
                        "header": "Approve app tool call?",
                        "id": questionID,
                        "isOther": false,
                        "isSecret": false,
                        "options": options,
                        "question": "The connector wants to modify data. Allow this action?",
                    ] as [String: Any]],
                    "threadId": "thread-717",
                    "turnId": "turn-717",
                ] as [String: Any],
            ]))
            guard case .approval(let approval) = decoded else {
                Issue.record("Expected connector approval")
                return
            }
            #expect(approval.kind == .toolUserInput)
            #expect(approval.request.policy.requiresApproval)
            #expect(approval.request.summary.text == "Codex connector requires approval")

            for (decision, expected) in [
                (CapabilityApprovalDecision.allowOnce, "Allow"),
                (.decline, "__codex_mcp_decline__"),
            ] {
                let response = try object(codec.approvalResponse(
                    approval, decision: decision
                ))
                #expect(response["id"] as? Int == 110)
                let answers = try #require(
                    (response["result"] as? [String: Any])?["answers"]
                        as? [String: Any]
                )
                let answer = try #require(answers[questionID] as? [String: Any])
                #expect(answer["answers"] as? [String] == [expected])
            }
            let cancelled = try object(codec.cancelApprovalResponse(approval))
            let cancelAnswers = try #require(
                (cancelled["result"] as? [String: Any])?["answers"]
                    as? [String: Any]
            )
            #expect(
                (cancelAnswers[questionID] as? [String: Any])?["answers"]
                    as? [String] == ["Cancel"]
            )
        }
    }

    @Test
    func connectorToolInputBoundsMalformedApprovalAndIgnoresNonApproval() throws {
        let codec = CodexCapabilityProtocol(maximumTextBytes: 128)
        let freeform = try codec.decodeActivity(frame([
            "id": "freeform-1",
            "method": "item/tool/requestUserInput",
            "params": [
                "itemId": "call-freeform",
                "questions": [[
                    "header": "Provide context", "id": "freeform-1",
                    "isOther": false, "isSecret": false,
                    "options": NSNull(), "question": "What should I post?",
                ] as [String: Any]],
                "threadId": "thread-1", "turnId": "turn-1",
            ] as [String: Any],
        ]))
        #expect(freeform == .ignored)
        let empty = try codec.decodeActivity(frame([
            "id": "empty-1",
            "method": "item/tool/requestUserInput",
            "params": [
                "itemId": "call-empty", "questions": [],
                "threadId": "thread-1", "turnId": "turn-1",
            ] as [String: Any],
        ]))
        #expect(empty == .ignored)

        let baseParams: [String: Any] = [
            "itemId": "call-1",
            "questions": [[
                "header": "Approve", "id": "mcp_tool_call_approval_call-1",
                "isOther": false, "isSecret": false,
                "options": [
                    ["description": "Approve", "label": "Allow"],
                    ["description": "Cancel", "label": "Cancel"],
                ],
                "question": "Allow this action?",
            ] as [String: Any]],
            "threadId": "thread-1", "turnId": "turn-1",
        ]
        for corrupt in [
            { () -> [String: Any] in
                var params = baseParams
                params["turnId"] = NSNull()
                return params
            }(),
            { () -> [String: Any] in
                var params = baseParams
                var questions = params["questions"] as! [[String: Any]]
                questions[0]["id"] = "mcp_tool_call_approval_other-call"
                params["questions"] = questions
                return params
            }(),
            { () -> [String: Any] in
                var params = baseParams
                var questions = params["questions"] as! [[String: Any]]
                questions[0]["options"] = [[
                    "description": "Approve", "label": "Allow",
                ]]
                params["questions"] = questions
                return params
            }(),
            { () -> [String: Any] in
                var params = baseParams
                var questions = params["questions"] as! [[String: Any]]
                questions[0]["options"] = [
                    ["description": "Approve", "label": "Allow"],
                    ["description": "Duplicate", "label": "Allow"],
                    ["description": "Cancel", "label": "Cancel"],
                ]
                params["questions"] = questions
                return params
            }(),
            { () -> [String: Any] in
                var params = baseParams
                var questions = params["questions"] as! [[String: Any]]
                questions[0]["options"] = [
                    ["description": "Approve", "label": "Allow"],
                    ["description": "Unknown", "label": "Always allow"],
                    ["description": "Cancel", "label": "Cancel"],
                ]
                params["questions"] = questions
                return params
            }(),
            { () -> [String: Any] in
                var params = baseParams
                var questions = params["questions"] as! [[String: Any]]
                questions[0]["question"] = String(repeating: "x", count: 129)
                params["questions"] = questions
                return params
            }(),
        ] {
            #expect(throws: CodexCapabilityProtocolError.invalidField) {
                try codec.decodeActivity(frame([
                    "id": "bad", "method": "item/tool/requestUserInput",
                    "params": corrupt,
                ]))
            }
        }
    }
}

private func frame(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
