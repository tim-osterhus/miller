import Foundation
@testable import MillerGateway
import Testing

@Suite(.serialized)
struct GatewayProcessTests {
    @Test
    func fakeHelperCompletesAReasoningTurnAndExitsOnInputEOF() async throws {
        let process = GatewayProcess(configuration: configuration(mode: "normal"))
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        let ready = try #require(try await iterator.next())
        #expect(ready.type == "gateway.ready")

        let requestID = UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        let outbound = try startRecord(
            sessionID: ready.sessionID,
            requestID: requestID,
            turnID: turnID,
            text: "first"
        )
        try process.send(outbound)

        #expect(try await iterator.next()?.type == "reasoning.accepted")
        #expect(try await iterator.next()?.type == "reasoning.text_delta")
        #expect(try await iterator.next()?.type == "reasoning.completed")

        process.closeInput()
        try await process.waitForExit()
        #expect(!process.isRunning)
    }

    @Test
    func stdoutContaminationIsAProtocolFailure() async throws {
        let process = GatewayProcess(
            configuration: configuration(mode: "stdout-contamination")
        )
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next()?.type == "gateway.ready")
        await expectAsyncThrows("stdout prose") {
            _ = try await iterator.next()
        }
        await process.stop()
    }

    @Test
    func stderrLineFloodIsBoundedAndTerminatesTheHelper() async throws {
        let process = GatewayProcess(configuration: configuration(mode: "stderr-flood"))
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next()?.type == "gateway.ready")
        await expectAsyncThrows("stderr line bound") {
            _ = try await iterator.next()
        }
        #expect(process.stderrByteCount <= 65_536)
        await process.stop()
    }

    @Test
    func finalTerminalBeforeEOFIsDeliveredBeforeExit() async throws {
        let process = GatewayProcess(configuration: configuration(mode: "terminal-then-exit"))
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        let ready = try #require(try await iterator.next())
        let requestID = UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        try process.send(try startRecord(
            sessionID: ready.sessionID,
            requestID: requestID,
            turnID: turnID,
            text: "exit"
        ))

        #expect(try await iterator.next()?.type == "reasoning.accepted")
        #expect(try await iterator.next()?.type == "reasoning.text_delta")
        #expect(try await iterator.next()?.type == "reasoning.completed")
        try await process.waitForExit()
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
            terminationGrace: .milliseconds(200)
        )
    }

    private func startRecord(
        sessionID: String,
        requestID: String,
        turnID: String,
        text: String
    ) throws -> GatewayRecord {
        try GatewayRecord.make(
            type: "reasoning.start",
            sessionID: sessionID,
            requestID: requestID,
            fields: [
                "conversation_id": .string(UUID().uuidString.lowercased()),
                "turn_id": .string(turnID),
                "generation": .integer(1),
                "provider_profile": .object([
                    "kind": .string("fake"),
                    "model": .string("fake"),
                    "credential_ref": .string(UUID().uuidString.lowercased()),
                ]),
                "context": .array([]),
                "user_text": .string(text),
                "tools": .array([]),
            ]
        )
    }

    private func expectAsyncThrows(
        _ label: String,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("Expected error: \(label)")
        } catch {}
    }
}
