import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite
@MainActor
struct VoiceHistoryPresentationTests {
    @Test
    func ordinaryTypedRequestContainsNoSavedVoiceHistory() async {
        let submits = VoiceHistorySubmitProbe()
        let model = AppPresentationModel(
            dependencies: hostDependencies(submits: submits)
        )
        model.draft = "ordinary request"

        await model.submit()

        let calls = await submits.calls
        #expect(calls.count == 1)
        #expect(calls.first?.text == "ordinary request")
        #expect(calls.first?.attachment == nil)
    }

    @Test
    func explicitSelectionAttachesToExactlyOneRequestThenClears() async throws {
        let sessionID = UUID()
        let history = VoiceHistoryProjectionProbe(
            sessions: [historySession(id: sessionID)],
            projections: [historyExport(id: sessionID)]
        )
        let submits = VoiceHistorySubmitProbe()
        let voiceDependencies = await history.dependencies()
        let model = AppPresentationModel(
            dependencies: hostDependencies(submits: submits),
            voiceHistory: voiceDependencies
        )

        await model.prepareVoiceHistoryAttachment(sessionIDs: [sessionID])
        #expect(model.pendingVoiceHistoryAttachment?.truncated == false)
        model.draft = "review this"
        await model.submit()
        await model.stop()
        model.draft = "ordinary follow-up"
        await model.submit()

        let calls = await submits.calls
        #expect(calls.count == 2)
        #expect(calls[0].attachment?.text.contains("review me") == true)
        #expect(calls[1].attachment == nil)
        #expect(model.pendingVoiceHistoryAttachment == nil)
    }

    @Test
    func explicitDateRangeSelectsOnlyChronologicalSessionsInsideTheRange() async {
        let earlier = UUID()
        let inside = UUID()
        let later = UUID()
        let history = VoiceHistoryProjectionProbe(
            sessions: [
                historySession(id: later, startedAt: Date(timeIntervalSince1970: 30)),
                historySession(id: inside, startedAt: Date(timeIntervalSince1970: 20)),
                historySession(id: earlier, startedAt: Date(timeIntervalSince1970: 10)),
            ],
            projections: [
                historyExport(id: later, text: "later", startedAt: Date(timeIntervalSince1970: 30)),
                historyExport(id: inside, text: "inside", startedAt: Date(timeIntervalSince1970: 20)),
                historyExport(id: earlier, text: "earlier", startedAt: Date(timeIntervalSince1970: 10)),
            ]
        )
        let voiceDependencies = await history.dependencies()
        let model = AppPresentationModel(
            dependencies: hostDependencies(submits: VoiceHistorySubmitProbe()),
            voiceHistory: voiceDependencies
        )

        await model.prepareVoiceHistoryAttachment(
            from: Date(timeIntervalSince1970: 15),
            through: Date(timeIntervalSince1970: 25)
        )

        #expect(model.pendingVoiceHistoryAttachment?.sessionIDs == [inside])
        #expect(model.pendingVoiceHistoryAttachment?.attachment.text.contains("inside") == true)
        #expect(model.pendingVoiceHistoryAttachment?.attachment.text.contains("earlier") == false)
        #expect(model.pendingVoiceHistoryAttachment?.attachment.text.contains("later") == false)
    }

    @Test
    func deletionBetweenSelectionAndSubmitPreventsAttachmentAndSubmission() async {
        let sessionID = UUID()
        let history = VoiceHistoryProjectionProbe(
            sessions: [historySession(id: sessionID)],
            projections: [historyExport(id: sessionID)]
        )
        let submits = VoiceHistorySubmitProbe()
        let voiceDependencies = await history.dependencies()
        let model = AppPresentationModel(
            dependencies: hostDependencies(submits: submits),
            voiceHistory: voiceDependencies
        )

        await model.prepareVoiceHistoryAttachment(sessionIDs: [sessionID])
        await history.removeAll()
        model.draft = "review deleted history"
        await model.submit()

        #expect(await submits.calls.isEmpty)
        #expect(model.pendingVoiceHistoryAttachment == nil)
        #expect(model.voiceHistoryStatus == "Selected voice history is no longer available.")
    }

    @Test
    func cancelClearsPendingAttachmentWithoutSubmitting() async {
        let sessionID = UUID()
        let history = VoiceHistoryProjectionProbe(
            sessions: [historySession(id: sessionID)],
            projections: [historyExport(id: sessionID)]
        )
        let submits = VoiceHistorySubmitProbe()
        let voiceDependencies = await history.dependencies()
        let model = AppPresentationModel(
            dependencies: hostDependencies(submits: submits),
            voiceHistory: voiceDependencies
        )

        await model.prepareVoiceHistoryAttachment(sessionIDs: [sessionID])
        model.cancelVoiceHistoryAttachment()

        #expect(model.pendingVoiceHistoryAttachment == nil)
        #expect(await submits.calls.isEmpty)
    }

    @Test
    func truncationDisclosureClearsWithTheOneShotAttachment() async {
        let sessionID = UUID()
        let history = VoiceHistoryProjectionProbe(
            sessions: [historySession(id: sessionID)],
            projections: [
                historyExport(
                    id: sessionID,
                    text: String(repeating: "large transcript ", count: 4_000)
                ),
            ]
        )
        let voiceDependencies = await history.dependencies()
        let model = AppPresentationModel(
            dependencies: hostDependencies(submits: VoiceHistorySubmitProbe()),
            voiceHistory: voiceDependencies
        )

        await model.prepareVoiceHistoryAttachment(sessionIDs: [sessionID])
        #expect(model.pendingVoiceHistoryAttachment?.truncated == true)
        #expect(model.voiceHistoryStatus == "Selection was truncated to 32 KiB.")
        model.draft = "review"
        await model.submit()

        #expect(model.pendingVoiceHistoryAttachment == nil)
        #expect(model.voiceHistoryStatus == nil)
    }

    @Test
    func destructiveHistoryActionsFlowThroughExplicitDependencies() async {
        let first = UUID()
        let second = UUID()
        let history = VoiceHistoryProjectionProbe(
            sessions: [historySession(id: first), historySession(id: second)],
            projections: [historyExport(id: first), historyExport(id: second)]
        )
        let voiceDependencies = await history.dependencies()
        let model = AppPresentationModel(
            dependencies: hostDependencies(submits: VoiceHistorySubmitProbe()),
            voiceHistory: voiceDependencies
        )

        await model.deleteVoiceHistorySession(first)
        await model.deleteVoiceHistory(from: Date(timeIntervalSince1970: 0), through: Date())
        await model.deleteAllVoiceHistory()

        #expect(await history.deletedSessionIDs == [first])
        #expect(await history.deletedRanges.count == 1)
        #expect(await history.deleteAllCount == 1)
    }

    private func hostDependencies(
        submits: VoiceHistorySubmitProbe
    ) -> HostDependencies {
        HostDependencies(
            submit: { text, conversationID, attachment in
                await submits.record(
                    text: text,
                    conversationID: conversationID,
                    attachment: attachment
                )
                return TurnID()
            },
            stop: {},
            loadTurn: { _ in nil },
            loadConversations: { [] },
            loadTurns: { _ in [] },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    private func historySession(
        id: UUID,
        startedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> VoiceHistorySession {
        VoiceHistorySession(
            id: id,
            conversationID: nil,
            activationSource: .manual,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1),
            terminalOutcome: .completed,
            saveChoice: .save
        )
    }

    private func historyExport(
        id: UUID,
        text: String = "review me",
        startedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> VoiceHistoryExportSession {
        VoiceHistoryExportSession(
            session: historySession(id: id, startedAt: startedAt),
            entries: [
                VoiceHistoryEntry(
                    id: UUID(),
                    sessionID: id,
                    sequence: 0,
                    role: .user,
                    text: text,
                    completionState: .complete,
                    startedAt: startedAt,
                    completedAt: startedAt
                ),
            ]
        )
    }
}

private actor VoiceHistorySubmitProbe {
    struct Call: Sendable {
        let text: String
        let conversationID: ConversationID
        let attachment: VoiceHistoryAttachment?
    }

    private(set) var calls: [Call] = []

    func record(
        text: String,
        conversationID: ConversationID,
        attachment: VoiceHistoryAttachment?
    ) {
        calls.append(.init(
            text: text,
            conversationID: conversationID,
            attachment: attachment
        ))
    }
}

private actor VoiceHistoryProjectionProbe {
    private var sessions: [VoiceHistorySession]
    private var projections: [VoiceHistoryExportSession]
    private(set) var deletedSessionIDs: [UUID] = []
    private(set) var deletedRanges: [(Date, Date)] = []
    private(set) var deleteAllCount = 0

    init(
        sessions: [VoiceHistorySession],
        projections: [VoiceHistoryExportSession]
    ) {
        self.sessions = sessions
        self.projections = projections
    }

    func dependencies() -> VoiceHistoryDependencies {
        VoiceHistoryDependencies(
            sessions: { [self] start, end in
                await selectedSessions(from: start, through: end)
            },
            exportProjection: { [self] ids in await selected(ids: ids) },
            deleteSession: { [self] id in await delete(id: id) },
            deleteRange: { [self] start, end in await delete(from: start, through: end) },
            deleteAll: { [self] in await deleteEverything() }
        )
    }

    func removeAll() {
        sessions = []
        projections = []
    }

    private func selectedSessions(from start: Date?, through end: Date?) -> [VoiceHistorySession] {
        sessions.filter {
            (start == nil || $0.startedAt >= start!)
                && (end == nil || $0.startedAt <= end!)
        }
    }

    private func selected(ids: [UUID]) -> [VoiceHistoryExportSession] {
        let requested = Set(ids)
        return projections.filter { requested.contains($0.session.id) }
    }

    private func delete(id: UUID) {
        deletedSessionIDs.append(id)
        sessions.removeAll { $0.id == id }
        projections.removeAll { $0.session.id == id }
    }

    private func delete(from start: Date, through end: Date) {
        deletedRanges.append((start, end))
    }

    private func deleteEverything() {
        deleteAllCount += 1
        sessions = []
        projections = []
    }
}
