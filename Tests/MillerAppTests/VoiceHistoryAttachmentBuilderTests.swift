import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite
struct VoiceHistoryAttachmentBuilderTests {
    @Test
    func explicitSelectionIsChronologicalRoleLabeledAndXMLEscaped() throws {
        let laterID = UUID()
        let earlierID = UUID()
        let selection = [
            exportSession(
                id: laterID,
                startedAt: instant("2026-08-05T12:34:57Z"),
                entries: [
                    entry(
                        sessionID: laterID,
                        sequence: 0,
                        role: .assistant,
                        text: "Use <safe> & \"clear\" output.",
                        at: instant("2026-08-05T12:34:58Z")
                    ),
                ]
            ),
            exportSession(
                id: earlierID,
                startedAt: instant("2026-08-05T12:34:55Z"),
                entries: [
                    entry(
                        sessionID: earlierID,
                        sequence: 0,
                        role: .user,
                        text: "Hello > Miller",
                        at: instant("2026-08-05T12:34:56Z")
                    ),
                ]
            ),
        ]

        let result = try VoiceHistoryAttachmentBuilder().build(from: selection)

        #expect(!result.truncated)
        #expect(result.attachment.text == """
            <miller_voice_history selection="explicit" truncated="false">
            [2026-08-05T12:34:56Z] You: Hello &gt; Miller
            [2026-08-05T12:34:58Z] Miller: Use &lt;safe&gt; &amp; &quot;clear&quot; output.
            </miller_voice_history>
            """)
    }

    @Test
    func attachmentIsBoundedByUTF8BytesAndDisclosesTruncation() throws {
        let sessionID = UUID()
        let selection = [
            exportSession(
                id: sessionID,
                startedAt: instant("2026-08-05T12:34:55Z"),
                entries: [
                    entry(
                        sessionID: sessionID,
                        sequence: 0,
                        role: .user,
                        text: String(repeating: "🙂", count: 12_000),
                        at: instant("2026-08-05T12:34:56Z")
                    ),
                ]
            ),
        ]

        let result = try VoiceHistoryAttachmentBuilder().build(from: selection)

        #expect(result.truncated)
        #expect(result.attachment.text.utf8.count <= 32 * 1_024)
        #expect(result.attachment.text.contains("truncated=\"true\""))
        #expect(result.attachment.text.hasSuffix("</miller_voice_history>"))
        #expect(String(data: Data(result.attachment.text.utf8), encoding: .utf8) != nil)
    }

    @Test
    func exportContainsOnlySessionMetadataAndChronologicalTranscriptEntries() throws {
        let sessionID = UUID()
        let projection = [
            exportSession(
                id: sessionID,
                startedAt: instant("2026-08-05T12:34:55Z"),
                entries: [
                    entry(
                        sessionID: sessionID,
                        sequence: 1,
                        role: .assistant,
                        text: "answer",
                        at: instant("2026-08-05T12:34:58Z")
                    ),
                    entry(
                        sessionID: sessionID,
                        sequence: 0,
                        role: .user,
                        text: "question",
                        at: instant("2026-08-05T12:34:56Z")
                    ),
                ]
            ),
        ]

        let data = try VoiceHistoryExportDocument.encode(projection)
        let text = try #require(String(data: data, encoding: .utf8))
        let question = try #require(text.range(of: "question"))
        let answer = try #require(text.range(of: "answer"))

        #expect(question.lowerBound < answer.lowerBound)
        #expect(!text.localizedCaseInsensitiveContains("credential"))
        #expect(!text.localizedCaseInsensitiveContains("audit"))
        #expect(!text.localizedCaseInsensitiveContains("providerPayload"))
        #expect(!text.localizedCaseInsensitiveContains("audio"))
    }

    @Test
    func exportIsWrittenAtomicallyWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voice-history.json")
        let sessionID = UUID()
        let projection = [
            exportSession(
                id: sessionID,
                startedAt: instant("2026-08-05T12:34:55Z"),
                entries: [
                    entry(
                        sessionID: sessionID,
                        sequence: 0,
                        role: .user,
                        text: "owner-visible transcript",
                        at: instant("2026-08-05T12:34:56Z")
                    ),
                ]
            ),
        ]

        try VoiceHistoryExportDocument.write(projection, to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("owner-visible transcript"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["voice-history.json"])
    }

    private func exportSession(
        id: UUID,
        startedAt: Date,
        entries: [VoiceHistoryEntry]
    ) -> VoiceHistoryExportSession {
        VoiceHistoryExportSession(
            session: VoiceHistorySession(
                id: id,
                conversationID: nil,
                activationSource: .manual,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(10),
                terminalOutcome: .completed,
                saveChoice: .save
            ),
            entries: entries
        )
    }

    private func entry(
        sessionID: UUID,
        sequence: Int,
        role: VoiceTranscriptRole,
        text: String,
        at: Date
    ) -> VoiceHistoryEntry {
        VoiceHistoryEntry(
            id: UUID(),
            sessionID: sessionID,
            sequence: sequence,
            role: role,
            text: text,
            completionState: .complete,
            startedAt: at,
            completedAt: at
        )
    }

    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
