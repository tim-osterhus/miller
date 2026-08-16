import Foundation
import MillerCore
import MillerLiveAudio
import MillerRemoteBridge
import MillerStorage
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct RemoteLiveCompositionTests {
    @Test
    func stopBeforeProviderAnswerReleasesOldWaiterBeforeRestart() async throws {
        let peerProbe = RemoteCompositionPeerProbe()
        let responseProbe = RemoteCompositionResponseProbe()
        let startProbe = RemoteCompositionStartProbe()
        let completedStartGate = RemoteCompositionGate()
        let model = makeModel(
            startRemote: { peer, receive in
                await peerProbe.record(peer)
                _ = try await peer.prepareOffer()
                if await startProbe.nextStart() == 1 {
                    try await Task.sleep(for: .seconds(3_600))
                } else {
                    try await peer.applyAnswerAndWaitForConnected("v=0")
                    await receive(.sessionAdmitted(id: UUID()))
                    await receive(.state(.listening))
                    await completedStartGate.wait()
                }
            }
        )
        let root = URL(fileURLWithPath: "/tmp/mr-stop-before-answer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        try await adapter.start()
        let connectionID = UUID()
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )

        let oldRequestID = UUID()
        let oldSessionID = UUID()
        let oldGeneration = adapter.hostGeneration
        let oldStart = Task {
            let response = await adapter.handle(
                .start(
                    requestID: oldRequestID,
                    hostGeneration: oldGeneration,
                    clientSessionID: oldSessionID,
                    offerSDP: "v=0"
                ),
                connectionID: connectionID
            )
            await responseProbe.record(response)
            return response
        }
        await peerProbe.waitUntilRecorded()
        let oldPeer = peerProbe.peer()

        await adapter.stop()
        try await adapter.start()
        let newGeneration = adapter.hostGeneration
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )
        let newSessionID = UUID()
        let newStart = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: newGeneration,
                clientSessionID: newSessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        guard case let .startResult(_, _, returnedSessionID, _) = newStart else {
            Issue.record("Replacement remote start did not return an answer: \(newStart)")
            await oldPeer.close()
            _ = await oldStart.value
            return
        }
        #expect(returnedSessionID == newSessionID)
        let connected = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: newGeneration,
                clientSessionID: newSessionID
            ),
            connectionID: connectionID
        )
        #expect(connected == .operationResult(
            requestID: connected.requestID,
            hostGeneration: newGeneration,
            clientSessionID: newSessionID,
            outcome: "ok"
        ))

        let oldResponseReady = await responseProbe.waitForResponse(
            timeout: .milliseconds(100)
        )
        #expect(oldResponseReady)
        if !oldResponseReady {
            await oldPeer.close()
        }
        let oldResponse = await oldStart.value
        #expect(oldResponse == .error(
            requestID: oldRequestID,
            hostGeneration: oldGeneration,
            code: .invalidRequest
        ))
        let status = await adapter.handle(
            .status(requestID: UUID(), hostGeneration: newGeneration),
            connectionID: connectionID
        )
        #expect(status == .statusResult(
            requestID: status.requestID,
            hostGeneration: newGeneration,
            clientSessionID: newSessionID,
            state: .listening,
            reason: nil
        ))

        await completedStartGate.open()
        await adapter.stop()
    }

    @Test
    func restartWaitsForTerminalizationBeforeAdmittingNewServer() async throws {
        let activeGate = RemoteCompositionGate()
        let cleanupGate = RemoteCompositionGate()
        let model = makeModel(
            startRemote: { peer, receive in
                _ = try await peer.prepareOffer()
                try await peer.applyAnswerAndWaitForConnected("v=0")
                await receive(.sessionAdmitted(id: UUID()))
                await receive(.state(.listening))
                await activeGate.wait()
            },
            endRemote: { await cleanupGate.wait() }
        )
        let root = URL(fileURLWithPath: "/tmp/mrr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        try await adapter.start()
        let connectionID = UUID()
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )
        let sessionID = UUID()
        let start = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: sessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        guard case .startResult = start else {
            Issue.record("Remote start did not return an answer: \(start)")
            return
        }
        _ = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: sessionID
            ),
            connectionID: connectionID
        )
        await activeGate.waitUntilBlocked()

        let stopping = Task { await adapter.stop() }
        await cleanupGate.waitUntilBlocked()
        let restarting = Task {
            try await adapter.start()
        }
        await Task.yield()
        await cleanupGate.open()
        await activeGate.open()
        await stopping.value
        try await restarting.value
        #expect(FileManager.default.fileExists(atPath: adapter.socketPath.path))
        await adapter.stop()
    }

    @Test
    func remoteStartReturnsAnswerBeforeConnectedAndUsesExistingTranscriptRecorder() async throws {
        let probe = RemoteCompositionProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.recorderPersistence()
        )
        let sessionID = UUID()
        let answer = "v=0\\r\\no=- remote answer\\r\\n"
        let model = makeModel(
            recorder: recorder,
            startRemote: { peer, receive in
                _ = try await peer.prepareOffer()
                try await peer.applyAnswerAndWaitForConnected(answer)
                await receive(.sessionAdmitted(id: sessionID))
                await receive(.state(.listening))
                await receive(.transcriptDone(role: .user, text: ""))
                await receive(.transcriptDone(role: .assistant, text: "hello"))
                await receive(.transcriptDone(role: .assistant, text: "hello"))
                await probe.waitForEnd()
            },
            endRemote: { await probe.releaseEnd() }
        )
        let root = URL(fileURLWithPath: "/tmp/mrh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        try await adapter.start()

        let connectionID = UUID()
        let helloID = UUID()
        let hello = await adapter.handle(
            .hello(requestID: helloID, clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )
        #expect(hello == .helloAck(requestID: helloID, hostGeneration: adapter.hostGeneration))

        let clientSessionID = UUID()
        let start = Task {
            await adapter.handle(
                .start(
                    requestID: UUID(),
                    hostGeneration: adapter.hostGeneration,
                    clientSessionID: clientSessionID,
                    offerSDP: "v=0\\r\\no=- remote offer\\r\\n"
                ),
                connectionID: connectionID
            )
        }
        let startResponse = await start.value
        if case let .startResult(_, generation, sessionID, answerSDP) = startResponse {
            #expect(generation == adapter.hostGeneration)
            #expect(sessionID == clientSessionID)
            #expect(answerSDP == answer)
        } else {
            Issue.record("Remote start did not return a start result: \(startResponse)")
        }

        let connected = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: clientSessionID
            ),
            connectionID: connectionID
        )
        #expect(connected == .operationResult(
            requestID: connected.requestID,
            hostGeneration: adapter.hostGeneration,
            clientSessionID: clientSessionID,
            outcome: "ok"
        ))
        await probe.waitForCompletedEntry()
        #expect(await probe.startedSessionCount() == 1)
        #expect(await probe.completedEntryCount() == 1)
        #expect(await probe.typedSubmissionCount() == 0)

        let ended = await adapter.handle(
            .end(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: clientSessionID,
                reason: .completed
            ),
            connectionID: connectionID
        )
        #expect(ended == .operationResult(
            requestID: ended.requestID,
            hostGeneration: adapter.hostGeneration,
            clientSessionID: clientSessionID,
            outcome: "ok"
        ))
        await probe.waitForFinalization(.completed)
        #expect(await probe.finalizedOutcome() == .completed)
        #expect(await probe.finalizedCount() == 1)
        #expect(FileManager.default.fileExists(atPath: adapter.socketPath.path))
        await adapter.stop()
        #expect(!FileManager.default.fileExists(atPath: adapter.socketPath.path))
    }

    @Test
    func providerCompletionTerminalizesBridgeAndAllowsNextRemoteStart() async throws {
        let probe = RemoteCompositionProbe()
        let cleanupGate = RemoteCompositionGate()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.recorderPersistence()
        )
        let model = makeModel(
            recorder: recorder,
            startRemote: { peer, receive in
                _ = try await peer.prepareOffer()
                try await peer.applyAnswerAndWaitForConnected("v=0\\r\\nanswer\\r\\n")
                await receive(.sessionAdmitted(id: UUID()))
                await receive(.state(.listening))
            },
            endRemote: { await cleanupGate.wait() }
        )
        let root = URL(fileURLWithPath: "/tmp/mrp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        try await adapter.start()
        let connectionID = UUID()
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )

        let firstSessionID = UUID()
        let firstStart = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: firstSessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        guard case .startResult = firstStart else {
            Issue.record("First remote start did not return an answer: \(firstStart)")
            return
        }
        _ = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: firstSessionID
            ),
            connectionID: connectionID
        )
        await cleanupGate.waitUntilBlocked()
        await cleanupGate.open()
        await probe.waitForFinalization(.completed)
        await adapter.waitForRemoteTerminalization()
        let terminalStatus = await adapter.handle(
            .status(requestID: UUID(), hostGeneration: adapter.hostGeneration),
            connectionID: connectionID
        )
        #expect(terminalStatus == .statusResult(
            requestID: terminalStatus.requestID,
            hostGeneration: adapter.hostGeneration,
            clientSessionID: nil,
            state: .closed,
            reason: .providerClosed
        ))
        #expect(await probe.finalizedOutcome() == .completed)

        let secondSessionID = UUID()
        let secondStart = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: secondSessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        guard case let .startResult(_, _, returnedSessionID, _) = secondStart else {
            Issue.record("Second remote start was not admitted: \(secondStart)")
            await adapter.stop()
            return
        }
        #expect(returnedSessionID == secondSessionID)
        await adapter.stop()
    }

    @Test
    func reservedProviderCleanupCompletesAcrossStopAndRestartWithoutClearingNewSession() async throws {
        let cleanupGate = RemoteCompositionGate()
        let replacementGate = RemoteCompositionGate()
        let cleanupProbe = RemoteCompositionEndProbe()
        let starts = RemoteCompositionStartProbe()
        let model = makeModel(
            startRemote: { peer, receive in
                _ = try await peer.prepareOffer()
                try await peer.applyAnswerAndWaitForConnected("v=0")
                await receive(.sessionAdmitted(id: UUID()))
                await receive(.state(.listening))
                if await starts.nextStart() == 2 {
                    await replacementGate.wait()
                }
            },
            endRemote: {
                await cleanupGate.wait()
                await cleanupProbe.record()
            }
        )
        let root = URL(fileURLWithPath: "/tmp/mr-reserved-cleanup-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        try await adapter.start()
        let connectionID = UUID()
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )
        let firstSessionID = UUID()
        _ = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: firstSessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        _ = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: firstSessionID
            ),
            connectionID: connectionID
        )
        await cleanupGate.waitUntilBlocked()

        let stopping = Task { await adapter.stop() }
        await cleanupGate.open()
        await stopping.value
        try await adapter.start()
        let generation = adapter.hostGeneration
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )
        let secondSessionID = UUID()
        let secondStart = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: secondSessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        guard case .startResult = secondStart else {
            Issue.record("Replacement remote start did not return an answer: \(secondStart)")
            await adapter.stop()
            return
        }
        _ = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: generation,
                clientSessionID: secondSessionID
            ),
            connectionID: connectionID
        )
        let status = await adapter.handle(
            .status(requestID: UUID(), hostGeneration: generation),
            connectionID: connectionID
        )
        #expect(status == .statusResult(
            requestID: status.requestID,
            hostGeneration: generation,
            clientSessionID: secondSessionID,
            state: .listening,
            reason: nil
        ))
        #expect(await cleanupProbe.count() == 1)

        await replacementGate.open()
        await adapter.stop()
    }

    @Test
    func providerFailureAfterAnswerTerminalizesBridgeWithFailureReason() async throws {
        let probe = RemoteCompositionProbe()
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: await probe.recorderPersistence()
        )
        let model = makeModel(
            recorder: recorder,
            startRemote: { peer, receive in
                _ = try await peer.prepareOffer()
                try await peer.applyAnswerAndWaitForConnected("v=0\\r\\nanswer\\r\\n")
                await receive(.sessionAdmitted(id: UUID()))
                await receive(.state(.listening))
                throw RemoteLiveBridgeHostError.providerUnavailable
            }
        )
        let root = URL(fileURLWithPath: "/tmp/mrf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        try await adapter.start()
        let connectionID = UUID()
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )
        let sessionID = UUID()
        let start = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: sessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        guard case .startResult = start else {
            Issue.record("Provider failure did not return its answer: \(start)")
            await adapter.stop()
            return
        }
        _ = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: sessionID
            ),
            connectionID: connectionID
        )
        await probe.waitForFinalization(.failed)
        await adapter.waitForRemoteTerminalization()
        let terminalStatus = await adapter.handle(
            .status(requestID: UUID(), hostGeneration: adapter.hostGeneration),
            connectionID: connectionID
        )
        #expect(terminalStatus == .statusResult(
            requestID: terminalStatus.requestID,
            hostGeneration: adapter.hostGeneration,
            clientSessionID: nil,
            state: .failed,
            reason: .providerFailed
        ))
        #expect(await probe.finalizedOutcome() == .failed)
        #expect(await probe.finalizedCount() == 1)
        await adapter.stop()
    }

    @Test
    func remoteAndLocalStartsUseTheSameBusyFenceInBothDirections() async throws {
        let probe = RemoteCompositionProbe()
        let model = makeModel(
            startLocal: { _, receive in
                await probe.recordLocalStart()
                await receive(.sessionAdmitted(id: UUID()))
                await receive(.state(.listening))
                await probe.recordLocalListening()
                await probe.waitForEnd()
            },
            startRemote: { peer, receive in
                _ = try await peer.prepareOffer()
                try await peer.applyAnswerAndWaitForConnected("v=0\\r\\nanswer\\r\\n")
                await receive(.sessionAdmitted(id: UUID()))
                await receive(.state(.listening))
                await probe.recordRemoteListening()
                await probe.waitForEnd()
            },
            endLocal: { await probe.releaseEnd() },
            endRemote: { await probe.releaseEnd() }
        )
        let root = URL(fileURLWithPath: "/tmp/mrb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        try await adapter.start()
        let connectionID = UUID()
        _ = await adapter.handle(
            .hello(requestID: UUID(), clientID: "miller-remote.gateway"),
            connectionID: connectionID
        )

        let remoteSessionID = UUID()
        let remoteStart = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: remoteSessionID,
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        if case let .startResult(_, generation, sessionID, _) = remoteStart {
            #expect(generation == adapter.hostGeneration)
            #expect(sessionID == remoteSessionID)
        } else {
            Issue.record("Remote start did not return a start result: \(remoteStart)")
        }
        _ = await adapter.handle(
            .connected(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: remoteSessionID
            ),
            connectionID: connectionID
        )
        await probe.waitForRemoteListening()

        await model.startLiveVoice()
        #expect(await probe.localStartCount() == 0)

        _ = await adapter.handle(
            .end(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: remoteSessionID,
                reason: .completed
            ),
            connectionID: connectionID
        )
        #expect(!model.voiceState.isActive)

        let localStart = Task { await model.startLiveVoice() }
        await probe.waitForLocalListening()
        let busyRemote = await adapter.handle(
            .start(
                requestID: UUID(),
                hostGeneration: adapter.hostGeneration,
                clientSessionID: UUID(),
                offerSDP: "v=0"
            ),
            connectionID: connectionID
        )
        #expect(busyRemote == .error(
            requestID: busyRemote.requestID,
            hostGeneration: adapter.hostGeneration,
            code: .busy
        ))
        await model.endLiveVoice()
        await localStart.value
        await adapter.stop()
    }

    @Test
    func localActiveRemoteStartReturnsBusyBeforeProviderAvailability() async throws {
        let probe = RemoteCompositionProbe()
        let model = makeModel(
            startLocal: { _, receive in
                await receive(.sessionAdmitted(id: UUID()))
                await receive(.state(.listening))
                await probe.recordLocalListening()
                await probe.waitForEnd()
            },
            startRemote: { _, _ in },
            remoteAvailability: { .unavailable }
        )
        let localStart = Task { await model.startLiveVoice() }
        await probe.waitForLocalListening()

        let peer = RemoteBrowserLivePeer(clientSessionID: UUID(), offerSDP: "v=0")
        await #expect(throws: RemoteLiveBridgeHostError.busy) {
            try await model.startRemoteLiveVoice(peer: peer)
        }

        await model.endLiveVoice()
        await probe.releaseEnd()
        await localStart.value
    }

    @Test
    func remoteLiveSettingsToggleRunsEnableAndDisableOperations() async {
        let probe = RemoteSettingsProbe()
        let settings = RemoteLiveSettingsModel(
            enable: { await probe.recordEnable() },
            disable: { await probe.recordDisable() }
        )

        #expect(settings.isEnabled == false)
        settings.setEnabled(true)
        await settings.waitUntilIdle()
        #expect(await probe.enableCount() == 1)

        settings.setEnabled(false)
        await settings.waitUntilIdle()
        #expect(await probe.disableCount() == 1)
    }

    @Test
    func remoteLiveSettingsLifecycleResetDisablesExternalEffect() async {
        let probe = RemoteSettingsProbe()
        let settings = RemoteLiveSettingsModel(
            enable: { await probe.recordEnable(); await probe.setActive(true) },
            disable: { await probe.recordDisable(); await probe.setActive(false) }
        )
        settings.setEnabled(true)
        await settings.waitUntilIdle()

        await settings.disableForLifecycle()

        #expect(!settings.isEnabled)
        #expect(!settings.isWorking)
        #expect(await probe.active() == false)
        #expect(await probe.disableCount() == 1)

        await settings.restorePersistedPreferences(enabled: true)
        #expect(!settings.isEnabled)
        #expect(await probe.enableCount() == 1)

        settings.setEnabled(true)
        await settings.waitUntilIdle()
        #expect(await probe.enableCount() == 2)
        await settings.disableForLifecycle()
        #expect(await probe.disableCount() == 2)
    }

    @Test
    func remoteLiveSettingsShutdownDuringEnableCompensatesExternalEffect() async {
        let gate = RemoteSettingsGate()
        let probe = RemoteSettingsProbe()
        let settings = RemoteLiveSettingsModel(
            enable: {
                await gate.wait()
                await probe.recordEnable()
                await probe.setActive(true)
            },
            disable: {
                await probe.recordDisable()
                await probe.setActive(false)
            }
        )
        settings.setEnabled(true)
        await gate.waitUntilBlocked()
        let shutdown = Task { await settings.disableForLifecycle() }
        await Task.yield()
        await gate.open()
        await shutdown.value

        #expect(!settings.isEnabled)
        #expect(!settings.isWorking)
        #expect(await probe.enableCount() == 1)
        #expect(await probe.disableCount() == 1)
        #expect(await probe.active() == false)
    }

    @Test
    func remoteLiveSettingsRestoreYieldsToToggleRequestedDuringEnable() async {
        let gate = RemoteSettingsGate()
        let probe = RemoteSettingsProbe()
        let settings = RemoteLiveSettingsModel(
            enable: {
                await gate.wait()
                await probe.recordEnable()
                await probe.setActive(true)
            },
            disable: {
                await probe.recordDisable()
                await probe.setActive(false)
            }
        )
        let restore = Task {
            await settings.restorePersistedPreferences(enabled: true)
        }
        await gate.waitUntilBlocked()
        settings.setEnabled(false)
        await gate.open()
        await restore.value
        await settings.waitUntilIdle()

        #expect(await probe.enableCount() == 1)
        #expect(await probe.disableCount() == 1)
        #expect(await probe.active() == false)
    }

    @Test
    func remoteLiveSettingsToggleOwnsTheUDSSocketLifecycle() async throws {
        let model = makeModel(startRemote: { _, _ in })
        let root = URL(fileURLWithPath: "/tmp/mrs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        let settings = RemoteLiveSettingsModel(
            enable: { try await adapter.start() },
            disable: { await adapter.stop() }
        )

        settings.setEnabled(true)
        await settings.waitUntilIdle()
        #expect(settings.isEnabled)
        #expect(FileManager.default.fileExists(atPath: adapter.socketPath.path))

        settings.setEnabled(false)
        await settings.waitUntilIdle()
        #expect(!settings.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: adapter.socketPath.path))
    }

    @Test
    func remoteLiveSettingsShutdownDuringEnableLeavesNoSocket() async throws {
        let model = makeModel(startRemote: { _, _ in })
        let root = URL(fileURLWithPath: "/tmp/mrt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MillerRemoteHostAdapter(
            model: model,
            homeDirectory: root,
            generation: UUID()
        )
        let gate = RemoteSettingsGate()
        let settings = RemoteLiveSettingsModel(
            enable: {
                await gate.wait()
                try await adapter.start()
            },
            disable: { await adapter.stop() }
        )

        settings.setEnabled(true)
        await gate.waitUntilBlocked()
        let shutdown = Task { await settings.disableForLifecycle() }
        await Task.yield()
        await gate.open()
        await shutdown.value

        #expect(!settings.isEnabled)
        #expect(!settings.isWorking)
        #expect(!FileManager.default.fileExists(atPath: adapter.socketPath.path))
        await adapter.stop()
    }

    private func makeModel(
        recorder: LiveVoiceTranscriptRecorder = .init(),
        startLocal: @escaping LiveVoiceStartOperation = { _, _ in },
        startRemote: @escaping LiveVoiceRemoteStartOperation,
        remoteAvailability: @escaping @Sendable () async -> LiveVoiceState = { .available },
        endLocal: @escaping @Sendable () async -> Void = {},
        endRemote: @escaping @Sendable () async -> Void = {}
    ) -> AppPresentationModel {
        AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in TurnID() },
                stop: {},
                loadTurn: { _ in nil },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in },
                admitLive: { conversationID, source in
                    LiveAdmission(
                        conversationID: conversationID,
                        activationSource: source
                    )
                }
            ),
            liveVoice: LiveVoiceDependencies(
                initialAvailability: .available,
                availability: { .available },
                remoteAvailability: remoteAvailability,
                start: startLocal,
                startRemote: startRemote,
                mute: { _ in },
                interrupt: endLocal,
                end: endRemote
            ),
            liveTranscriptRecorder: recorder
        )
    }

}

private actor RemoteCompositionProbe {
    private var endWaiters: [CheckedContinuation<Void, Never>] = []
    private var endReleased = false
    private var starts = 0
    private var localStarts = 0
    private var completedEntries = 0
    private var typedSubmissions = 0
    private var finalizedOutcomes: [VoiceSessionTerminalOutcome] = []
    private var completedEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finalizationWaiters: [
        (VoiceSessionTerminalOutcome, CheckedContinuation<Void, Never>)
    ] = []
    private var remoteListening = false
    private var localListening = false
    private var remoteListeningWaiters: [CheckedContinuation<Void, Never>] = []
    private var localListeningWaiters: [CheckedContinuation<Void, Never>] = []

    func recorderPersistence() -> LiveVoiceTranscriptRecorder.Persistence {
        .init(
            savingEnabled: { true },
            nextSessionSavingEnabled: { true },
            restoreNextSessionSavingDefault: {},
            startSession: { [weak self] _, _, _, _ in
                await self?.recordStart()
            },
            appendEntry: { _, _, _, _, _, _ in },
            completeEntry: { [weak self] _, _ in
                await self?.recordCompletedEntry()
            },
            finalizeSession: { [weak self] _, outcome in
                await self?.recordFinalized(outcome)
            },
            recoverInterruptedSessions: {}
        )
    }

    func recordStart() { starts += 1 }
    func recordLocalStart() { localStarts += 1 }
    func recordCompletedEntry() {
        completedEntries += 1
        let waiters = completedEntryWaiters
        completedEntryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func recordFinalized(_ outcome: VoiceSessionTerminalOutcome) {
        finalizedOutcomes.append(outcome)
        let matching = finalizationWaiters.filter { $0.0 == outcome }
        finalizationWaiters.removeAll { $0.0 == outcome }
        matching.forEach { $0.1.resume() }
    }
    func recordTypedSubmission() { typedSubmissions += 1 }

    func startedSessionCount() -> Int { starts }
    func localStartCount() -> Int { localStarts }
    func completedEntryCount() -> Int { completedEntries }
    func finalizedOutcome() -> VoiceSessionTerminalOutcome? { finalizedOutcomes.last }
    func finalizedCount() -> Int { finalizedOutcomes.count }
    func typedSubmissionCount() -> Int { typedSubmissions }

    func waitForCompletedEntry() async {
        guard completedEntries == 0 else { return }
        await withCheckedContinuation { completedEntryWaiters.append($0) }
    }

    func waitForFinalization(_ outcome: VoiceSessionTerminalOutcome) async {
        guard !finalizedOutcomes.contains(outcome) else { return }
        await withCheckedContinuation { finalizationWaiters.append((outcome, $0)) }
    }

    func recordRemoteListening() {
        remoteListening = true
        let waiters = remoteListeningWaiters
        remoteListeningWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForRemoteListening() async {
        guard !remoteListening else { return }
        await withCheckedContinuation { remoteListeningWaiters.append($0) }
    }

    func recordLocalListening() {
        localListening = true
        let waiters = localListeningWaiters
        localListeningWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForLocalListening() async {
        guard !localListening else { return }
        await withCheckedContinuation { localListeningWaiters.append($0) }
    }

    func waitForEnd() async {
        if endReleased { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    func releaseEnd() {
        endReleased = true
        let waiters = endWaiters
        endWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class RemoteCompositionPeerProbe: @unchecked Sendable {
    private var recordedPeer: RemoteBrowserLivePeer?
    private var recorded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ peer: any LiveAudioPeer) {
        recordedPeer = peer as? RemoteBrowserLivePeer
        recorded = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilRecorded() async {
        guard !recorded else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func peer() -> RemoteBrowserLivePeer {
        recordedPeer!
    }
}

private actor RemoteCompositionStartProbe {
    private var starts = 0

    func nextStart() -> Int {
        starts += 1
        return starts
    }
}

private actor RemoteCompositionEndProbe {
    private var ends = 0

    func record() {
        ends += 1
    }

    func count() -> Int { ends }
}

private actor RemoteCompositionResponseProbe {
    private var response: RemoteLiveResponse?

    func record(_ response: RemoteLiveResponse) {
        self.response = response
    }

    func waitForResponse(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while response == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return response != nil
    }
}

private actor RemoteSettingsProbe {
    private var enables = 0
    private var disables = 0
    private var isActive = false

    func recordEnable() { enables += 1 }
    func recordDisable() { disables += 1 }
    func setActive(_ active: Bool) { isActive = active }
    func enableCount() -> Int { enables }
    func disableCount() -> Int { disables }
    func active() -> Bool { isActive }
}

private actor RemoteSettingsGate {
    private var opened = false
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        if !blocked {
            blocked = true
            let pending = blockedWaiters
            blockedWaiters.removeAll()
            pending.forEach { $0.resume() }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        let blockedWaiters = blockedWaiters
        self.blockedWaiters.removeAll()
        blockedWaiters.forEach { $0.resume() }
    }
}

private actor RemoteCompositionGate {
    private var opened = false
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        if !blocked {
            blocked = true
            let pending = blockedWaiters
            blockedWaiters.removeAll()
            pending.forEach { $0.resume() }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        let blockedWaiters = blockedWaiters
        self.blockedWaiters.removeAll()
        blockedWaiters.forEach { $0.resume() }
    }
}
