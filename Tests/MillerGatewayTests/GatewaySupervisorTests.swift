import Foundation
import MillerCore
@testable import MillerGateway
import Testing

@Suite(.serialized)
struct GatewaySupervisorTests {
    @Test
    func authenticationTerminalIsAcceptedForItsRegisteredOperation() throws {
        var validator = GatewaySessionValidator()
        let sessionID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        let operationID = UUID().uuidString.lowercased()
        let credentialReference = UUID().uuidString.lowercased()

        try validator.accept(
            GatewayRecord.make(
                type: "gateway.ready",
                sessionID: sessionID,
                fields: [
                    "helper_version": .string("fixture"),
                    "supported_protocols": .array([.integer(1)]),
                ]
            )
        )
        try validator.register(
            requestID: requestID,
            turnID: operationID,
            generation: 1
        )
        let terminal: Void? = try? validator.accept(
            GatewayRecord.make(
                type: "auth.completed",
                sessionID: sessionID,
                requestID: requestID,
                fields: [
                    "operation_id": .string(operationID),
                    "generation": .integer(1),
                    "credential_ref": .string(credentialReference),
                ]
            )
        )

        #expect(terminal != nil)
    }

    @Test
    func authenticationCandidateIsAcknowledgedBeforeItsTerminalRecord() async throws {
        let supervisor = GatewaySupervisor(
            configuration: productionAuthenticationConfiguration()
        )
        let source = try await supervisor.beginAuthentication(
            reference: UUID(),
            providerKind: "codex_oauth"
        )
        var iterator = source.makeAsyncIterator()
        let opened = try #require(try await iterator.next())
        guard case let .openURL(operation, url) = opened else {
            Issue.record("Expected an authentication URL")
            return
        }
        #expect(url.host == "127.0.0.1")
        let candidate = try #require(try await iterator.next())
        guard case let .credentialCandidate(candidateOperation, payload) = candidate else {
            Issue.record("Expected an authentication candidate")
            return
        }
        #expect(candidateOperation == operation)
        #expect(!payload.isEmpty)

        try await supervisor.acknowledgeAuthentication(operation, persisted: true)

        let completed = try #require(try await iterator.next())
        guard case let .completed(completedOperation) = completed else {
            Issue.record("Expected authentication completion")
            return
        }
        #expect(completedOperation == operation)
        #expect(try await iterator.next() == nil)
        await supervisor.shutdown()
    }

    @Test
    func helperBackedReadinessTracksSyntheticRestoreAndClear() async throws {
        let supervisor = GatewaySupervisor(
            configuration: productionAuthenticationConfiguration()
        )
        let reference = UUID()
        let credential = try JSONSerialization.data(
            withJSONObject: ["kind": "api_key", "key": "synthetic"],
            options: [.sortedKeys]
        )
        let profile = GatewayProviderProfile(
            kind: "openai_compatible",
            baseURL: "http://127.0.0.1:1/v1",
            model: "fixture-model",
            credentialReference: reference
        )

        try await supervisor.restoreCredential(
            reference: reference,
            credential: credential
        )
        let ready = try await supervisor.providerReadiness(profile: profile)
        #expect(ready.status == "ready")

        try await supervisor.clearCredential(reference: reference)
        let cleared = try await supervisor.providerReadiness(profile: profile)
        #expect(cleared.status == "authentication_required")
        await supervisor.shutdown()
    }

    @Test
    func codexModelCatalogComesFromTheIdleFakeHelperExchange() async throws {
        let supervisor = GatewaySupervisor(configuration: configuration(mode: "normal"))

        let catalog = try await supervisor.codexModelCatalog()

        #expect(catalog.providerKind == "codex_oauth")
        #expect(catalog.defaultModel == "gpt-5.6-terra")
        #expect(catalog.models == [
            GatewayModelChoice(id: "gpt-5.6-terra", name: "GPT-5.6 Terra"),
            GatewayModelChoice(id: "gpt-5.4", name: "GPT-5.4"),
        ])
        await supervisor.shutdown()
    }

    @Test
    func firstAndFollowUpTurnsCompleteThroughTheFakeProvider() async throws {
        let supervisor = GatewaySupervisor(configuration: configuration(mode: "normal"))
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )

        for text in ["first", "follow-up"] {
            let events = try await collect(try await gateway.start(request(text: text)))
            #expect(events.first == .accepted)
            #expect(events.contains(.textDelta(ordinal: 0, text: "fake: \(text)")))
            #expect(events.last == .completed)
        }
        await supervisor.shutdown()
    }

    @Test
    func explicitVoiceHistoryTravelsSeparatelyAndOrdinaryRequestsOmitIt() async throws {
        let supervisor = GatewaySupervisor(configuration: configuration(mode: "normal"))
        let gateway = JSONLReasoningGateway(supervisor: supervisor, selectedProvider: providerProfile)
        let attachment = try VoiceHistoryAttachment(
            text: "<miller_voice_history selection=\"explicit\" truncated=\"false\">\n[history]\n</miller_voice_history>"
        )

        let attached = try await collect(try await gateway.start(request(text: "question", attachment: attachment)))
        #expect(attached.contains(.textDelta(
            ordinal: 0,
            text: "fake: \(attachment.text)\n\nquestion"
        )))
        let ordinary = try await collect(try await gateway.start(request(text: "ordinary")))
        #expect(ordinary.contains(.textDelta(ordinal: 0, text: "fake: ordinary")))
        await supervisor.shutdown()
    }

    @Test
    func swiftProtocolBoundsAndClosesVoiceHistoryAttachment() throws {
        let sessionID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        var fields: [String: JSONValue] = [
            "conversation_id": .string(UUID().uuidString.lowercased()),
            "turn_id": .string(UUID().uuidString.lowercased()),
            "generation": .integer(1),
            "provider_profile": .object([
                "kind": .string("fake"), "model": .string("fake"),
                "credential_ref": .string(UUID().uuidString.lowercased()),
            ]),
            "context": .array([]), "user_text": .string("question"), "tools": .array([]),
            "voice_history_attachment": .string(String(repeating: "é", count: 16_384)),
        ]
        _ = try GatewayRecord.make(
            type: "reasoning.start", sessionID: sessionID,
            requestID: requestID, fields: fields
        )
        fields["voice_history_attachment"] = .string(String(repeating: "é", count: 16_385))
        #expect(throws: GatewayProtocolError.invalidField) {
            try GatewayRecord.make(
                type: "reasoning.start", sessionID: sessionID,
                requestID: requestID, fields: fields
            )
        }
        fields.removeValue(forKey: "voice_history_attachment")
        fields["voice_history"] = .string("unexpected")
        #expect(throws: GatewayProtocolError.unknownField) {
            try GatewayRecord.make(
                type: "reasoning.start", sessionID: sessionID,
                requestID: requestID, fields: fields
            )
        }
    }

    @Test
    func unsupportedModelFailureIsPreservedForTheCore() async throws {
        let supervisor = GatewaySupervisor(
            configuration: configuration(mode: "unsupported-model")
        )
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )

        let events = try await collect(try await gateway.start(request(text: "test")))

        #expect(events == [
            .accepted,
            .failed(
                code: "unsupported_model",
                message: "The selected model is unavailable for this account."
            ),
        ])
        await supervisor.shutdown()
    }

    @Test
    func markdownQualificationHelperProducesDeterministicBlockFixture() async throws {
        let supervisor = GatewaySupervisor(
            configuration: configuration(mode: "markdown-qualification")
        )
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )

        let events = try await collect(try await gateway.start(request(text: "render")))
        let text = events.compactMap { event -> String? in
            guard case let .textDelta(_, value) = event else { return nil }
            return value
        }.joined()

        #expect(text == """
        # Sample response

        **Bold text** and [a link](https://example.com).

        - First item
        - Second item

        Use `inline code`.

        ```swift
        let value = 1
        ```
        """)
        #expect(events.last == .completed)
        await supervisor.shutdown()
    }

    @Test
    func cancellationAfterDeltaRestartsHungHelperCleanly() async throws {
        let supervisor = GatewaySupervisor(
            configuration: configuration(mode: "hang-on-cancel"),
            cancellationTimeout: .milliseconds(150)
        )
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )
        let firstRequest = request(text: "cancel")
        let stream = try await gateway.start(firstRequest)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted)
        #expect(try await iterator.next() == .textDelta(ordinal: 0, text: "fake: cancel"))

        await gateway.cancel(.init(turnID: firstRequest.turnID, targetGeneration: 1))
        try await eventually {
            let count = await supervisor.restartCount
            let ready = await supervisor.isReady
            return count == 1 && ready
        }
        #expect(await supervisor.restartCount == 1)
        #expect(await supervisor.isReady)
        await supervisor.shutdown()
    }

    @Test
    func wrongSessionMalformedAndOversizedOutputTriggerCleanRestart() async throws {
        for mode in ["wrong-session", "malformed", "oversized"] {
            let supervisor = GatewaySupervisor(
                configuration: configuration(mode: mode),
                readinessTimeout: .seconds(1)
            )
            let gateway = JSONLReasoningGateway(
                supervisor: supervisor,
                selectedProvider: providerProfile
            )
            do {
                _ = try await collect(try await gateway.start(request(text: mode)))
                Issue.record("Expected \(mode) to fail")
            } catch {}
            try await eventually {
                let count = await supervisor.restartCount
                let ready = await supervisor.isReady
                return count == 1 && ready
            }
            await supervisor.shutdown()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedHostileOutputRestartsAndShutdownsStayBounded() async throws {
        for _ in 0..<4 {
            for mode in ["wrong-session", "malformed", "oversized"] {
                let supervisor = GatewaySupervisor(
                    configuration: configuration(mode: mode),
                    readinessTimeout: .seconds(1)
                )
                let gateway = JSONLReasoningGateway(
                    supervisor: supervisor,
                    selectedProvider: providerProfile
                )
                do {
                    _ = try await collect(try await gateway.start(request(text: mode)))
                    Issue.record("Expected \(mode) to fail")
                } catch {}
                try await eventually {
                    let count = await supervisor.restartCount
                    let ready = await supervisor.isReady
                    return count == 1 && ready
                }
                await supervisor.shutdown()
            }
        }
    }

    @Test
    func threeTerminalProcessFailuresOpenRetryCircuit() async throws {
        let supervisor = GatewaySupervisor(
            configuration: configuration(mode: "crash"),
            crashBudget: 3,
            crashWindow: .seconds(300)
        )
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )
        for index in 0..<3 {
            do {
                _ = try await collect(try await gateway.start(request(text: "\(index)")))
            } catch {}
        }
        await #expect(throws: GatewayProtocolError.retryCircuitOpen) {
            _ = try await gateway.start(request(text: "circuit"))
        }
        await supervisor.shutdown()
    }

    @Test
    func lateDeltaIsNeverAdmittedAndRestartsTheHelper() async throws {
        let supervisor = GatewaySupervisor(
            configuration: configuration(mode: "late-delta")
        )
        let gateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: providerProfile
        )
        let events = try await collect(try await gateway.start(request(text: "late")))

        #expect(events == [
            .accepted,
            .textDelta(ordinal: 0, text: "fake: late"),
            .completed,
        ])
        try await eventually {
            let restartCount = await supervisor.restartCount
            let isReady = await supervisor.isReady
            return restartCount == 1 && isReady
        }
        await supervisor.shutdown()
    }

    private func configuration(mode: String) -> GatewayProcess.Configuration {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return GatewayProcess.Configuration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: ["Gateway/src/fake-helper.mjs", mode],
            workingDirectoryURL: repository,
            environment: [
                "LANG": "C",
                "LC_ALL": "C",
                "TMPDIR": repository.appendingPathComponent("Gateway").path,
            ],
            terminationGrace: .milliseconds(100)
        )
    }

    private func providerProfile() -> GatewayProviderProfile {
        GatewayProviderProfile(
            kind: "openai_compatible",
            baseURL: "https://fixture.invalid/v1",
            model: "fixture-model",
            credentialReference: UUID()
        )
    }

    private func productionAuthenticationConfiguration()
        -> GatewayProcess.Configuration
    {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return GatewayProcess.Configuration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [
                "--import", "./Gateway/tests/auth-test-adapter.mjs",
                "./Gateway/src/server.mjs",
            ],
            workingDirectoryURL: repository,
            environment: [
                "LANG": "C",
                "LC_ALL": "C",
                "TMPDIR": repository.appendingPathComponent("Gateway").path,
            ]
        )
    }

    private func request(
        text: String,
        attachment: VoiceHistoryAttachment? = nil
    ) -> ReasoningRequest {
        ReasoningRequest(
            conversationID: ConversationID(),
            turnID: TurnID(),
            generation: 1,
            context: [],
            userText: text,
            voiceHistoryAttachment: attachment
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ReasoningEvent, Error>
    ) async throws -> [ReasoningEvent] {
        var result: [ReasoningEvent] = []
        for try await event in stream {
            result.append(event)
        }
        return result
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Condition did not become true")
    }
}
