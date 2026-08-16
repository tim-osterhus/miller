import Foundation
import MillerCore
import MillerLive
import MillerLiveAudio
import MillerRemoteBridge
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct GPTLiveDirectControllerTests {
    @Test
    func remoteStartReusesProviderLifecycleWithoutMacMicrophoneOrLocalPeer() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let peer = RemoteBrowserLivePeer(
            clientSessionID: UUID(),
            offerSDP: directControllerSyntheticOffer
        )
        let localPeerFactoryCalls = DirectControllerCounter()
        let microphoneCalls = DirectControllerCounter()
        let socket = DirectControllerSocket()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-remote-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: {
                await microphoneCalls.increment()
                return .denied
            },
            makePeer: {
                await localPeerFactoryCalls.increment()
                return DirectControllerPeer()
            },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(
                    peer: peer,
                    callCreator: GPTLiveCallCreator(loader: DirectControllerLoader()),
                    sidebandConnector: GPTLiveSidebandConnector(
                        factory: { _, _ in socket },
                        sleep: { _ in }
                    ),
                    configuration: configuration
                )
            }
        )
        let states = DirectControllerStateProbe()
        let run = Task { @MainActor in
            try? await controller.startRemote(peer: peer) { event in
                if case let .state(state) = event { states.append(state) }
            }
        }

        _ = try await peer.providerAnswer()
        #expect(peer.markConnected())
        try await waitUntilDirectController { states.contains(.listening) }
        await controller.dependencies().end()
        await run.value

        #expect(await microphoneCalls.value == 0)
        #expect(await localPeerFactoryCalls.value == 0)
        #expect(states.valuesSnapshot == [.connecting, .listening])
    }

    @Test
    func noHelperSelectsDirectGPTLiveAndKeepsPeerLifecycleBounded() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let peer = DirectControllerPeer()
        let socket = DirectControllerSocket()
        let credentialLoads = DirectControllerCounter()
        let credentialAdmission = DirectControllerCredentialAdmission()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await credentialLoads.increment()
                await credentialAdmission.record(.load)
                return envelope
            }),
            refreshCredential: {
                await credentialAdmission.record(.refresh)
            },
            microphonePermission: { .authorized },
            makePeer: { peer },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(
                    peer: peer,
                    callCreator: GPTLiveCallCreator(loader: DirectControllerLoader()),
                    sidebandConnector: GPTLiveSidebandConnector(
                        factory: { _, _ in socket },
                        sleep: { _ in }
                    ),
                    configuration: configuration
                )
            }
        )
        #expect(await controller.availability() == .available)
        #expect(await credentialLoads.value == 0)
        let dependencies = controller.dependencies()
        let states = DirectControllerStateProbe()
        let run = Task {
            try? await dependencies.start(LiveVoiceStartContext.manual) { event in
                if case let .state(state) = event {
                    states.append(state)
                }
            }
        }

        try await waitUntilDirectController { states.contains(.listening) }
        await dependencies.end()
        await run.value

        #expect(peer.operations == [.prepare, .answer, .close])
        #expect(peer.operations.filter { $0 == .response }.isEmpty)
        #expect(states.valuesSnapshot == [.connecting, .listening])
        #expect(await credentialLoads.value == 1)
        #expect(await credentialAdmission.events == [.refresh, .load])
    }

    @Test
    func wakeRearmCannotObserveControllerEndBeforeLiveLeaseRelease() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let ownership = MicrophoneOwnership()
        let peer = DirectControllerPeer()
        let socket = DirectControllerSocket()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            makePeer: { peer },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(
                    peer: peer,
                    callCreator: GPTLiveCallCreator(loader: DirectControllerLoader()),
                    sidebandConnector: GPTLiveSidebandConnector(
                        factory: { _, _ in socket },
                        sleep: { _ in }
                    ),
                    configuration: configuration
                )
            },
            microphoneOwnership: ownership
        )
        let dependencies = controller.dependencies()
        let order = DirectControllerLeaseOrderProbe()
        let run = Task {
            try? await dependencies.start(LiveVoiceStartContext.wakeword) { event in
                if case .state(.listening) = event {
                    Task(priority: .high) {
                        await dependencies.end()
                        let wakeLease = try? ownership.acquire(.wake)
                        wakeLease?.release()
                        await order.recordEnd(wakeLeaseAcquired: wakeLease != nil)
                    }
                }
            }
        }

        try await waitUntilDirectControllerAsync { await order.endCompleted }
        await run.value

        #expect(await order.wakeLeaseAcquired)
    }

    @Test
    func controllerCompletionReleasesLiveLeaseBeforeResumingStopWaiters() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MillerApp/Voice/GPTLiveController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let completion = try #require(source.range(of: "private func finishStart()"))
        let finishStartSource = String(source[completion.lowerBound...])
        let release = try #require(
            finishStartSource.range(of: "releaseLiveMicrophoneLeaseIfNeeded()")
        )
        let waiterResume = try #require(
            finishStartSource.range(of: "for waiter in waiters { waiter.resume() }")
        )

        #expect(release.lowerBound < waiterResume.lowerBound)
    }

    @Test
    func wakeDirectSessionRequestsExactlyOneProviderResponseAfterPeerConnection() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let peer = DirectControllerPeer()
        let socket = DirectControllerSocket()
        let states = DirectControllerStateProbe()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            makePeer: { peer },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(
                    peer: peer,
                    callCreator: GPTLiveCallCreator(loader: DirectControllerLoader()),
                    sidebandConnector: GPTLiveSidebandConnector(
                        factory: { _, _ in socket },
                        sleep: { _ in }
                    ),
                    configuration: configuration
                )
            }
        )
        let dependencies = controller.dependencies()
        let run = Task {
            try? await dependencies.start(LiveVoiceStartContext.wakeword) { event in
                if case let .state(state) = event {
                    states.append(state)
                }
            }
        }

        try await waitUntilDirectController { states.contains(.listening) }
        await dependencies.end()
        await run.value

        #expect(peer.operations == [.prepare, .answer, .response, .close])
    }

    @Test
    func wakeHelperSessionRequestsExactlyOneProviderResponseAfterPeerConnection() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/helper-wake-response-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryParent) }
        let fixture = repository.appendingPathComponent(
            "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
        )
        let helper = temporaryParent.appendingPathComponent("fake-helper")
        try Data(
            "#!/bin/sh\nexec /opt/homebrew/opt/node@22/bin/node \(fixture.path) wait-stop\n".utf8
        ).write(to: helper)
        #expect(chmod(helper.path, 0o700) == 0)

        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let peer = DirectControllerPeer()
        let states = DirectControllerStateProbe()
        let controller = try GPTLiveController(
            helperURL: helper,
            temporaryParentURL: temporaryParent,
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            makeSession: { client in LiveAudioSession(client: client, peer: peer) },
            helperVerifier: { _ in },
            spawnedProcessVerifier: { _ in }
        )
        let dependencies = controller.dependencies()
        let run = Task {
            try? await dependencies.start(LiveVoiceStartContext.wakeword) { event in
                if case let .state(state) = event {
                    states.append(state)
                }
            }
        }

        try await waitUntilDirectController(timeout: .seconds(5)) {
            states.contains(.listening)
        }
        await dependencies.end()
        await run.value

        let manualRun = Task {
            try? await dependencies.start(LiveVoiceStartContext.manual) { _ in }
        }
        try await waitUntilDirectController(timeout: .seconds(5)) {
            peer.operations.filter { $0 == .answer }.count == 2
        }
        await dependencies.end()
        await manualRun.value

        #expect(peer.operations.filter { $0 == .response }.count == 1)
        #expect(peer.operations.suffix(3) == [.prepare, .answer, .close])
    }

    @Test
    func directFactoryReceivesWakeInstructionOnlyForWakeStarts() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let configurations = DirectControllerConfigurationRecorder()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            makePeer: { DirectControllerPeer(failPrepare: true) },
            makeDirectSession: { peer, configuration in
                configurations.record(configuration)
                return DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )

        let dependencies = controller.dependencies()
        try? await dependencies.start(LiveVoiceStartContext.wakeword) { _ in }
        try? await dependencies.start(LiveVoiceStartContext.manual) { _ in }

        let values = configurations.values
        #expect(values.count == 2)
        #expect(values[0].instructions.contains(
            GPTLiveSessionInstructions.wakeAcknowledgement
        ))
        #expect(values[1].instructions.contains(
            GPTLiveSessionInstructions.wakeAcknowledgement
        ) == false)
    }

    @Test
    func endCancelsAStalledCredentialRefresh() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let refresh = DirectControllerRefreshGate()
        let stop = DirectControllerCompletionProbe()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                throw GPTLiveCredentialError.invalidCredential
            }),
            refreshCredential: { await refresh.wait() },
            microphonePermission: { .authorized },
            makePeer: { DirectControllerPeer() },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )
        let dependencies = controller.dependencies()
        let run = Task {
            try? await dependencies.start(LiveVoiceStartContext.manual) { _ in }
        }
        try await waitUntilDirectControllerAsync { await refresh.entered }

        let end = Task {
            await dependencies.end()
            await stop.complete()
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await stop.completed)

        await refresh.release()
        await end.value
        await run.value
    }

    @Test
    func stalledCredentialRefreshTimesOut() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let refresh = DirectControllerRefreshGate()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                throw GPTLiveCredentialError.invalidCredential
            }),
            refreshCredential: { await refresh.wait() },
            microphonePermission: { .authorized },
            credentialRefreshTimeout: .milliseconds(20),
            makePeer: { DirectControllerPeer() },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )
        let dependencies = controller.dependencies()
        let result = await Task {
            do {
                try await dependencies.start(LiveVoiceStartContext.manual) { _ in }
                return false
            } catch let error as LiveProcessError {
                return error == .timeout
            } catch {
                return false
            }
        }.value

        #expect(result)
        await refresh.release()
    }

    @Test
    func failedCredentialRefreshStopsAdmissionBeforeCredentialLoad() async throws {
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let credentialLoads = DirectControllerCounter()
        let peer = DirectControllerPeer()
        let controller = try GPTLiveController(
            helperURL: nil,
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-live-test"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await credentialLoads.increment()
                throw GPTLiveCredentialError.invalidCredential
            }),
            refreshCredential: { throw DirectControllerRefreshFailure() },
            microphonePermission: { .authorized },
            makePeer: { peer },
            makeDirectSession: { peer, configuration in
                DirectGPTLiveSession(peer: peer, configuration: configuration)
            }
        )

        await #expect(throws: DirectControllerRefreshFailure.self) {
            try await controller.dependencies().start(LiveVoiceStartContext.manual) { _ in }
        }
        #expect(await credentialLoads.value == 0)
        #expect(peer.operations.isEmpty)
    }

    @Test
    func outputMonitorStartsOnlyAfterAdmissionAndEmitsMeasuredOutput() async throws {
        let peer = DirectOutputControllerPeer(holdAnswer: true)
        let socket = DirectOutputControllerSocket()
        let probe = DirectOutputControllerProbe()
        var order = [String]()
        peer.onMonitorStart = { order.append("monitor") }
        let controller = try makeDirectOutputController(
            peers: DirectOutputControllerPeerFactory(peers: [peer]),
            sockets: DirectOutputControllerSocketFactory(sockets: [socket]),
            sink: { _, observation in probe.record(observation) }
        )
        let dependencies = controller.dependencies()
        let run = Task { @MainActor in
            try? await dependencies.start(.manual) { event in
                probe.record(event)
                if case .sessionAdmitted = event {
                    order.append("admitted")
                }
            }
        }

        try await waitUntilDirectController { peer.answerEntered }
        #expect(peer.monitorStartCount == 0)
        #expect(probe.admitted == false)

        peer.releaseAnswer()
        try await waitUntilDirectController {
            peer.monitorStartCount == 1 && probe.admitted
        }
        #expect(order == ["admitted", "monitor"])

        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 100,
                envelope: 0.8
            )
        )
        try await Task.sleep(for: .milliseconds(45))
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 132,
                envelope: 0.8
            )
        )
        try await waitUntilDirectController {
            probe.observations.count >= 2
        }
        #expect(probe.observations.first == .playbackStarted(offsetMilliseconds: 132))
        #expect(probe.observations.contains(.mouthCue(offsetMilliseconds: 132, envelope: 0.8)))

        await dependencies.end()
        await run.value
        #expect(peer.closeCalls == 1)
    }

    @Test(arguments: DirectOutputTermination.allCases)
    func outputMonitorNeutralizesOnEveryControllerTermination(
        _ termination: DirectOutputTermination
    ) async throws {
        let peer = DirectOutputControllerPeer(
            failMute: termination == .failure
        )
        let socket = DirectOutputControllerSocket()
        let probe = DirectOutputControllerProbe()
        let controller = try makeDirectOutputController(
            peers: DirectOutputControllerPeerFactory(peers: [peer]),
            sockets: DirectOutputControllerSocketFactory(sockets: [socket]),
            sink: { _, observation in probe.record(observation) }
        )
        let dependencies = controller.dependencies()
        let run = Task { @MainActor in
            try? await dependencies.start(.manual) { event in
                probe.record(event)
            }
        }

        try await waitUntilDirectController {
            peer.monitorStartCount == 1 && probe.admitted
        }
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 100,
                envelope: 0.8
            )
        )
        try await Task.sleep(for: .milliseconds(45))
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 132,
                envelope: 0.8
            )
        )
        try await waitUntilDirectController {
            probe.observations.contains {
                if case .playbackStarted = $0 { return true }
                return false
            }
        }
        switch termination {
        case .interrupt:
            await dependencies.interrupt()
        case .end:
            await dependencies.end()
        case .failure:
            await dependencies.mute(true)
        case .spontaneousClose:
            socket.close()
        }

        await run.value
        try await waitUntilDirectController { peer.closeCalls == 1 }
        try await waitUntilDirectController {
            probe.observations.contains {
                if case .playbackStopped = $0 { return true }
                return false
            }
        }
        let observationCount = probe.observations.count
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 200,
                envelope: 0.9
            )
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(peer.closeCalls == 1)
        #expect(peer.streamFinished)
        #expect(probe.observations.count == observationCount)
    }

    @Test
    func stalePriorGenerationOutputIsRejectedAfterAReplacementStart() async throws {
        let firstPeer = DirectOutputControllerPeer(finishStreamOnClose: false)
        let secondPeer = DirectOutputControllerPeer()
        let firstSocket = DirectOutputControllerSocket()
        let secondSocket = DirectOutputControllerSocket()
        let probe = DirectOutputControllerProbe()
        let controller = try makeDirectOutputController(
            peers: DirectOutputControllerPeerFactory(peers: [firstPeer, secondPeer]),
            sockets: DirectOutputControllerSocketFactory(
                sockets: [firstSocket, secondSocket]
            ),
            sink: { _, observation in probe.record(observation) }
        )
        let dependencies = controller.dependencies()

        let firstRun = Task { @MainActor in
            try? await dependencies.start(.manual) { event in
                probe.record(event)
            }
        }
        try await waitUntilDirectController {
            firstPeer.monitorStartCount == 1 && probe.admitted
        }
        await dependencies.end()
        await firstRun.value
        #expect(firstPeer.closeCalls == 1)

        probe.resetAdmission()
        let secondRun = Task { @MainActor in
            try? await dependencies.start(.manual) { event in
                probe.record(event)
            }
        }
        try await waitUntilDirectController {
            secondPeer.monitorStartCount == 1 && probe.admitted
        }
        let observationsBeforeStale = probe.observations.count
        firstPeer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 300,
                envelope: 0.9
            )
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.observations.count == observationsBeforeStale)

        firstPeer.finishStream()
        await dependencies.end()
        await secondRun.value
        #expect(secondPeer.closeCalls == 1)
    }

    @Test
    func wakeStartAndMicrophoneMuteCannotCreateOrStopRemoteOutputCues() async throws {
        let peer = DirectOutputControllerPeer()
        let socket = DirectOutputControllerSocket()
        let probe = DirectOutputControllerProbe()
        let controller = try makeDirectOutputController(
            peers: DirectOutputControllerPeerFactory(peers: [peer]),
            sockets: DirectOutputControllerSocketFactory(sockets: [socket]),
            sink: { _, observation in probe.record(observation) }
        )
        let dependencies = controller.dependencies()
        let run = Task { @MainActor in
            try? await dependencies.start(.wakeword) { event in
                probe.record(event)
            }
        }

        try await waitUntilDirectController {
            peer.monitorStartCount == 1 && probe.admitted
        }
        #expect(probe.observations.isEmpty)
        await dependencies.mute(true)
        #expect(probe.observations.isEmpty)

        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 100,
                envelope: 0.8
            )
        )
        try await Task.sleep(for: .milliseconds(45))
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 132,
                envelope: 0.8
            )
        )
        try await waitUntilDirectController {
            probe.observations.contains {
                if case .playbackStarted = $0 { return true }
                return false
            }
        }
        await dependencies.mute(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.observations.contains {
            if case .playbackStopped = $0 { return true }
            return false
        } == false)

        await dependencies.end()
        await run.value
    }

    @Test
    func terminalStopFencesOutputQueuedAcrossAReentrantControllerStop() async throws {
        let peer = DirectOutputControllerPeer(finishStreamOnClose: false)
        let socket = DirectOutputControllerSocket()
        let probe = DirectOutputControllerProbe()
        let mainActorGate = DirectOutputMainActorGate()
        let controller = try makeDirectOutputController(
            peers: DirectOutputControllerPeerFactory(peers: [peer]),
            sockets: DirectOutputControllerSocketFactory(sockets: [socket]),
            sink: { _, observation in
                if mainActorGate.stopRequested {
                    mainActorGate.recordAfterStop(observation)
                }
                probe.record(observation)
            }
        )
        let dependencies = controller.dependencies()
        let run = Task { @MainActor in
            try? await dependencies.start(.manual) { event in
                probe.record(event)
            }
        }

        try await waitUntilDirectController {
            peer.monitorStartCount == 1 && probe.admitted
        }
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 100,
                envelope: 0.8
            )
        )
        try await Task.sleep(for: .milliseconds(45))
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 132,
                envelope: 0.8
            )
        )
        try await waitUntilDirectController {
            probe.observations.contains {
                if case .playbackStarted = $0 { return true }
                return false
            }
        }
        let blocker = Task { @MainActor in
            mainActorGate.block()
        }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            mainActorGate.release()
        }
        Task.detached {
            await mainActorGate.waitUntilBlocked()
            peer.emitFromAnyActor(
                LiveAudioOutputSample(
                    isPlaying: true,
                    offsetMilliseconds: 164,
                    envelope: 0.8
                )
            )
        }
        try await waitUntilDirectControllerAsync { mainActorGate.isBlocked }

        let stop = Task(priority: .high) {
            try? await Task.sleep(for: .milliseconds(75))
            mainActorGate.markStopRequested()
            await dependencies.end()
        }
        await stop.value
        await blocker.value
        await run.value

        try await waitUntilDirectController {
            probe.observations.contains {
                if case .playbackStopped = $0 { return true }
                return false
            }
        }
        guard let stopIndex = probe.observations.firstIndex(where: {
            if case .playbackStopped = $0 { return true }
            return false
        }) else {
            Issue.record("expected synthesized playback stop")
            return
        }
        #expect(mainActorGate.postStopActiveObservations == 0)
        #expect(!probe.observations.dropFirst(stopIndex + 1).contains {
            switch $0 {
            case .playbackStarted, .mouthCue: return true
            case .playbackStopped: return false
            }
        })
    }

    @Test
    func naturalStopQueuedBeforeTerminationStillReceivesATerminalStop() async throws {
        let peer = DirectOutputControllerPeer(finishStreamOnClose: false)
        let socket = DirectOutputControllerSocket()
        let probe = DirectOutputControllerProbe()
        let mainActorGate = DirectOutputMainActorGate()
        let controller = try makeDirectOutputController(
            peers: DirectOutputControllerPeerFactory(peers: [peer]),
            sockets: DirectOutputControllerSocketFactory(sockets: [socket]),
            sink: { _, observation in probe.record(observation) }
        )
        let dependencies = controller.dependencies()
        let run = Task { @MainActor in
            try? await dependencies.start(.manual) { event in
                probe.record(event)
            }
        }

        try await waitUntilDirectController {
            peer.monitorStartCount == 1 && probe.admitted
        }
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 100,
                envelope: 0.8
            )
        )
        try await Task.sleep(for: .milliseconds(45))
        peer.emit(
            LiveAudioOutputSample(
                isPlaying: true,
                offsetMilliseconds: 132,
                envelope: 0.8
            )
        )
        try await waitUntilDirectController {
            probe.observations.contains {
                if case .playbackStarted = $0 { return true }
                return false
            }
        }

        let blocker = Task { @MainActor in
            mainActorGate.block()
        }
        let scenario = Task.detached {
            await mainActorGate.waitUntilBlocked()
            try? await Task.sleep(for: .milliseconds(450))
            peer.emitFromAnyActor(
                LiveAudioOutputSample(
                    isPlaying: false,
                    offsetMilliseconds: 500,
                    envelope: 0
                )
            )
            try? await Task.sleep(for: .milliseconds(100))
            await dependencies.end()
        }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(900))
            mainActorGate.release()
        }

        await scenario.value
        await blocker.value
        await run.value

        guard let stopIndex = probe.observations.firstIndex(where: {
            if case .playbackStopped = $0 { return true }
            return false
        }) else {
            Issue.record("expected a terminal playback stop")
            return
        }
        #expect(probe.observations.dropFirst(stopIndex + 1).allSatisfy {
            if case .playbackStopped = $0 { return true }
            return false
        })
    }
}

enum DirectOutputTermination: CaseIterable, Equatable, Sendable {
    case interrupt
    case end
    case failure
    case spontaneousClose
}

@MainActor
private func makeDirectOutputController(
    peers: DirectOutputControllerPeerFactory,
    sockets: DirectOutputControllerSocketFactory,
    sink: @escaping LiveAudioOutputObservationSink
) throws -> GPTLiveController {
    let profile = try ProviderProfile(
        kind: .codexOAuth,
        label: "Codex",
        baseURL: nil,
        model: "gpt-5.6-terra",
        credentialReference: UUID(),
        isSelected: true
    )
    let envelope = try CredentialEnvelope(
        providerKind: .codexOAuth,
        payload: Data(
            #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
        )
    )
    return try GPTLiveController(
        helperURL: nil,
        temporaryParentURL: URL(fileURLWithPath: "/private/tmp/miller-direct-output-test"),
        selectedProfile: { profile },
        credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
        refreshCredential: {},
        microphonePermission: { .authorized },
        makePeer: { peers.next() },
        makeDirectSession: { peer, configuration in
            let socket = sockets.next()
            return DirectGPTLiveSession(
                peer: peer,
                callCreator: GPTLiveCallCreator(
                    loader: DirectControllerLoader()
                ),
                sidebandConnector: GPTLiveSidebandConnector(
                    factory: { _, _ in socket },
                    sleep: { _ in }
                ),
                configuration: configuration
            )
        },
        outputObservationSink: sink
    )
}

@MainActor
private final class DirectOutputControllerProbe {
    private(set) var events = [LiveVoiceEvent]()
    private(set) var observations = [LiveAudioOutputObservation]()

    var admitted: Bool {
        events.contains {
            if case .sessionAdmitted = $0 { return true }
            return false
        }
    }

    func record(_ event: LiveVoiceEvent) {
        events.append(event)
    }

    func record(_ observation: LiveAudioOutputObservation) {
        observations.append(observation)
    }

    func resetAdmission() {
        events.removeAll()
    }
}

@MainActor
private final class DirectOutputControllerPeer: LiveAudioPeer,
    LiveAudioOutputMonitoring {
    private let stream: AsyncStream<LiveAudioOutputSample>
    private let sampleEmitter: DirectOutputControllerSampleEmitter
    private var continuation: AsyncStream<LiveAudioOutputSample>.Continuation?
    private let holdAnswer: Bool
    private let failMute: Bool
    private let finishStreamOnClose: Bool
    private var answerContinuation: CheckedContinuation<Void, Never>?

    private(set) var answerEntered = false
    private(set) var monitorStartCount = 0
    private(set) var closeCalls = 0
    private(set) var streamFinished = false
    var onMonitorStart: (() -> Void)?

    nonisolated init(
        holdAnswer: Bool = false,
        failMute: Bool = false,
        finishStreamOnClose: Bool = true
    ) {
        let (stream, continuation) = AsyncStream<LiveAudioOutputSample>.makeStream()
        self.stream = stream
        self.sampleEmitter = DirectOutputControllerSampleEmitter(continuation: continuation)
        self.continuation = continuation
        self.holdAnswer = holdAnswer
        self.failMute = failMute
        self.finishStreamOnClose = finishStreamOnClose
    }

    func prepareOffer() async throws -> String {
        directControllerSyntheticOffer
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        answerEntered = true
        guard holdAnswer else { return }
        await withCheckedContinuation { answerContinuation = $0 }
    }

    func requestResponse() async throws {}

    func setMuted(_ muted: Bool) async throws {
        if failMute { throw DirectOutputControllerPeerError.mute }
    }

    func close() async {
        closeCalls += 1
        if finishStreamOnClose { finishStream() }
    }

    func outputSamples() -> AsyncStream<LiveAudioOutputSample> {
        monitorStartCount += 1
        onMonitorStart?()
        return stream
    }

    func releaseAnswer() {
        answerContinuation?.resume()
        answerContinuation = nil
    }

    func emit(_ sample: LiveAudioOutputSample) {
        continuation?.yield(sample)
    }

    nonisolated func emitFromAnyActor(_ sample: LiveAudioOutputSample) {
        sampleEmitter.emit(sample)
    }

    func finishStream() {
        guard !streamFinished else { return }
        streamFinished = true
        continuation?.finish()
        continuation = nil
        sampleEmitter.finish()
    }
}

private final class DirectOutputControllerSampleEmitter: @unchecked Sendable {
    private let continuation: AsyncStream<LiveAudioOutputSample>.Continuation

    init(continuation: AsyncStream<LiveAudioOutputSample>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ sample: LiveAudioOutputSample) {
        continuation.yield(sample)
    }

    func finish() {
        continuation.finish()
    }
}

private final class DirectOutputMainActorGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var blocked = false
    private var blockedWaiters = [CheckedContinuation<Void, Never>]()
    private var stopWasRequested = false
    private var postStopActiveCount = 0

    var stopRequested: Bool {
        lock.withLock { stopWasRequested }
    }

    var postStopActiveObservations: Int {
        lock.withLock { postStopActiveCount }
    }

    var isBlocked: Bool {
        lock.withLock { blocked }
    }

    func block() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            blocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
        semaphore.wait()
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if blocked { return true }
                blockedWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        semaphore.signal()
    }

    func markStopRequested() {
        lock.withLock { stopWasRequested = true }
    }

    func recordAfterStop(_ observation: LiveAudioOutputObservation) {
        switch observation {
        case .playbackStarted, .mouthCue:
            lock.withLock { postStopActiveCount += 1 }
        case .playbackStopped:
            break
        }
    }
}

private enum DirectOutputControllerPeerError: Error {
    case mute
}

private final class DirectOutputControllerPeerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [DirectOutputControllerPeer]

    init(peers: [DirectOutputControllerPeer]) {
        self.peers = peers
    }

    func next() -> any LiveAudioPeer {
        lock.withLock { peers.removeFirst() }
    }
}

private final class DirectOutputControllerSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [DirectOutputControllerSocket]

    init(sockets: [DirectOutputControllerSocket]) {
        self.sockets = sockets
    }

    func next() -> DirectOutputControllerSocket {
        lock.withLock { sockets.removeFirst() }
    }
}

private final class DirectOutputControllerSocket: GPTLiveWebSocket,
    @unchecked Sendable {
    private let lock = NSLock()
    private var queue = [GPTLiveWebSocketMessage]()
    private var waiters = [CheckedContinuation<GPTLiveWebSocketMessage, Error>]()
    private var closed = false

    func open() async throws {}

    func receive() async throws -> GPTLiveWebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let message = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: GPTLiveSidebandError.closed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func send(_ text: String) async throws {}

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(throwing: GPTLiveSidebandError.closed)
        }
    }
}

private actor DirectControllerCredentialAdmission {
    enum Event: Equatable, Sendable { case refresh, load }

    private(set) var events: [Event] = []

    func record(_ event: Event) { events.append(event) }
}

private final class DirectControllerConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values = [GPTLiveConfiguration]()

    func record(_ configuration: GPTLiveConfiguration) {
        lock.withLock { values.append(configuration) }
    }
}

@MainActor
private final class DirectControllerPeer: LiveAudioPeer {
    enum Operation: Equatable { case prepare, answer, response, close }
    private(set) var operations: [Operation] = []
    private let failPrepare: Bool

    nonisolated init(failPrepare: Bool = false) {
        self.failPrepare = failPrepare
    }

    func prepareOffer() async throws -> String {
        if failPrepare { throw DirectControllerPeerFailure.prepare }
        operations.append(.prepare)
        return directControllerSyntheticOffer
    }

    func applyAnswerAndWaitForConnected(_ answer: String) async throws {
        operations.append(.answer)
    }

    func requestResponse() async throws { operations.append(.response) }
    func setMuted(_ muted: Bool) async throws {}
    func close() async { operations.append(.close) }
}

private enum DirectControllerPeerFailure: Error {
    case prepare
}

private let directControllerSyntheticOffer = """
v=0\r
o=- 0 0 IN IP4 0.0.0.0\r
s=-\r
t=0 0\r
a=group:BUNDLE 0 1\r
m=audio 9 UDP/TLS/RTP/SAVPF 111\r
a=mid:0\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r
a=setup:actpass\r
a=rtpmap:111 opus/48000/2\r
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
a=mid:1\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r
a=setup:actpass\r
a=sctp-port:5000\r
a=max-message-size:262144\r
"""

private final class DirectControllerLoader: GPTLiveURLLoading, @unchecked Sendable {
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            Data("v=0\r\ns=-\r\n".utf8),
            HTTPURLResponse(
                url: URL(string: "https://api.openai.com/v1/live")!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Location": "/v1/live/rtc_controller"]
            )!
        )
    }
}

private final class DirectControllerSocket: GPTLiveWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<GPTLiveWebSocketMessage, Error>] = []
    private var closed = false

    func open() async throws {}

    func receive() async throws -> GPTLiveWebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: GPTLiveSidebandError.closed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func send(_ text: String) async throws {}

    func close() {
        lock.lock()
        closed = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(throwing: GPTLiveSidebandError.closed) }
    }
}

@MainActor
private final class DirectControllerStateProbe {
    private(set) var values: [LiveVoiceState] = []
    func append(_ value: LiveVoiceState) { values.append(value) }
    func contains(_ value: LiveVoiceState) -> Bool { values.contains(value) }
    var valuesSnapshot: [LiveVoiceState] { values }
}

private func waitUntilDirectController(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @MainActor @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await MainActor.run(body: predicate) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DirectControllerTimeout()
}

private func waitUntilDirectControllerAsync(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DirectControllerTimeout()
}

private struct DirectControllerTimeout: Error {}

private struct DirectControllerRefreshFailure: Error {}

private actor DirectControllerCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor DirectControllerRefreshGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DirectControllerCompletionProbe {
    private(set) var completed = false
    func complete() { completed = true }
}

private actor DirectControllerLeaseOrderProbe {
    private(set) var wakeLeaseAcquired = false
    private(set) var endCompleted = false

    func recordEnd(wakeLeaseAcquired: Bool) {
        self.wakeLeaseAcquired = wakeLeaseAcquired
        endCompleted = true
    }
}
