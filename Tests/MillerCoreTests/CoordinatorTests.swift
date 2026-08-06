import Foundation
@testable import MillerCore
import Testing

@Suite
struct CoordinatorTests {
    @Test
    func concurrentSubmissionsReserveOnlyOneTurn() async throws {
        let repository = FakeRepository()
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        let conversationID = ConversationID()

        let first = Task {
            try await coordinator.submit(text: "first", conversationID: conversationID)
        }
        let second = Task {
            try await coordinator.submit(text: "second", conversationID: conversationID)
        }
        let results = await [first.result, second.result]

        #expect(results.compactMap(\.success).count == 1)
        #expect(results.compactMap(\.coreError) == [.turnAlreadyActive])
        #expect(await repository.accepted.count == 1)
        try await coordinator.stop()
    }

    @Test
    func durableAcceptancePrecedesGatewayStart() async throws {
        let trace = Trace()
        let repository = FakeRepository(trace: trace)
        let gateway = FakeGateway(trace: trace)
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)

        _ = try await coordinator.submit(text: "hello", conversationID: ConversationID())

        #expect(await trace.values == ["accept", "start"])
        try await coordinator.stop()
    }

    @Test
    func failedAdmissionReleasesReservationAndBlocksFurtherTurns() async {
        let repository = FakeRepository()
        await repository.failAccepts()
        let coordinator = MillerCoordinator(
            repository: repository,
            gateway: FakeGateway()
        )

        await #expect(throws: TestFailure.self) {
            try await coordinator.submit(text: "first", conversationID: ConversationID())
        }
        #expect(await coordinator.activeTurnID == nil)
        await #expect(throws: CoreError.storageUnavailable) {
            try await coordinator.submit(text: "second", conversationID: ConversationID())
        }
    }

    @Test
    func cancellationPersistsFenceBeforeSendingPriorGeneration() async throws {
        let trace = Trace()
        let repository = FakeRepository(trace: trace)
        let gateway = FakeGateway(trace: trace)
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        let turnID = try await coordinator.submit(
            text: "cancel me",
            conversationID: ConversationID()
        )

        try await coordinator.stop()

        #expect(await repository.stops == [
            StopRecord(turnID: turnID, targetGeneration: 1, nextGeneration: 2),
        ])
        #expect(await gateway.cancellations == [
            ReasoningCancellation(turnID: turnID, targetGeneration: 1),
        ])
        #expect(await gateway.cancelledBeforeConsumerTermination)
        #expect(await trace.values.suffix(2) == ["stop", "cancel"])
        #expect(await coordinator.activeTurnID == nil)
    }

    @Test
    func cancellationDuringAdmissionStopsAfterAcceptanceWithoutStartingGateway() async throws {
        let repository = FakeRepository()
        await repository.blockAccepts()
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        let submission = Task {
            try await coordinator.submit(
                text: "cancel during admission",
                conversationID: ConversationID()
            )
        }
        await eventually {
            await repository.acceptStarted
        }

        try await coordinator.stop()
        await repository.releaseAccept()
        let turnID = try await submission.value
        await eventually {
            await coordinator.activeTurnID == nil
        }

        #expect(await repository.stops == [
            StopRecord(turnID: turnID, targetGeneration: 1, nextGeneration: 2),
        ])
        #expect(await gateway.starts.isEmpty)
        #expect(await gateway.cancellations.isEmpty)
    }

    @Test
    func lateEventsAfterCancellationAreIgnored() async throws {
        let repository = FakeRepository()
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        _ = try await coordinator.submit(text: "cancel", conversationID: ConversationID())

        try await coordinator.stop()
        await gateway.yield(.textDelta(ordinal: 0, text: "late"))
        await gateway.yield(.completed)
        await settle()

        #expect(await repository.appends.isEmpty)
        #expect(await repository.completions.isEmpty)
    }

    @Test
    func toolsUnavailableStatusIsActiveOnlyForTheCurrentTurn() async throws {
        let repository = FakeRepository()
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        _ = try await coordinator.submit(text: "continue", conversationID: ConversationID())

        await gateway.yield(.status(.toolsUnavailable))
        await settle()

        #expect(await coordinator.activeReasoningStatus == .toolsUnavailable)
        #expect(await repository.appends.isEmpty)

        await gateway.yield(.textDelta(ordinal: 0, text: "ordinary text"))
        await gateway.yield(.completed)
        await eventually { await coordinator.activeTurnID == nil }

        #expect(await coordinator.activeReasoningStatus == nil)
        #expect(await repository.appends.map(\.text) == ["ordinary text"])
    }

    @Test
    func storageFailureCancelsReasoningAndBlocksNewTurns() async throws {
        let repository = FakeRepository()
        await repository.failAppends()
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        let turnID = try await coordinator.submit(
            text: "stream",
            conversationID: ConversationID()
        )

        await gateway.yield(.textDelta(ordinal: 0, text: "not durable"))
        await eventually {
            await gateway.cancellations.count == 1
        }

        #expect(await gateway.cancellations == [
            ReasoningCancellation(turnID: turnID, targetGeneration: 1),
        ])
        await #expect(throws: CoreError.storageUnavailable) {
            try await coordinator.submit(text: "blocked", conversationID: ConversationID())
        }
    }

    @Test
    func activeConversationCannotBeArchivedOrDeleted() async throws {
        let repository = FakeRepository()
        let coordinator = MillerCoordinator(
            repository: repository,
            gateway: FakeGateway()
        )
        let conversationID = ConversationID()
        _ = try await coordinator.submit(text: "active", conversationID: conversationID)

        await #expect(throws: CoreError.turnAlreadyActive) {
            try await coordinator.archive(conversationID: conversationID)
        }
        await #expect(throws: CoreError.turnAlreadyActive) {
            try await coordinator.delete(conversationID: conversationID)
        }
        #expect(await repository.archives.isEmpty)
        #expect(await repository.deletions.isEmpty)
        try await coordinator.stop()
    }

    @Test
    func seriallyCommitsDeltasAndTerminalBeforeReleasingTurn() async throws {
        let repository = FakeRepository()
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        let turnID = try await coordinator.submit(
            text: "stream",
            conversationID: ConversationID()
        )

        await gateway.yield(.accepted)
        await gateway.yield(.textDelta(ordinal: 0, text: "hello"))
        await gateway.yield(.textDelta(ordinal: 1, text: " world"))
        await gateway.yield(.usage(inputTokens: 1, outputTokens: 2))
        await gateway.yield(.completed)
        await eventually {
            await coordinator.activeTurnID == nil
        }

        #expect(await repository.appends == [
            AppendRecord(turnID: turnID, text: "hello", generation: 1),
            AppendRecord(turnID: turnID, text: " world", generation: 1),
        ])
        #expect(await repository.completions == [
            CompletionRecord(turnID: turnID, generation: 1),
        ])
    }

    @Test
    func contextAndCurrentInputRemainSeparateInReasoningRequest() async throws {
        let repository = FakeRepository()
        let conversationID = ConversationID()
        await repository.setCompletedTurns([
            makeCompletedTurn(
                conversationID: conversationID,
                sequence: 1,
                user: "prior user",
                assistant: "prior assistant"
            ),
        ])
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)

        _ = try await coordinator.submit(text: "current", conversationID: conversationID)

        let request = try #require(await gateway.starts.first)
        #expect(request.context == [
            ReasoningMessage(role: .user, text: "prior user"),
            ReasoningMessage(role: .assistant, text: "prior assistant"),
        ])
        #expect(request.userText == "current")
        try await coordinator.stop()
    }

    @Test
    func explicitVoiceHistoryAttachmentIsForwardedWithoutChangingUserText() async throws {
        let repository = FakeRepository()
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(repository: repository, gateway: gateway)
        let conversationID = ConversationID()
        let attachment = try VoiceHistoryAttachment(text: """
            <miller_voice_history selection="explicit" truncated="false">
            [2026-08-05T12:34:56Z] You: hello
            </miller_voice_history>
            """)

        _ = try await coordinator.submit(
            text: "review this",
            conversationID: conversationID,
            voiceHistoryAttachment: attachment
        )

        let request = try #require(await gateway.starts.first)
        #expect(request.userText == "review this")
        #expect(request.voiceHistoryAttachment == attachment)
        #expect(await repository.acceptedUserTexts == ["review this"])
        try await coordinator.stop()
    }

    @Test
    func ordinarySubmissionDefaultsToNoVoiceHistoryAttachment() async throws {
        let gateway = FakeGateway()
        let coordinator = MillerCoordinator(
            repository: FakeRepository(),
            gateway: gateway
        )

        _ = try await coordinator.submit(
            text: "ordinary",
            conversationID: ConversationID()
        )

        #expect(try #require(await gateway.starts.first).voiceHistoryAttachment == nil)
    }

    @Test
    func capabilityRegistryGatesOnlyRequiredTextCapabilities() async {
        let registry = CapabilityRegistry()
        await registry.update(.init(capability: .durableStorage, status: .ready))
        await registry.update(.init(capability: .reasoningHelper, status: .ready))
        await registry.update(
            .init(capability: .selectedProviderAndAuthentication, status: .ready)
        )
        await registry.update(
            .init(
                capability: .avatarPresentation,
                status: .failed,
                failureCode: "avatar_unavailable"
            )
        )

        #expect(await registry.isTextReady)
        #expect(await registry.readiness(for: .avatarPresentation).status == .failed)

        await registry.update(
            .init(
                capability: .reasoningHelper,
                status: .failed,
                failureCode: "gateway_unavailable"
            )
        )
        #expect(!(await registry.isTextReady))
        #expect(await registry.snapshot.count == MillerCapability.allCases.count)
    }
}

private actor Trace {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct TestFailure: Error {}

private struct AppendRecord: Equatable {
    let turnID: TurnID
    let text: String
    let generation: Int
}

private struct CompletionRecord: Equatable {
    let turnID: TurnID
    let generation: Int
}

private struct StopRecord: Equatable {
    let turnID: TurnID
    let targetGeneration: Int
    let nextGeneration: Int
}

private actor FakeRepository: ConversationRepository {
    private let trace: Trace?
    private var shouldFailAccept = false
    private var shouldFailAppend = false
    private var acceptIsBlocked = false
    private var acceptContinuation: CheckedContinuation<Void, Never>?
    private(set) var acceptStarted = false
    private var storedCompletedTurns: [Turn] = []
    private(set) var accepted: [TurnID] = []
    private(set) var acceptedUserTexts: [String] = []
    private(set) var appends: [AppendRecord] = []
    private(set) var completions: [CompletionRecord] = []
    private(set) var stops: [StopRecord] = []
    private(set) var archives: [ConversationID] = []
    private(set) var deletions: [ConversationID] = []

    init(trace: Trace? = nil) {
        self.trace = trace
    }

    func failAccepts() {
        shouldFailAccept = true
    }

    func failAppends() {
        shouldFailAppend = true
    }

    func blockAccepts() {
        acceptIsBlocked = true
    }

    func releaseAccept() {
        acceptIsBlocked = false
        acceptContinuation?.resume()
        acceptContinuation = nil
    }

    func setCompletedTurns(_ turns: [Turn]) {
        storedCompletedTurns = turns
    }

    func accept(
        conversationID _: ConversationID,
        turnID: TurnID,
        userText: String,
        inputMode _: InputMode,
        generation _: Int
    ) async throws {
        acceptStarted = true
        if acceptIsBlocked {
            await withCheckedContinuation { continuation in
                acceptContinuation = continuation
            }
        }
        if shouldFailAccept {
            throw TestFailure()
        }
        accepted.append(turnID)
        acceptedUserTexts.append(userText)
        await trace?.append("accept")
    }

    func append(turnID: TurnID, text: String, generation: Int) async throws {
        if shouldFailAppend {
            throw TestFailure()
        }
        appends.append(.init(turnID: turnID, text: text, generation: generation))
    }

    func complete(turnID: TurnID, generation: Int) async throws {
        completions.append(.init(turnID: turnID, generation: generation))
    }

    func stop(
        turnID: TurnID,
        targetGeneration: Int,
        nextGeneration: Int
    ) async throws {
        stops.append(
            .init(
                turnID: turnID,
                targetGeneration: targetGeneration,
                nextGeneration: nextGeneration
            )
        )
        await trace?.append("stop")
    }

    func fail(
        turnID _: TurnID,
        code _: String,
        message _: String,
        targetGeneration _: Int,
        nextGeneration _: Int
    ) async throws {}

    func turn(id _: TurnID) async throws -> Turn? {
        nil
    }

    func completedTurns(conversationID _: ConversationID) async throws -> [Turn] {
        storedCompletedTurns
    }

    func archive(conversationID: ConversationID) async throws {
        archives.append(conversationID)
    }

    func unarchive(conversationID _: ConversationID) async throws {}

    func delete(conversationID: ConversationID) async throws {
        deletions.append(conversationID)
    }

    func recoverInterruptedTurns() async throws {}
}

private actor FakeGateway: ReasoningGateway {
    private let trace: Trace?
    private let terminationProbe = ConsumerTerminationProbe()
    private var continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation?
    private(set) var starts: [ReasoningRequest] = []
    private(set) var cancellations: [ReasoningCancellation] = []
    private(set) var cancelledBeforeConsumerTermination = false

    init(trace: Trace? = nil) {
        self.trace = trace
    }

    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        starts.append(request)
        await trace?.append("start")
        let terminationProbe = terminationProbe
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in terminationProbe.markTerminated() }
        }
    }

    func cancel(_ cancellation: ReasoningCancellation) async {
        cancelledBeforeConsumerTermination = !terminationProbe.isTerminated
        cancellations.append(cancellation)
        await trace?.append("cancel")
    }

    func yield(_ event: ReasoningEvent) {
        continuation?.yield(event)
    }
}

private final class ConsumerTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var isTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    func markTerminated() {
        lock.lock(); defer { lock.unlock() }
        terminated = true
    }
}

private func makeCompletedTurn(
    conversationID: ConversationID,
    sequence: Int,
    user: String,
    assistant: String
) -> Turn {
    Turn(
        id: TurnID(),
        conversationID: conversationID,
        sequence: sequence,
        inputMode: .text,
        userText: user,
        assistantText: assistant,
        state: .completed,
        generation: 1,
        errorCode: nil,
        errorMessage: nil,
        startedAt: .distantPast,
        terminalAt: .distantFuture
    )
}

private func settle() async {
    for _ in 0..<50 {
        await Task.yield()
    }
}

private func eventually(
    _ condition: () async -> Bool
) async {
    for _ in 0..<1_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}

private extension Result {
    var success: Success? {
        try? get()
    }

    var coreError: CoreError? {
        guard case let .failure(error) = self else {
            return nil
        }
        return error as? CoreError
    }
}
