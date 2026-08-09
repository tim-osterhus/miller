import Foundation
import Testing

@testable import MillerLive

@Suite(.serialized)
struct CodexLiveTextCompatibilityTests {
    private let threadID = "synthetic-thread"

    @Test
    func appendTextUsesTheExactBoundedRequestAndEmptyAcknowledgementShape() throws {
        let request = try LiveTextCompatibilityFrame.appendTextRequest(
            id: "probe:append:accepted",
            threadID: threadID,
            text: "synthetic-input",
            role: "user"
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        #expect(root.keys.sorted() == ["id", "method", "params"])
        #expect(root["id"] as? String == "probe:append:accepted")
        #expect(root["method"] as? String == "thread/realtime/appendText")
        let params = try #require(root["params"] as? [String: Any])
        #expect(params.keys.sorted() == ["role", "text", "threadId"])
        #expect(params["threadId"] as? String == threadID)
        #expect(params["text"] as? String == "synthetic-input")
        #expect(params["role"] as? String == "user")

        #expect(try LiveTextCompatibilityFrame.decodeAcknowledgement(Data(
            #"{"id":"probe:append:accepted","result":{}}"#.utf8
        )) == .success(id: "probe:append:accepted"))
    }

    @Test
    func v3InitialItemsUseRoleAndTextItemsWithoutProductionSeeding() throws {
        let request = try LiveTextCompatibilityFrame.realtimeStartRequest(
            id: "probe:start",
            threadID: threadID,
            initialItems: [
                .init(role: "user", text: "synthetic-history"),
                .init(role: "assistant", text: "synthetic-answer"),
            ]
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        #expect(root.keys.sorted() == ["id", "method", "params"])
        #expect(root["method"] as? String == "thread/realtime/start")
        let params = try #require(root["params"] as? [String: Any])
        #expect(params.keys.sorted() == [
            "initialItems", "outputModality", "prompt", "realtimeSessionId",
            "threadId", "transport", "version", "voice",
        ])
        #expect(params["version"] as? String == "v3")
        #expect(params["outputModality"] as? String == "audio")
        #expect(params["prompt"] as? String == "synthetic-prompt")
        #expect(params["realtimeSessionId"] is NSNull)
        #expect(params["voice"] is NSNull)
        let transport = try #require(params["transport"] as? [String: Any])
        #expect(transport.keys.sorted() == ["type"])
        #expect(transport["type"] as? String == "websocket")
        let initialItems = try #require(params["initialItems"] as? [[String: Any]])
        #expect(initialItems.count == 2)
        #expect(initialItems.allSatisfy { $0.keys.sorted() == ["role", "text"] })
        #expect(initialItems[0]["role"] as? String == "user")
        #expect(initialItems[1]["role"] as? String == "assistant")
    }

    @Test
    func boundedFixturesClassifyAcceptedRejectedMalformedOversizedLateCancelledAndDuplicateFrames()
        throws
    {
        var ledger = LiveTextCompatibilityLedger()
        #expect(ledger.register("accepted") == .registered)
        #expect(ledger.observe(.success(id: "accepted")) == .accepted)

        #expect(ledger.register("rejected") == .registered)
        #expect(ledger.observe(.failure(id: "rejected", code: -32602)) == .rejected(code: -32602))

        #expect(throws: LiveTextCompatibilityFrameError.malformed) {
            try LiveTextCompatibilityFrame.decodeAcknowledgement(Data("{".utf8))
        }
        #expect(throws: LiveTextCompatibilityFrameError.payloadTooLarge) {
            try LiveTextCompatibilityFrame.appendTextRequest(
                id: "oversized",
                threadID: threadID,
                text: String(repeating: "x", count: LiveTextCompatibilityFrame.maximumTextBytes + 1),
                role: "user"
            )
        }

        #expect(ledger.register("late") == .registered)
        ledger.expire("late")
        #expect(ledger.observe(.success(id: "late")) == .late)

        #expect(ledger.register("cancelled") == .registered)
        ledger.cancel("cancelled")
        #expect(ledger.observe(.success(id: "cancelled")) == .cancelled)

        #expect(ledger.observe(.success(id: "accepted")) == .duplicate)
    }

    @Test
    func dynamicThreadStartIDsAreCapturedAndRejectedOutsideTheBoundedUUIDShape() throws {
        let dynamicThreadID = "00000000-0000-4000-8000-000000000001"
        #expect(try LiveTextCompatibilityHarness.dynamicThreadID(from: .threadStartResponse(
            id: "probe:thread-start",
            threadID: dynamicThreadID
        )) == dynamicThreadID)
        #expect(throws: LiveTextCompatibilityFrameError.invalid) {
            try LiveTextCompatibilityHarness.dynamicThreadID(from: .emptyResponse(
                id: "probe:thread-start"
            ))
        }
        #expect(throws: LiveTextCompatibilityFrameError.invalid) {
            try LiveTextCompatibilityHarness.dynamicThreadID(from: .threadStartResponse(
                id: "probe:thread-start",
                threadID: "not-a-uuid"
            ))
        }
        #expect(throws: LiveTextCompatibilityFrameError.payloadTooLarge) {
            try LiveTextCompatibilityHarness.dynamicThreadID(from: .threadStartResponse(
                id: "probe:thread-start",
                threadID: String(repeating: "0", count: LiveTextCompatibilityHarness.maximumThreadIDBytes + 1)
            ))
        }
    }

    @Test
    func boundedProbeCapturesAndFencesTheDynamicThreadIDReturnedByTheFixture() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = Bundle.module.url(
            forResource: "fake-codex-app-server",
            withExtension: "mjs",
            subdirectory: "Fixtures"
        )!

        let result = try await LiveTextCompatibilityHarness.probe(
            scenario: .accepted,
            fixture: fixture,
            temporaryParent: repository.appendingPathComponent(".artifacts")
        )
        #expect(result.outcome == .accepted)
        #expect(result.observations == [
            .startAcknowledged, .realtimeStarted, .assistantOutputActive,
            .appendPending, .appendAcknowledged, .echo, .stopAcknowledged, .closed,
        ])
        #expect(result.temporaryRootWasRemoved)
        #expect(result.childWasStopped)
    }

    @Test
    func boundedProcessProbeCoversEveryStrictFixtureAndCleansItsPrivateRoot() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = Bundle.module.url(
            forResource: "fake-codex-app-server",
            withExtension: "mjs",
            subdirectory: "Fixtures"
        )!

        for scenario in LiveTextCompatibilityScenario.allCases {
            let result = try await LiveTextCompatibilityHarness.probe(
                scenario: scenario,
                fixture: fixture,
                temporaryParent: repository.appendingPathComponent(".artifacts")
            )
            #expect(result.scenario == scenario)
            switch scenario {
            case .accepted, .duplicate:
                #expect(result.outcome == .accepted)
            case .rejected, .malformed, .oversized:
                #expect(result.outcome == .rejected(code: -32602))
            case .late:
                #expect(result.outcome == .late)
            case .cancelled:
                #expect(result.outcome == .cancelled)
            }
            switch scenario {
            case .accepted:
                #expect(result.observations == [
                    .startAcknowledged, .realtimeStarted, .assistantOutputActive,
                    .appendPending, .appendAcknowledged, .echo, .stopAcknowledged, .closed,
                ])
            case .rejected, .malformed, .oversized:
                #expect(result.observations == [
                    .startAcknowledged, .realtimeStarted, .assistantOutputActive,
                    .appendPending, .appendRejected, .stopAcknowledged, .closed,
                ])
            case .late:
                #expect(result.observations == [
                    .startAcknowledged, .realtimeStarted, .assistantOutputActive,
                    .appendPending, .appendLate, .stopAcknowledged, .closed,
                ])
            case .cancelled:
                #expect(result.observations == [
                    .startAcknowledged, .realtimeStarted, .assistantOutputActive,
                    .appendPending, .appendCancelled, .stopAcknowledged, .closed,
                ])
            case .duplicate:
                #expect(result.observations == [
                    .startAcknowledged, .realtimeStarted, .assistantOutputActive,
                    .appendPending, .appendAcknowledged, .duplicateFrame,
                    .stopAcknowledged, .closed,
                ])
            }
            #expect(result.temporaryRootWasRemoved)
            #expect(result.childWasStopped)
        }
    }

    @Test
    func productionSourcesHaveNoEnabledLiveTextComposerOutboxInitialItemsOrMigration() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey]
        )!
        var contents = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            contents += try String(contentsOf: url, encoding: .utf8)
        }

        for forbidden in [
            "appendText", "initialItems", "initial_items", "LiveComposer", "LiveOutbox",
            "live_text", "live_composer", "initial_item",
        ] {
            #expect(!contents.contains(forbidden), "Production source enabled forbidden term: \(forbidden)")
        }
    }

    @Test
    func installedSignedCodexProbeIsVersionBoundedAndLeavesNoPrivateRoot() async throws {
        guard let path = ProcessInfo.processInfo.environment["MILLER_LIVE_TEXT_SPIKE_CODEX"] else {
            return
        }
        let executable = URL(fileURLWithPath: path)
        #expect(
            try LiveTextCompatibilityHarness.installedVersion(executableURL: executable)
                == "codex-cli 0.147.0"
        )
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let result = try await LiveTextCompatibilityHarness.probeInstalledRuntime(
            executableURL: executable,
            temporaryParent: repository.appendingPathComponent(".artifacts")
        )
        #expect(result.stage == .realtimeStartErrored)
        #expect(result.temporaryRootWasRemoved)
        #expect(result.childWasStopped)
    }
}
