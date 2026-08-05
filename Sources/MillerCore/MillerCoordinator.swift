public actor MillerCoordinator {
    private enum ActivePhase {
        case admitting
        case running
        case stopping
        case terminalizing
    }

    private struct ActiveTurn {
        let id: TurnID
        let conversationID: ConversationID
        var generation: Int
        var expectedOrdinal: Int
        var phase: ActivePhase
        var consumer: Task<Void, Never>?
    }

    private let repository: any ConversationRepository
    private let gateway: any ReasoningGateway
    private let contextSelector: ContextSelector
    private var active: ActiveTurn?
    private var storageAvailable = true

    public init(
        repository: any ConversationRepository,
        gateway: any ReasoningGateway,
        contextSelector: ContextSelector = ContextSelector()
    ) {
        self.repository = repository
        self.gateway = gateway
        self.contextSelector = contextSelector
    }

    public var activeTurnID: TurnID? {
        active?.id
    }

    @discardableResult
    public func submit(
        text: String,
        conversationID: ConversationID,
        voiceHistoryAttachment: VoiceHistoryAttachment? = nil
    ) async throws -> TurnID {
        guard storageAvailable else {
            throw CoreError.storageUnavailable
        }
        guard active == nil else {
            throw CoreError.turnAlreadyActive
        }

        let turnID = TurnID()
        let generation = 1
        active = ActiveTurn(
            id: turnID,
            conversationID: conversationID,
            generation: generation,
            expectedOrdinal: 0,
            phase: .admitting,
            consumer: nil
        )

        do {
            try contextSelector.validateCurrentInput(text)
        } catch {
            clearReservation(turnID: turnID)
            throw error
        }

        let context: [ReasoningMessage]
        do {
            let turns = try await repository.completedTurns(
                conversationID: conversationID
            )
            context = contextSelector.select(from: turns)
            try await repository.accept(
                conversationID: conversationID,
                turnID: turnID,
                userText: text,
                inputMode: .text,
                generation: generation
            )
        } catch {
            admissionStorageDidFail(turnID: turnID)
            throw error
        }

        if active?.id == turnID, active?.phase == .stopping {
            do {
                try await repository.stop(
                    turnID: turnID,
                    targetGeneration: generation,
                    nextGeneration: generation + 1
                )
            } catch {
                admissionStorageDidFail(turnID: turnID)
                throw error
            }
            if active?.id == turnID, active?.phase == .stopping {
                active = nil
            }
            return turnID
        }
        guard active?.id == turnID, active?.phase == .admitting else {
            return turnID
        }
        active?.phase = .running

        let request = ReasoningRequest(
            conversationID: conversationID,
            turnID: turnID,
            generation: generation,
            context: context,
            userText: text,
            voiceHistoryAttachment: voiceHistoryAttachment
        )
        let events: AsyncThrowingStream<ReasoningEvent, Error>
        do {
            events = try await gateway.start(request)
        } catch {
            try await failAcceptedTurn(
                turnID: turnID,
                generation: generation,
                code: "gateway_unavailable"
            )
            throw error
        }

        guard isRunning(turnID: turnID, generation: generation) else {
            return turnID
        }

        let consumer = Task { [weak self] in
            guard let self else {
                return
            }
            await self.consume(
                events,
                turnID: turnID,
                generation: generation
            )
        }
        if isRunning(turnID: turnID, generation: generation) {
            active?.consumer = consumer
        } else {
            consumer.cancel()
        }
        return turnID
    }

    public func stop() async throws {
        guard var turn = active else {
            return
        }

        if turn.phase == .admitting {
            turn.generation += 1
            turn.phase = .stopping
            active = turn
            return
        }
        guard turn.phase == .running else {
            return
        }

        let targetGeneration = turn.generation
        let nextGeneration = targetGeneration + 1
        turn.generation = nextGeneration
        turn.phase = .stopping
        active = turn

        do {
            try await repository.stop(
                turnID: turn.id,
                targetGeneration: targetGeneration,
                nextGeneration: nextGeneration
            )
        } catch {
            await storageDidFail(
                turnID: turn.id,
                generation: targetGeneration
            )
            throw error
        }

        if active?.id == turn.id, active?.phase == .stopping {
            active = nil
        }
        turn.consumer?.cancel()
        await gateway.cancel(
            ReasoningCancellation(
                turnID: turn.id,
                targetGeneration: targetGeneration
            )
        )
    }

    public func archive(conversationID: ConversationID) async throws {
        try refuseLifecycleChangeWhenActive(conversationID)
        do {
            try await repository.archive(conversationID: conversationID)
        } catch {
            storageAvailable = false
            throw error
        }
    }

    public func unarchive(conversationID: ConversationID) async throws {
        do {
            try await repository.unarchive(conversationID: conversationID)
        } catch {
            storageAvailable = false
            throw error
        }
    }

    public func delete(conversationID: ConversationID) async throws {
        try refuseLifecycleChangeWhenActive(conversationID)
        do {
            try await repository.delete(conversationID: conversationID)
        } catch {
            storageAvailable = false
            throw error
        }
    }

    private func consume(
        _ events: AsyncThrowingStream<ReasoningEvent, Error>,
        turnID: TurnID,
        generation: Int
    ) async {
        do {
            for try await event in events {
                await receive(
                    event,
                    turnID: turnID,
                    generation: generation
                )
            }
        } catch {
            await terminalFailure(
                turnID: turnID,
                generation: generation,
                code: "gateway_unavailable"
            )
            return
        }

        await terminalFailure(
            turnID: turnID,
            generation: generation,
            code: "gateway_unavailable"
        )
    }

    private func receive(
        _ event: ReasoningEvent,
        turnID: TurnID,
        generation: Int
    ) async {
        guard isRunning(turnID: turnID, generation: generation) else {
            return
        }

        switch event {
        case .accepted, .usage, .capabilityLifecycle,
             .capabilityApprovalRequested:
            return

        case let .textDelta(ordinal, text):
            guard ordinal == active?.expectedOrdinal else {
                await terminalFailure(
                    turnID: turnID,
                    generation: generation,
                    code: "failed"
                )
                return
            }
            do {
                try await repository.append(
                    turnID: turnID,
                    text: text,
                    generation: generation
                )
            } catch {
                await storageDidFail(
                    turnID: turnID,
                    generation: generation
                )
                return
            }
            if isRunning(turnID: turnID, generation: generation) {
                active?.expectedOrdinal += 1
            }

        case .completed:
            await complete(turnID: turnID, generation: generation)

        case .stopped:
            await terminalStop(turnID: turnID, generation: generation)

        case let .failed(code, _):
            await terminalFailure(
                turnID: turnID,
                generation: generation,
                code: code
            )
        }
    }

    private func complete(turnID: TurnID, generation: Int) async {
        guard beginTerminalCommit(turnID: turnID, generation: generation) else {
            return
        }
        do {
            try await repository.complete(
                turnID: turnID,
                generation: generation
            )
        } catch {
            await storageDidFail(turnID: turnID, generation: generation)
            return
        }
        clearAfterTerminalCommit(turnID: turnID)
    }

    private func terminalStop(turnID: TurnID, generation: Int) async {
        guard beginTerminalCommit(turnID: turnID, generation: generation) else {
            return
        }
        do {
            try await repository.stop(
                turnID: turnID,
                targetGeneration: generation,
                nextGeneration: generation + 1
            )
        } catch {
            await storageDidFail(turnID: turnID, generation: generation)
            return
        }
        clearAfterTerminalCommit(turnID: turnID)
    }

    private func terminalFailure(
        turnID: TurnID,
        generation: Int,
        code: String
    ) async {
        guard beginTerminalCommit(turnID: turnID, generation: generation) else {
            return
        }
        do {
            try await repository.fail(
                turnID: turnID,
                code: code,
                message: MillerFailure(code: code).message,
                targetGeneration: generation,
                nextGeneration: generation + 1
            )
        } catch {
            await storageDidFail(turnID: turnID, generation: generation)
            return
        }
        clearAfterTerminalCommit(turnID: turnID)
    }

    private func failAcceptedTurn(
        turnID: TurnID,
        generation: Int,
        code: String
    ) async throws {
        guard beginTerminalCommit(turnID: turnID, generation: generation) else {
            return
        }
        do {
            try await repository.fail(
                turnID: turnID,
                code: code,
                message: MillerFailure(code: code).message,
                targetGeneration: generation,
                nextGeneration: generation + 1
            )
        } catch {
            await storageDidFail(turnID: turnID, generation: generation)
            throw error
        }
        clearAfterTerminalCommit(turnID: turnID)
    }

    private func beginTerminalCommit(
        turnID: TurnID,
        generation: Int
    ) -> Bool {
        guard isRunning(turnID: turnID, generation: generation) else {
            return false
        }
        active?.phase = .terminalizing
        return true
    }

    private func clearAfterTerminalCommit(turnID: TurnID) {
        guard active?.id == turnID, active?.phase == .terminalizing else {
            return
        }
        active = nil
    }

    private func storageDidFail(
        turnID: TurnID,
        generation: Int
    ) async {
        storageAvailable = false
        let consumer = active?.id == turnID ? active?.consumer : nil
        if active?.id == turnID {
            active = nil
        }
        consumer?.cancel()
        await gateway.cancel(
            ReasoningCancellation(
                turnID: turnID,
                targetGeneration: generation
            )
        )
    }

    private func clearReservation(turnID: TurnID) {
        if active?.id == turnID {
            active = nil
        }
    }

    private func admissionStorageDidFail(turnID: TurnID) {
        storageAvailable = false
        clearReservation(turnID: turnID)
    }

    private func isRunning(
        turnID: TurnID,
        generation: Int
    ) -> Bool {
        active?.id == turnID
            && active?.generation == generation
            && active?.phase == .running
    }

    private func refuseLifecycleChangeWhenActive(
        _ conversationID: ConversationID
    ) throws {
        guard active?.conversationID != conversationID else {
            throw CoreError.turnAlreadyActive
        }
    }
}
