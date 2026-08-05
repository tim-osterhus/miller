import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite
struct LiveVoiceTranscriptRecorderTests {
    @Test
    func savingDefaultsOnAndPreservesActivationSource() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        let sessionID = UUID()

        try await recorder.begin(
            sessionID: sessionID,
            conversationID: nil,
            activationSource: .wakeword
        )
        try await recorder.finish(outcome: .completed)

        let session = try #require(await probe.sessions.first)
        #expect(session.id == sessionID)
        #expect(session.activationSource == .wakeword)
        #expect(session.saveChoice == .save)
        #expect(await probe.terminalOutcomes == [.completed])
    }

    @Test
    func nextSessionOptOutIsConsumedAndRestored() async throws {
        let probe = RecorderPersistenceProbe(nextSessionSavingEnabled: false)
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )

        try await recorder.begin(
            sessionID: UUID(),
            conversationID: nil,
            activationSource: .manual
        )
        try await recorder.record(.transcriptDone(role: .user, text: "private"))
        try await recorder.finish(outcome: .completed)
        try await recorder.begin(
            sessionID: UUID(),
            conversationID: nil,
            activationSource: .manual
        )
        try await recorder.record(.transcriptDone(role: .user, text: "saved"))
        try await recorder.finish(outcome: .completed)

        #expect(await probe.sessions.map(\.saveChoice) == [.discard, .save])
        #expect(await probe.entries.map(\.text) == ["saved"])
        #expect(await probe.nextSessionResetCount == 1)
    }

    @Test
    func adjacentSameRoleEntriesRemainChronological() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        try await recorder.begin(
            sessionID: UUID(),
            conversationID: ConversationID(),
            activationSource: .manual
        )

        try await recorder.record(.transcriptDelta(role: .user, text: "first"))
        try await recorder.record(.transcriptDone(role: .user, text: "first"))
        try await recorder.record(.transcriptDelta(role: .user, text: "second"))
        try await recorder.record(.transcriptDone(role: .user, text: "second"))
        try await recorder.finish(outcome: .completed)

        #expect(await probe.entries.map(\.sequence) == [0, 1])
        #expect(await probe.entries.map(\.role) == [.user, .user])
        #expect(await probe.entries.map(\.text) == ["first", "second"])
    }

    @Test
    func deltasAccumulateAndTerminalTextReplacesThePartial() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        try await recorder.begin(
            sessionID: UUID(), conversationID: nil, activationSource: .manual
        )

        try await recorder.record(.transcriptDelta(role: .assistant, text: "Hel"))
        try await recorder.record(.transcriptDelta(role: .assistant, text: "lo"))
        try await recorder.record(.transcriptDone(role: .assistant, text: "Hello!"))
        try await recorder.finish(outcome: .completed)

        let entry = try #require(await probe.entries.first)
        #expect(entry.text == "Hello!")
        #expect(entry.completionState == .complete)
        #expect(await probe.entries.count == 1)
        #expect(await probe.completedEntryCount == 1)
    }

    @Test
    func duplicateTranscriptDoneIsIdempotent() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        try await recorder.begin(
            sessionID: UUID(), conversationID: nil, activationSource: .manual
        )

        try await recorder.record(.transcriptDelta(role: .assistant, text: "answer"))
        try await recorder.record(.transcriptDone(role: .assistant, text: "answer"))
        try await recorder.record(.transcriptDone(role: .assistant, text: "answer"))
        try await recorder.finish(outcome: .completed)

        #expect(await probe.entries.count == 1)
        #expect(await probe.entries.first?.text == "answer")
    }

    @Test(arguments: [VoiceSessionTerminalOutcome.stopped, .failed])
    func terminalCleanupCapturesOnlyNonemptyPartials(
        outcome: VoiceSessionTerminalOutcome
    ) async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        try await recorder.begin(
            sessionID: UUID(), conversationID: nil, activationSource: .manual
        )
        try await recorder.record(.transcriptDelta(role: .user, text: "unfinished "))
        try await recorder.record(.transcriptDelta(role: .user, text: "thought"))
        try await recorder.record(.transcriptDelta(role: .assistant, text: ""))

        try await recorder.finish(outcome: outcome)

        #expect(await probe.entries.count == 1)
        #expect(await probe.entries.first?.text == "unfinished thought")
        #expect(await probe.entries.first?.completionState == .incomplete)
        #expect(await probe.terminalOutcomes == [outcome])
    }

    @Test
    func nonTranscriptEventsPersistNeitherAudioNorRawTransportData() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        try await recorder.begin(
            sessionID: UUID(), conversationID: nil, activationSource: .manual
        )

        try await recorder.record(.state(.connecting))
        try await recorder.record(.state(.speaking))
        try await recorder.record(.failed(code: "provider_failed"))
        try await recorder.finish(outcome: .failed)

        #expect(await probe.entries.isEmpty)
    }

    @Test
    func recorderAdmitsExactlyOneSessionAtATime() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        try await recorder.begin(
            sessionID: UUID(), conversationID: nil, activationSource: .manual
        )

        await #expect(throws: LiveVoiceTranscriptRecorderError.sessionAlreadyActive) {
            try await recorder.begin(
                sessionID: UUID(),
                conversationID: nil,
                activationSource: .wakeword
            )
        }

        try await recorder.finish(outcome: .completed)
        #expect(await probe.sessions.count == 1)
    }

    @Test
    func concurrentBeginsPersistExactlyOneSession() async throws {
        let probe = SuspendedAdmissionProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            try await recorder.begin(
                sessionID: firstID,
                conversationID: nil,
                activationSource: .manual
            )
        }
        await probe.waitUntilFirstStartIsSuspended()

        await #expect(throws: LiveVoiceTranscriptRecorderError.sessionAlreadyActive) {
            try await recorder.begin(
                sessionID: secondID,
                conversationID: nil,
                activationSource: .manual
            )
        }
        await probe.resumeFirstStart()
        try await first.value

        #expect(await probe.persistedSessionIDs == [firstID])
        try await recorder.finish(outcome: .completed)
    }

    @Test
    func failedBeginReleasesAdmissionForRetry() async throws {
        let probe = RecorderPersistenceProbe(startFailures: 1)
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )

        await #expect(throws: RecorderProbeError.startFailed) {
            try await recorder.begin(
                sessionID: UUID(),
                conversationID: nil,
                activationSource: .manual
            )
        }
        let retryID = UUID()
        try await recorder.begin(
            sessionID: retryID,
            conversationID: nil,
            activationSource: .manual
        )
        try await recorder.finish(outcome: .completed)

        #expect(await probe.sessions.map(\.id) == [retryID])
    }

    @Test
    func cancelledBeginReleasesAdmissionForRetry() async throws {
        let probe = CancelledAdmissionProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        let first = Task {
            try await recorder.begin(
                sessionID: UUID(),
                conversationID: nil,
                activationSource: .manual
            )
        }
        await probe.waitUntilFirstReadIsSuspended()

        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        let retryID = UUID()
        try await recorder.begin(
            sessionID: retryID,
            conversationID: nil,
            activationSource: .manual
        )
        try await recorder.finish(outcome: .completed)

        #expect(await probe.persistedSessionIDs == [retryID])
    }

    @Test @MainActor
    func presentationStartsPersistenceOnlyAfterSessionAdmission() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        let model = AppPresentationModel(
            dependencies: inertHostDependencies(),
            liveVoice: .unavailable,
            liveTranscriptRecorder: recorder
        )

        await model.applyLiveEvent(.transcriptDone(role: .user, text: "too early"))
        #expect(await probe.sessions.isEmpty)
        #expect(await probe.entries.isEmpty)

        await model.applyLiveEvent(.sessionAdmitted(id: UUID()))
        await model.applyLiveEvent(.transcriptDone(role: .user, text: "admitted"))
        await model.abandonLiveVoiceSession()

        #expect(await probe.sessions.count == 1)
        #expect(await probe.entries.map(\.text) == ["admitted"])
        #expect(await probe.terminalOutcomes == [.abandoned])
    }

    @Test @MainActor
    func presentationAndDurableTranscriptBoundsRemainIndependent() async throws {
        let probe = RecorderPersistenceProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.persistence()
        )
        let model = AppPresentationModel(
            dependencies: inertHostDependencies(),
            liveVoice: .unavailable,
            liveTranscriptRecorder: recorder
        )
        let first = String(repeating: "a", count: 40_000)
        let second = String(repeating: "b", count: 40_000)

        await model.applyLiveEvent(.sessionAdmitted(id: UUID()))
        await model.applyLiveEvent(.transcriptDone(role: .user, text: first))
        await model.applyLiveEvent(.transcriptDone(role: .assistant, text: second))
        await model.abandonLiveVoiceSession()

        #expect(model.liveTranscriptTurns.map(\.text).reduce(0) {
            $0 + $1.utf8.count
        } == 65_536)
        #expect(await probe.entries.map { $0.text.utf8.count } == [40_000, 40_000])
    }
}

private func inertHostDependencies() -> HostDependencies {
    HostDependencies(
        submit: { _, _ in TurnID() },
        stop: {},
        loadTurn: { _ in nil },
        loadConversations: { [] },
        loadTurns: { _ in [] },
        archive: { _ in },
        unarchive: { _ in },
        delete: { _ in }
    )
}

private actor RecorderPersistenceProbe {
    struct Session: Sendable {
        let id: UUID
        let conversationID: ConversationID?
        let activationSource: VoiceActivationSource
        let saveChoice: VoiceTranscriptSaveChoice
    }

    struct Entry: Sendable {
        let id: UUID
        let sessionID: UUID
        let sequence: Int
        let role: VoiceTranscriptRole
        let text: String
        let completionState: VoiceEntryCompletionState
    }

    private let savingEnabled: Bool
    private var nextSessionSavingEnabled: Bool
    private var remainingStartFailures: Int
    private(set) var sessions: [Session] = []
    private(set) var entries: [Entry] = []
    private(set) var terminalOutcomes: [VoiceSessionTerminalOutcome] = []
    private(set) var nextSessionResetCount = 0
    private(set) var completedEntryCount = 0

    init(
        savingEnabled: Bool = true,
        nextSessionSavingEnabled: Bool = true,
        startFailures: Int = 0
    ) {
        self.savingEnabled = savingEnabled
        self.nextSessionSavingEnabled = nextSessionSavingEnabled
        remainingStartFailures = startFailures
    }

    func persistence() -> LiveVoiceTranscriptRecorder.Persistence {
        LiveVoiceTranscriptRecorder.Persistence(
            savingEnabled: { [self] in await savingIsEnabled() },
            nextSessionSavingEnabled: { [self] in await nextSavingIsEnabled() },
            restoreNextSessionSavingDefault: { [self] in await recordNextReset() },
            startSession: {
                [self] id, conversationID, activationSource, saveChoice in
                try await recordSession(
                    id: id,
                    conversationID: conversationID,
                    activationSource: activationSource,
                    saveChoice: saveChoice
                )
            },
            appendEntry: {
                [self] id, sessionID, sequence, role, text, completionState in
                await recordEntry(
                    id: id,
                    sessionID: sessionID,
                    sequence: sequence,
                    role: role,
                    text: text,
                    completionState: completionState
                )
            },
            completeEntry: { [self] id, text in
                await completeEntry(id: id, text: text)
            },
            finalizeSession: { [self] _, outcome in
                await recordTerminal(outcome)
            },
            recoverInterruptedSessions: {}
        )
    }

    private func savingIsEnabled() -> Bool { savingEnabled }
    private func nextSavingIsEnabled() -> Bool { nextSessionSavingEnabled }
    private func recordNextReset() {
        nextSessionResetCount += 1
        nextSessionSavingEnabled = true
    }

    private func recordSession(
        id: UUID,
        conversationID: ConversationID?,
        activationSource: VoiceActivationSource,
        saveChoice: VoiceTranscriptSaveChoice
    ) throws {
        if remainingStartFailures > 0 {
            remainingStartFailures -= 1
            throw RecorderProbeError.startFailed
        }
        sessions.append(.init(
            id: id,
            conversationID: conversationID,
            activationSource: activationSource,
            saveChoice: saveChoice
        ))
    }

    private func recordEntry(
        id: UUID,
        sessionID: UUID,
        sequence: Int,
        role: VoiceTranscriptRole,
        text: String,
        completionState: VoiceEntryCompletionState
    ) {
        entries.append(.init(
            id: id,
            sessionID: sessionID,
            sequence: sequence,
            role: role,
            text: text,
            completionState: completionState
        ))
    }

    private func completeEntry(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].completionState == .incomplete
        else { return }
        let entry = entries[index]
        entries[index] = .init(
            id: entry.id,
            sessionID: entry.sessionID,
            sequence: entry.sequence,
            role: entry.role,
            text: text,
            completionState: .complete
        )
        completedEntryCount += 1
    }

    private func recordTerminal(_ outcome: VoiceSessionTerminalOutcome) {
        terminalOutcomes.append(outcome)
    }
}

private enum RecorderProbeError: Error {
    case startFailed
}

private actor SuspendedAdmissionProbe {
    private var firstStartContinuation: CheckedContinuation<Void, Never>?
    private var startAttempts = 0
    private(set) var persistedSessionIDs: [UUID] = []

    func persistence() -> LiveVoiceTranscriptRecorder.Persistence {
        .init(
            savingEnabled: { true },
            nextSessionSavingEnabled: { true },
            restoreNextSessionSavingDefault: {},
            startSession: { [self] id, _, _, _ in
                await persistSession(id)
            },
            appendEntry: { _, _, _, _, _, _ in },
            completeEntry: { _, _ in },
            finalizeSession: { _, _ in },
            recoverInterruptedSessions: {}
        )
    }

    func waitUntilFirstStartIsSuspended() async {
        while firstStartContinuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstStart() {
        firstStartContinuation?.resume()
        firstStartContinuation = nil
    }

    private func persistSession(_ id: UUID) async {
        startAttempts += 1
        if startAttempts == 1 {
            await withCheckedContinuation { continuation in
                firstStartContinuation = continuation
            }
        }
        persistedSessionIDs.append(id)
    }
}

private actor CancelledAdmissionProbe {
    private var savingEnabledReads = 0
    private(set) var persistedSessionIDs: [UUID] = []

    func persistence() -> LiveVoiceTranscriptRecorder.Persistence {
        .init(
            savingEnabled: { [self] in try await readSavingEnabled() },
            nextSessionSavingEnabled: { true },
            restoreNextSessionSavingDefault: {},
            startSession: { [self] id, _, _, _ in
                await persistSession(id)
            },
            appendEntry: { _, _, _, _, _, _ in },
            completeEntry: { _, _ in },
            finalizeSession: { _, _ in },
            recoverInterruptedSessions: {}
        )
    }

    func waitUntilFirstReadIsSuspended() async {
        while savingEnabledReads == 0 {
            await Task.yield()
        }
    }

    private func readSavingEnabled() async throws -> Bool {
        savingEnabledReads += 1
        if savingEnabledReads == 1 {
            try await Task.sleep(for: .seconds(60))
        }
        return true
    }

    private func persistSession(_ id: UUID) {
        persistedSessionIDs.append(id)
    }
}
