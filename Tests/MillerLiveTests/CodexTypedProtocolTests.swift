@testable import MillerLive
import Foundation
import Testing

@Suite
struct CodexTypedProtocolTests {
    @Test
    func registersPortableSkillRootAndAttachesSkillInput() throws {
        let codec = CodexTypedProtocol()
        let roots = try object(codec.skillsExtraRootsSetRequest(
            id: "request:skills-roots", roots: ["/private/runtime"]
        ))
        #expect(roots["method"] as? String == "skills/extraRoots/set")
        #expect((roots["params"] as? [String: Any])?["extraRoots"] as? [String]
            == ["/private/runtime"])
        let list = try object(codec.skillsListRequest(
            id: "request:skills-list", cwd: "/private/runtime"
        ))
        #expect(list["method"] as? String == "skills/list")

        let turn = try object(codec.turnStartRequest(
            id: "request:turn-start", threadID: "thread", cwd: "/private/runtime",
            context: [], userText: "hello",
            skills: [.init(name: "Example", path: "/private/runtime/skills/example/SKILL.md")]
        ))
        let params = try #require(turn["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])
        #expect(input.count == 2)
        #expect(input[1]["type"] as? String == "skill")
        #expect(input[1]["name"] as? String == "Example")
    }
    private let codec = CodexTypedProtocol(
        maximumIdentifierBytes: 64,
        maximumTextBytes: 128,
        maximumItems: 4
    )

    @Test
    func encodesStableEphemeralThreadAndTurnRequests() throws {
        #expect(CodexTypedProtocol.permissionProfileArguments.contains(
            "default_permissions=\"miller-typed-read-only\""
        ))

        let initialize = try object(codec.initializeRequest(id: "typed:initialize"))
        let initializeParams = try #require(initialize["params"] as? [String: Any])
        let capabilities = try #require(initializeParams["capabilities"] as? [String: Any])
        #expect(capabilities["experimentalApi"] as? Bool == true)

        let start = try object(codec.threadStartRequest(
            id: "typed:thread",
            model: "gpt-5.6-terra",
            cwd: "/private/tmp/miller"
        ))
        #expect(start["method"] as? String == "thread/start")
        let startParams = try #require(start["params"] as? [String: Any])
        #expect(startParams["ephemeral"] as? Bool == true)
        #expect(startParams["approvalPolicy"] as? String == "never")
        #expect(startParams["permissions"] == nil)
        #expect(startParams["runtimeWorkspaceRoots"] == nil)
        #expect(startParams["sandbox"] == nil)
        #expect(startParams["sandboxPolicy"] == nil)

        let turn = try object(codec.turnStartRequest(
            id: "typed:turn",
            threadID: "thr_1",
            cwd: "/private/tmp/miller",
            context: [
                .init(role: "user", text: "Earlier question"),
                .init(role: "assistant", text: "Earlier answer"),
            ],
            userText: "Current question"
        ))
        #expect(turn["method"] as? String == "turn/start")
        let turnParams = try #require(turn["params"] as? [String: Any])
        #expect(turnParams["cwd"] as? String == "/private/tmp/miller")
        #expect(turnParams["approvalPolicy"] as? String == "never")
        #expect(turnParams["permissions"] == nil)
        #expect(turnParams["runtimeWorkspaceRoots"] == nil)
        #expect(turnParams["sandboxPolicy"] == nil)
        let input = try #require(turnParams["input"] as? [[String: Any]])
        #expect(input.count == 1)
        let text = try #require(input[0]["text"] as? String)
        #expect(text.contains("Earlier question"))
        #expect(text.contains("Earlier answer"))
        #expect(text.hasSuffix("Current question"))

        let source = String(data: try codec.turnStartRequest(
            id: "typed:turn-2", threadID: "thr_1", cwd: "/private/tmp/miller",
            context: [], userText: "hello"
        ), encoding: .utf8)!
        #expect(!source.contains("dynamicTools"))
        #expect(!source.contains("item/tool/call"))
    }

    @Test
    func decodesAssistantStreamingAndTerminalSequence() throws {
        #expect(try codec.decode(frame([
            "method": "turn/started",
            "params": ["threadId": "thr_1", "turn": [
                "id": "turn_1", "status": "inProgress", "items": [], "error": NSNull(),
            ]],
        ])) == .turnStarted(threadID: "thr_1", turnID: "turn_1"))
        #expect(try codec.decode(frame([
            "method": "item/agentMessage/delta",
            "params": [
                "threadId": "thr_1", "turnId": "turn_1",
                "itemId": "item_1", "delta": "hello",
            ],
        ])) == .assistantTextDelta(
            threadID: "thr_1", turnID: "turn_1", itemID: "item_1", text: "hello"
        ))
        #expect(try codec.decode(frame([
            "method": "item/completed",
            "params": [
                "threadId": "thr_1", "turnId": "turn_1",
                "item": ["type": "agentMessage", "id": "item_1", "text": "hello"],
            ],
        ])) == .assistantMessageCompleted(
            threadID: "thr_1", turnID: "turn_1", itemID: "item_1", text: "hello"
        ))
        #expect(try codec.decode(frame([
            "method": "turn/completed",
            "params": ["threadId": "thr_1", "turn": [
                "id": "turn_1", "status": "completed", "items": [], "error": NSNull(),
            ]],
        ])) == .turnCompleted(threadID: "thr_1", turnID: "turn_1", outcome: .completed))
    }

    @Test
    func acceptsOnlyUnauthorizedCredentialRefreshRequests() throws {
        let valid = try codec.decode(frame([
            "id": "refresh-1",
            "method": "account/chatgptAuthTokens/refresh",
            "params": ["reason": "unauthorized", "previousAccountId": "account-1"],
        ]))
        #expect(valid == .credentialRefresh(
            id: .string("refresh-1"), previousAccountID: "account-1"
        ))

        for params in [
            [:] as [String: Any],
            ["reason": "expired"] as [String: Any],
        ] {
            #expect(throws: CodexTypedProtocolError.invalidField) {
                _ = try codec.decode(frame([
                    "id": "refresh-invalid",
                    "method": "account/chatgptAuthTokens/refresh",
                    "params": params,
                ]))
            }
        }
    }

    @Test
    func requiresReturnedReadOnlyThreadAuthority() throws {
        let cwd = "/private/tmp/miller"
        let valid = try codec.decode(frame(threadStartResponse(cwd: cwd)))
        #expect(valid == .threadStartResponse(
            id: "typed:thread-start",
            threadID: "thr_1",
            authority: .init(
                permissionProfileID: "miller-typed-read-only",
                cwd: cwd,
                runtimeWorkspaceRoots: [cwd],
                sandboxType: "readOnly",
                networkAccess: false,
                ephemeral: true
            )
        ))

        var invalidResponses: [[String: Any]] = []
        var missingProfile = threadStartResponse(cwd: cwd)
        missingProfile["result"] = threadStartResult(cwd: cwd, profileID: nil)
        invalidResponses.append(missingProfile)
        invalidResponses.append(threadStartResponse(cwd: cwd, profileID: "wrong"))
        invalidResponses.append(threadStartResponse(cwd: cwd, sandboxType: "workspaceWrite"))
        invalidResponses.append(threadStartResponse(cwd: cwd, networkAccess: true))
        invalidResponses.append(threadStartResponse(
            cwd: cwd, runtimeWorkspaceRoots: ["/private/tmp/other"]
        ))
        invalidResponses.append(threadStartResponse(cwd: cwd, ephemeral: false))
        for response in invalidResponses {
            #expect(throws: CodexTypedProtocolError.invalidField) {
                _ = try codec.decode(frame(response))
            }
        }
    }

    @Test
    func projectsSafeCapabilityKindsAndIgnoresSensitiveItems() throws {
        for (item, expected) in [
            (["type": "webSearch", "id": "item_1"], CodexTypedCapabilityKind.webSearch),
            (["type": "mcpToolCall", "id": "item_1"], .mcpToolCall),
            ([
                "type": "mcpToolCall", "id": "item_1",
                "appContext": ["resourceUri": "private"],
            ], .appToolCall),
        ] {
            #expect(try codec.decode(frame([
                "method": "item/started",
                "params": [
                    "threadId": "thr_1", "turnId": "turn_1",
                    "item": item,
                ],
            ])) == .capabilityActivity(
                threadID: "thr_1", turnID: "turn_1", itemID: "item_1",
                kind: expected, phase: .started
            ))
        }

        #expect(try codec.decode(frame([
            "method": "future/notification",
        ])) == .ignored)

        let approval = try codec.decode(frame([
            "id": "approval-1",
            "method": "item/commandExecution/requestApproval",
            "params": ["reason": "private", "command": ["private"]],
        ]))
        #expect(approval == .unsupportedApproval(id: .string("approval-1")))
        let decline = try object(codec.declineUnsupportedApproval(
            id: .string("approval-1")
        ))
        #expect((decline["result"] as? [String: Any])?["decision"] as? String == "decline")

        let permissions = try codec.decode(frame([
            "id": "permissions-1",
            "method": "item/permissions/requestApproval",
            "params": ["permissions": ["network": ["enabled": true]]],
        ]))
        #expect(permissions == .unsupportedPermissionsApproval(
            id: .string("permissions-1")
        ))
        let deniedPermissions = try object(codec.declineUnsupportedPermissionsApproval(
            id: .string("permissions-1")
        ))
        let result = try #require(deniedPermissions["result"] as? [String: Any])
        #expect((result["permissions"] as? [String: Any])?.isEmpty == true)
        #expect(result["scope"] as? String == "turn")
        #expect(result["strictAutoReview"] as? Bool == true)

        for type in ["reasoning", "commandExecution", "fileChange"] {
            #expect(try codec.decode(frame([
                "method": "item/completed",
                "params": [
                    "threadId": "thr_1", "turnId": "turn_1",
                    "item": [
                        "type": type, "id": "item_1",
                        "text": "hidden", "aggregatedOutput": "secret", "diff": "secret",
                    ],
                ],
            ])) == .ignored)
        }
        #expect(try codec.decode(frame([
            "method": "item/completed",
            "params": [
                "threadId": "thr_1", "turnId": "turn_1",
                "item": [
                    "type": "mcpToolCall", "id": "item_2", "status": "failed",
                ],
            ],
        ])) == .capabilityActivity(
            threadID: "thr_1", turnID: "turn_1", itemID: "item_2",
            kind: .mcpToolCall, phase: .failed
        ))
    }

    @Test
    func encodesProtocolFeatureProbeWithoutVersionGating() throws {
        let requests = try codec.featureProbeRequests(
            requestPrefix: "probe", cwd: "/private/tmp/miller"
        ).map(object)
        #expect(requests.map { $0["method"] as? String } == [
            "app/list", "mcpServerStatus/list", "skills/list",
        ])
        let encoded = requests.map { String(describing: $0) }.joined()
        #expect(!encoded.contains("0.146.0"))

        let arguments = CodexTypedProtocol.permissionProfileArguments
        #expect(arguments.contains { $0.contains("miller-typed-read-only") })
        #expect(arguments.contains { $0.contains(":minimal") })
        #expect(arguments.contains { $0.contains(":workspace_roots") })
        #expect(arguments.contains { $0.contains("network.enabled=false") })
    }

    @Test
    func rejectsOversizeIdentifiersTextItemsAndInvalidTerminals() throws {
        #expect(throws: CodexTypedProtocolError.identifierTooLarge) {
            try codec.decode(frame([
                "method": "item/agentMessage/delta",
                "params": [
                    "threadId": String(repeating: "x", count: 65),
                    "turnId": "turn", "itemId": "item", "delta": "ok",
                ],
            ]))
        }
        #expect(throws: CodexTypedProtocolError.textTooLarge) {
            try codec.decode(frame([
                "method": "item/agentMessage/delta",
                "params": [
                    "threadId": "thr", "turnId": "turn", "itemId": "item",
                    "delta": String(repeating: "x", count: 129),
                ],
            ]))
        }
        #expect(throws: CodexTypedProtocolError.tooManyItems) {
            try codec.decode(frame([
                "method": "turn/completed",
                "params": ["threadId": "thr", "turn": [
                    "id": "turn", "status": "completed",
                    "items": Array(repeating: ["type": "agentMessage"], count: 5),
                    "error": NSNull(),
                ]],
            ]))
        }
        #expect(throws: CodexTypedProtocolError.invalidSequence) {
            var sequence = CodexTypedTerminalSequence()
            _ = try sequence.accept(.turnCompleted(
                threadID: "thr", turnID: "turn", outcome: .completed
            ))
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func frame(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func threadStartResponse(
        cwd: String,
        profileID: String? = "miller-typed-read-only",
        sandboxType: String = "readOnly",
        networkAccess: Bool = false,
        runtimeWorkspaceRoots: [String]? = nil,
        ephemeral: Bool = true
    ) -> [String: Any] {
        [
            "id": "typed:thread-start",
            "result": threadStartResult(
                cwd: cwd,
                profileID: profileID,
                sandboxType: sandboxType,
                networkAccess: networkAccess,
                runtimeWorkspaceRoots: runtimeWorkspaceRoots,
                ephemeral: ephemeral
            ),
        ]
    }

    private func threadStartResult(
        cwd: String,
        profileID: String?,
        sandboxType: String = "readOnly",
        networkAccess: Bool = false,
        runtimeWorkspaceRoots: [String]? = nil,
        ephemeral: Bool = true
    ) -> [String: Any] {
        var result: [String: Any] = [
            "approvalPolicy": "never",
            "cwd": cwd,
            "runtimeWorkspaceRoots": runtimeWorkspaceRoots ?? [cwd],
            "sandbox": ["type": sandboxType, "networkAccess": networkAccess],
            "thread": ["id": "thr_1", "cwd": cwd, "ephemeral": ephemeral],
        ]
        if let profileID {
            result["activePermissionProfile"] = ["id": profileID]
        }
        return result
    }
}
