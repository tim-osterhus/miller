import AppKit
import Combine
import Darwin
import Foundation
import MillerCore
import MillerGateway
import MillerLive
import MillerLiveAudio
import Testing
@testable import MillerApp

private let acceptingLiveHelperVerifier: @Sendable (URL) throws -> Void = { _ in }

private final class SpawnedProcessVerifierProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedPID: pid_t?

    var pid: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return observedPID
    }

    func record(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        observedPID = pid
    }
}

@Suite(.serialized)
@MainActor
struct GPTLivePresentationTests {
    @Test
    func transcriptPersistenceFailureIsPresentedWithoutEndingLiveMedia() async {
        let recorder = LiveVoiceTranscriptRecorder(
            persistence: .init(
                savingEnabled: { true },
                nextSessionSavingEnabled: { true },
                restoreNextSessionSavingDefault: {},
                startSession: { _, _, _, _ in
                    throw SyntheticTranscriptPersistenceError.failed
                },
                appendEntry: { _, _, _, _, _, _ in },
                completeEntry: { _, _ in },
                finalizeSession: { _, _ in },
                recoverInterruptedSessions: {}
            )
        )
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: .unavailable,
            liveTranscriptRecorder: recorder
        )

        await model.applyLiveEvent(.sessionAdmitted(id: UUID()))
        await model.applyLiveEvent(.state(.listening))

        #expect(model.voiceState == .listening)
        #expect(model.voiceStatusText == "Transcript could not be saved")
    }

    @Test
    func ordinaryModeRemainsTextOnlyAndVoiceUnavailable() {
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: .unavailable
        )

        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)
        #expect(model.canSubmit == false)
    }

    @Test
    func selectedProviderChangesRefreshVoiceAvailabilityInBothDirections() async {
        let codexID = UUID()
        let deepSeekID = UUID()
        let probe = LiveReadinessMutationProbe(
            initialAvailability: .unavailable,
            codexID: codexID
        )
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(
                initialAvailability: .unavailable
            )
        )

        await model.selectProvider(codexID)

        #expect(model.voiceState == .available)
        #expect(model.canStartLiveVoice)

        await model.selectProvider(deepSeekID)

        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 2)
    }

    @Test
    func savingSelectedOpenAICompatibleProfileMakesVoiceUnavailable() async {
        let probe = LiveReadinessMutationProbe(initialAvailability: .available)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(initialAvailability: .available)
        )

        await model.saveOpenAICompatibleProfile(
            label: "DeepSeek",
            endpoint: "https://example.invalid",
            model: "deepseek-chat",
            apiKey: "synthetic"
        )

        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test
    func successfulCodexLoginMakesVoiceAvailableWithoutRelaunch() async {
        let probe = LiveReadinessMutationProbe(initialAvailability: .unavailable)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(
                initialAvailability: .unavailable
            )
        )

        await model.prepareCodexLogin()

        #expect(model.voiceState == .available)
        #expect(model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test
    func successfulCredentialRefreshMakesVoiceAvailableWithoutRelaunch() async {
        let probe = LiveReadinessMutationProbe(initialAvailability: .unavailable)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(
                initialAvailability: .unavailable
            )
        )

        await model.refreshCodexAuthentication()

        #expect(model.voiceState == .available)
        #expect(model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test(arguments: LiveReadinessRemoval.allCases)
    fileprivate func credentialAndProfileRemovalMakesVoiceUnavailableWithoutRelaunch(
        removal: LiveReadinessRemoval
    ) async {
        let probe = LiveReadinessMutationProbe(initialAvailability: .available)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(initialAvailability: .available)
        )

        switch removal {
        case .logout:
            await model.localProviderLogout()
        case .delete:
            await model.deleteProvider(UUID())
        case .reset:
            await model.resetMiller()
        }

        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test(arguments: FailingReadinessMutation.allCases)
    fileprivate func failedProviderMutationsRefreshWithoutFalseTransition(
        mutation: FailingReadinessMutation
    ) async {
        let probe = LiveReadinessMutationProbe(
            initialAvailability: .available,
            failingMutation: mutation
        )
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(initialAvailability: .available)
        )

        switch mutation {
        case .saveOpenAICompatible:
            await model.saveOpenAICompatibleProfile(
                label: "DeepSeek",
                endpoint: "https://example.invalid",
                model: "deepseek-chat",
                apiKey: "synthetic"
            )
        case .select:
            await model.selectProvider(UUID())
        case .login:
            await model.prepareCodexLogin()
        case .refresh:
            await model.refreshCodexAuthentication()
        case .logout:
            await model.localProviderLogout()
        case .delete:
            await model.deleteProvider(UUID())
        }

        #expect(model.voiceState == .available)
        #expect(model.canStartLiveVoice)
        #expect(model.providerStatus == mutation.failureStatus)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test(arguments: FailingReadinessMutation.allCases)
    fileprivate func partialProviderMutationFailuresRefreshChangedReadiness(
        mutation: FailingReadinessMutation
    ) async {
        let initial: LiveVoiceState = mutation.resultingAvailability == .available
            ? .unavailable : .available
        let probe = LiveReadinessMutationProbe(
            initialAvailability: initial,
            failingMutation: mutation,
            mutateBeforeFailure: true
        )
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(initialAvailability: initial)
        )

        switch mutation {
        case .saveOpenAICompatible:
            await model.saveOpenAICompatibleProfile(
                label: "DeepSeek",
                endpoint: "https://example.invalid",
                model: "deepseek-chat",
                apiKey: "synthetic"
            )
        case .select:
            await model.selectProvider(UUID())
        case .login:
            await model.prepareCodexLogin()
        case .refresh:
            await model.refreshCodexAuthentication()
        case .logout:
            await model.localProviderLogout()
        case .delete:
            await model.deleteProvider(UUID())
        }

        #expect(model.voiceState == mutation.resultingAvailability)
        #expect(
            model.canStartLiveVoice
                == (mutation.resultingAvailability == .available)
        )
        #expect(model.providerStatus == mutation.failureStatus)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test(arguments: PartialSnapshotMutation.allCases)
    fileprivate func partialProviderCommitReloadsSnapshotAndPreservesFailureText(
        mutation: PartialSnapshotMutation
    ) async {
        let probe = PartialProviderSnapshotProbe(mutation: mutation)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies(),
            liveVoice: LiveVoiceDependencies(
                initialAvailability: .unavailable,
                availability: { .unavailable },
                start: { _ in },
                mute: { _ in },
                interrupt: {},
                end: {}
            )
        )
        await model.refreshProviderSettings()

        await perform(mutation, on: model)

        #expect(model.providerProfiles == probe.committedSnapshot.profiles)
        #expect(model.providerProfiles.filter(\.isSelected).count == 1)
        #expect(model.providerProfiles.first?.label == mutation.committedLabel)
        #expect(model.providerStatus == mutation.failureStatus)
        #expect(await probe.loadCalls == 2)
    }

    @Test
    func olderStartupProviderLoadCannotOverwriteMutationSnapshot() async throws {
        let probe = ProviderSnapshotGenerationProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies()
        )
        let startup = Task { await model.refreshProviderSettings() }
        try await waitUntil { await probe.firstLoadEntered }

        await model.selectProvider(UUID())

        #expect(model.providerProfiles == probe.mutationSnapshot.profiles)
        #expect(model.providerStatus == probe.mutationSnapshot.readiness)
        await probe.releaseFirstLoad()
        await startup.value
        #expect(model.providerProfiles == probe.mutationSnapshot.profiles)
        #expect(model.providerStatus == probe.mutationSnapshot.readiness)
    }

    @Test(arguments: StandaloneProviderStatusTransition.allCases)
    fileprivate func standaloneProviderStatusOwnsGenerationAgainstStartupLoad(
        transition: StandaloneProviderStatusTransition
    ) async throws {
        let probe = StandaloneProviderStatusProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies()
        )
        let startup = Task { await model.refreshProviderSettings() }
        try await waitUntil { await probe.loadEntered }

        switch transition {
        case .activeRefusal:
            await model.applyLiveEvent(.state(.listening))
            await model.selectProvider(UUID())
            await model.applyLiveEvent(.state(.closed))
        case .endpointValidation:
            await model.saveOpenAICompatibleProfile(
                label: "Rejected",
                endpoint: "http://example.invalid",
                model: "fixture-model",
                apiKey: "synthetic"
            )
        }

        #expect(model.providerStatus == transition.expectedStatus)
        await probe.releaseLoad()
        await startup.value
        #expect(model.providerStatus == transition.expectedStatus)
        #expect(model.providerProfiles.isEmpty)
    }

    @Test(arguments: ActiveProviderMutationInterference.allCases)
    fileprivate func activeProviderMutationRetainsSnapshotOwnership(
        interference: ActiveProviderMutationInterference
    ) async throws {
        let probe = ActiveProviderMutationOwnershipProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies()
        )
        let mutation = Task { await model.selectProvider(UUID()) }
        try await waitUntil { await probe.mutationEntered }

        switch interference {
        case .ordinaryRefresh:
            await model.refreshProviderSettings()
        case .refusedMutation:
            await model.deleteProvider(UUID())
        }

        await probe.releaseMutation()
        await mutation.value
        #expect(model.providerProfiles == probe.committedSnapshot.profiles)
        #expect(model.providerStatus == probe.committedSnapshot.readiness)
    }

    @Test(arguments: ResetSnapshotOutcome.allCases)
    fileprivate func resetReloadsAuthoritativeSnapshotAndPreservesResult(
        outcome: ResetSnapshotOutcome
    ) async {
        let probe = ResetSnapshotProbe(outcome: outcome)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies(),
            liveVoice: LiveVoiceDependencies(
                initialAvailability: .unavailable,
                availability: { .unavailable },
                start: { _ in },
                mute: { _ in },
                interrupt: {},
                end: {}
            )
        )
        await model.refreshProviderSettings()

        await model.resetMiller()

        #expect(model.providerProfiles == probe.committedSnapshot.profiles)
        #expect(
            model.providerProfiles.filter(\.isSelected).count
                == outcome.expectedSelectedProfiles
        )
        #expect(model.resetResults == probe.resetResult.roots)
        #expect(model.providerStatus == outcome.status)
        #expect(await probe.loadCalls == 2)
    }

    @Test
    func resetClearsDeletedPresentationStateAndFailedProviderReload() async {
        let probe = ResetPresentationStateProbe()
        let model = AppPresentationModel(
            dependencies: probe.hostDependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        await model.refreshProviderSettings()
        await model.refresh()
        await model.selectConversation(probe.conversationID)
        model.draft = "cause typed failure"
        await model.submit()
        model.draft = "stale draft"
        await model.applyLiveEvent(.state(.listening))
        await model.applyLiveEvent(.transcriptDone(role: .user, text: "stale user"))
        await model.applyLiveEvent(.transcriptDone(role: .assistant, text: "stale assistant"))
        await model.toggleLiveMute()
        await model.applyLiveEvent(.failed(code: "stale_live_failure"))

        await model.resetMiller()

        #expect(model.conversations.isEmpty)
        #expect(model.visibleTurns.isEmpty)
        #expect(model.selectedConversationID != probe.conversationID)
        #expect(model.draft.isEmpty)
        #expect(model.presentationState == .ready)
        #expect(model.errorCode == nil)
        #expect(model.providerProfiles.isEmpty)
        #expect(model.codexModels.isEmpty)
        #expect(model.codexDefaultModel.isEmpty)
        #expect(model.liveTranscriptTurns.isEmpty)
        #expect(model.liveVoiceFailureCode == nil)
        #expect(!model.liveVoiceMuted)
        #expect(model.voiceState == .unavailable)
        #expect(model.providerStatus == "Reset completed; secure erasure is not claimed.")
    }

    @Test(arguments: StaleConversationProjection.allCases)
    fileprivate func resetInvalidatesOlderConversationProjectionLoad(
        projection: StaleConversationProjection
    ) async throws {
        let probe = ConversationProjectionResetProbe(projection: projection)
        let model = AppPresentationModel(
            dependencies: probe.hostDependencies(),
            providerSettings: await probe.providerDependencies()
        )
        let staleRefresh = Task { await model.refresh() }
        try await waitUntil { await probe.staleLoadEntered }

        await model.resetMiller()

        #expect(model.conversations.isEmpty)
        #expect(model.visibleTurns.isEmpty)
        await probe.releaseStaleLoad()
        await staleRefresh.value
        #expect(model.conversations.isEmpty)
        #expect(model.visibleTurns.isEmpty)
    }

    @Test
    func activeLiveOperationFencesReadinessChangingMutations() async {
        let probe = LiveReadinessMutationProbe(initialAvailability: .unavailable)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies(initialAvailability: .listening)
        )

        await model.selectProvider(UUID())
        await model.prepareCodexLogin()
        await model.refreshCodexAuthentication()
        await model.localProviderLogout()
        await model.deleteProvider(UUID())
        await model.resetMiller()

        #expect(model.voiceState == .listening)
        #expect(await probe.mutationCalls == 0)
        #expect(await probe.availabilityCalls == 0)
    }

    @Test
    func startLiveVoiceUsesOneAuthoritativeAdmissionLoad() async {
        let probe = StartAdmissionProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.dependencies()
        )

        await model.startLiveVoice()

        #expect(model.voiceState == .failed)
        #expect(!model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 0)
        #expect(await probe.credentialLoads == 1)
    }

    @Test(arguments: LiveTerminalOutcome.allCases)
    fileprivate func liveTerminalCleanupRechecksInvalidatedCredentialBeforeRestart(
        outcome: LiveTerminalOutcome
    ) async throws {
        let probe = TerminalReadinessProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.dependencies()
        )
        let run = Task { await model.startLiveVoice() }
        try await waitUntil {
            let listening = await MainActor.run { model.voiceState == .listening }
            let ready = await probe.readyForFinish
            return listening && ready
        }

        await probe.finish(outcome, availability: .unavailable)
        await run.value

        #expect(model.voiceState == outcome.voiceState)
        #expect(!model.canStartLiveVoice)

        await probe.setAvailability(.available)
        await model.refreshLiveVoiceAvailability()

        #expect(model.voiceState == outcome.voiceState)
        #expect(model.canStartLiveVoice)
    }

    @Test
    func interruptedLiveCleanupRechecksRevokedPermissionBeforeRestart() async throws {
        let probe = TerminalReadinessProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.dependencies()
        )
        let run = Task { await model.startLiveVoice() }
        try await waitUntil {
            let listening = await MainActor.run { model.voiceState == .listening }
            let ready = await probe.readyForFinish
            return listening && ready
        }

        await probe.setAvailability(.unavailable)
        await model.interruptLiveVoice()
        await run.value

        #expect(model.voiceState == .stopped)
        #expect(!model.canStartLiveVoice)

        await probe.setAvailability(.available)
        await model.refreshLiveVoiceAvailability()

        #expect(model.voiceState == .stopped)
        #expect(model.canStartLiveVoice)
    }

    @Test
    func overlayShowRefreshesReadinessBeforePresentingStaleStart() async throws {
        let probe = LiveReadinessMutationProbe(initialAvailability: .unavailable)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.liveDependencies(initialAvailability: .available)
        )
        let controller = OverlayPanelController(model: model)

        controller.show()
        try await waitUntil {
            let applied = await MainActor.run {
                model.voiceState == .unavailable && !model.canStartLiveVoice
            }
            return await probe.availabilityCalls == 1 && applied
        }

        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)
        controller.window?.orderOut(nil)
    }

    @Test(arguments: StaleReadinessScenario.allCases)
    fileprivate func olderReadinessRequestCannotOverwriteNewerAuthority(
        scenario: StaleReadinessScenario
    ) async throws {
        let probe = OrderedReadinessProbe(scenario: scenario)
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        let olderRefresh = Task { await model.refreshLiveVoiceAvailability() }
        try await waitUntil { await probe.firstAvailabilityEntered }

        switch scenario {
        case .providerMutation:
            await model.selectProvider(UUID())
        case .admissionFailure, .terminal:
            await model.startLiveVoice()
        }

        #expect(!model.canStartLiveVoice)
        await probe.releaseFirstAvailability()
        await olderRefresh.value

        #expect(!model.canStartLiveVoice)
        #expect(model.voiceState == scenario.expectedVoiceState)
        #expect(await probe.availabilityCalls == scenario.expectedAvailabilityCalls)
    }

    @Test
    func rejectedOrdinaryRefreshCannotSupersedePrivilegedTypedFailureRefresh() async throws {
        let probe = PrivilegedReadinessProbe()
        let model = AppPresentationModel(
            dependencies: probe.hostDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        model.draft = "fail after admission"
        let submission = Task { await model.submit() }
        try await waitUntil { await probe.availabilityEntered }

        await model.refreshLiveVoiceAvailability()

        #expect(await probe.availabilityCalls == 1)
        await probe.releaseAvailability()
        await submission.value
        #expect(model.voiceState == .available)
        #expect(model.canStartLiveVoice)
    }

    @Test(arguments: TypedTerminalOutcome.allCases)
    fileprivate func typedTerminalRecomputesVoiceReadiness(
        outcome: TypedTerminalOutcome
    ) async throws {
        let turnID = TurnID()
        let gate = TypedTurnGate(turn: typedTurn(id: turnID, outcome: outcome))
        let probe = LiveReadinessMutationProbe(initialAvailability: .available)
        let model = AppPresentationModel(
            dependencies: HostDependencies(
                submit: { _, _ in turnID },
                stop: {},
                loadTurn: { _ in await gate.load() },
                loadConversations: { [] },
                loadTurns: { _ in [] },
                archive: { _ in },
                unarchive: { _ in },
                delete: { _ in }
            ),
            liveVoice: await probe.liveDependencies(initialAvailability: .available)
        )
        model.draft = "typed"

        await model.submit()
        try await waitUntil { await gate.entered }

        #expect(model.isActiveTurn)
        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)

        await gate.release()
        try await waitUntil {
            let terminal = await MainActor.run { !model.isActiveTurn }
            let refreshed = await probe.availabilityCalls == 1
            return terminal && refreshed
        }

        #expect(model.voiceState == .available)
        #expect(model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test
    func stoppingTypedOperationRecomputesVoiceReadiness() async {
        let probe = LiveReadinessMutationProbe(initialAvailability: .available)
        let model = AppPresentationModel(
            dependencies: dependencies(loadTurn: { _ in nil }),
            liveVoice: await probe.liveDependencies(initialAvailability: .available)
        )
        model.draft = "typed"

        await model.submit()

        #expect(model.isActiveTurn)
        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)

        await model.stop()

        #expect(!model.isActiveTurn)
        #expect(model.voiceState == .available)
        #expect(model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test
    func terminalReadinessCacheChangeNotifiesObserversWithoutErasingStatus() async {
        let probe = TerminalReadinessProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.dependencies()
        )
        await model.applyLiveEvent(.failed(code: "voice_failed"))
        await probe.setAvailability(.unavailable)
        let notifications = ChangeCounter()
        let observation = model.objectWillChange.sink { notifications.record() }

        await model.refreshLiveVoiceAvailability()

        #expect(notifications.value == 1)
        #expect(model.voiceState == .failed)
        #expect(model.voiceStatusText == "Failed (voice_failed)")
        #expect(!model.canStartLiveVoice)
        withExtendedLifetime(observation) {}
    }

    @Test
    func invalidatedSelectedCredentialRefusesAvailabilityAndStartBeforeLoading() async throws {
        let reference = UUID()
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: reference,
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let invalidation = CredentialInvalidationProbe(invalidated: true)
        let credentialLoads = SubmitProbe()
        let controller = try GPTLiveController(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp"),
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await credentialLoads.record()
                return envelope
            }),
            credentialInvalidated: { reference in
                await invalidation.isInvalidated(reference: reference)
            },
            refreshCredential: {},
            microphonePermissionStatus: { .authorized },
            microphonePermission: { .authorized },
            helperVerifier: acceptingLiveHelperVerifier
        )

        #expect(await controller.availability() == .unavailable)
        await #expect(throws: GPTLiveCredentialError.unavailable) {
            try await controller.start { _ in }
        }
        #expect(await credentialLoads.calls == 0)

        await invalidation.setInvalidated(false)

        #expect(await controller.availability() == .available)
        #expect(await credentialLoads.calls == 1)
    }

    @Test(arguments: CredentialAuthorityRaceCase.all)
    fileprivate func liveStartRevalidatesAuthorityAtSuspensionBoundary(
        testCase: CredentialAuthorityRaceCase
    ) async throws {
        let probe = try GPTLiveAuthorityRaceProbe(testCase: testCase)
        let controller = try GPTLiveController(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp"),
            selectedProfile: { await probe.selectedProfile() },
            credentialLoader: GPTLiveCredentialLoader(load: { reference in
                try await probe.loadCredential(reference: reference)
            }),
            credentialInvalidated: { reference in
                await probe.isInvalidated(reference: reference)
            },
            refreshCredential: {},
            microphonePermissionStatus: { .authorized },
            microphonePermission: { await probe.microphonePermission() },
            helperVerifier: acceptingLiveHelperVerifier
        )
        let start = Task<GPTLiveCredentialError?, Never> {
            do {
                try await controller.start { _ in }
                return nil
            } catch let error as GPTLiveCredentialError {
                return error
            } catch {
                return nil
            }
        }
        try await waitUntil { await probe.suspensionEntered }

        await probe.changeAuthority()
        await probe.releaseSuspension()

        #expect(await start.value == .unavailable)
        #expect(await probe.credentialLoads == testCase.expectedCredentialLoads)
    }

    @Test(arguments: CredentialAuthorityChange.allCases)
    fileprivate func availabilityRevalidatesAuthorityAfterCredentialLoad(
        change: CredentialAuthorityChange
    ) async throws {
        let testCase = CredentialAuthorityRaceCase(
            suspension: .credentialLoad,
            change: change
        )
        let probe = try GPTLiveAuthorityRaceProbe(testCase: testCase)
        let controller = try GPTLiveController(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp"),
            selectedProfile: { await probe.selectedProfile() },
            credentialLoader: GPTLiveCredentialLoader(load: { reference in
                try await probe.loadCredential(reference: reference)
            }),
            credentialInvalidated: { reference in
                await probe.isInvalidated(reference: reference)
            },
            refreshCredential: {},
            microphonePermissionStatus: { .authorized },
            microphonePermission: { .authorized },
            helperVerifier: acceptingLiveHelperVerifier
        )
        let availability = Task { await controller.availability() }
        try await waitUntil { await probe.suspensionEntered }

        await probe.changeAuthority()
        await probe.releaseSuspension()

        #expect(await availability.value == .unavailable)
        #expect(await probe.credentialLoads == 1)
    }

    @Test
    func suspendedTypedSubmitFencesLiveAndEveryProviderMutationUntilTurnHandoff() async throws {
        let probe = TypedSubmissionRaceProbe()
        let model = AppPresentationModel(
            dependencies: await probe.hostDependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        model.draft = "typed"
        let submission = Task { await model.submit() }
        try await waitUntil { await probe.submitEntered }

        #expect(model.draft.isEmpty)
        #expect(model.presentationState == .waiting)
        #expect(model.activeTurnID == nil)
        #expect(model.isActiveOperation)
        #expect(model.menuState.canStop)
        #expect(!model.canSubmit)
        #expect(!model.canStartLiveVoice)

        for mutation in ProviderMutationAttempt.allCases {
            await perform(mutation, on: model)
        }
        await model.startLiveVoice()

        #expect(await probe.liveStarts == 0)
        #expect(await probe.providerMutationCalls == 0)
        #expect(await probe.activeFlags.isEmpty)

        await probe.releaseSubmit()
        await submission.value

        #expect(model.activeTurnID == probe.turnID)
        #expect(model.isActiveOperation)
        #expect(!model.canStartLiveVoice)
    }

    @Test
    func failedSuspendedTypedSubmitClearsFenceAndRecomputesReadiness() async throws {
        let probe = TypedSubmissionRaceProbe(submitFails: true)
        let model = AppPresentationModel(
            dependencies: await probe.hostDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        model.draft = "typed"
        let submission = Task { await model.submit() }
        try await waitUntil { await probe.submitEntered }

        await probe.revokeAvailability()
        await probe.releaseSubmit()
        await submission.value

        #expect(model.draft.isEmpty)
        #expect(model.presentationState == .failed)
        #expect(model.activeTurnID == nil)
        #expect(!model.isActiveOperation)
        #expect(model.voiceState == .unavailable)
        #expect(!model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test(arguments: FastTerminalReadinessCase.all)
    fileprivate func fastTypedTerminalHandoffRecomputesReadinessExactlyOnce(
        testCase: FastTerminalReadinessCase
    ) async throws {
        let probe = FastTypedTerminalProbe(testCase: testCase)
        let model = AppPresentationModel(
            dependencies: await probe.hostDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        model.draft = "typed"
        let submission = Task { await model.submit() }
        try await waitUntil { await probe.initialRefreshEntered }
        try await waitUntil {
            let reachedRefresh = await probe.terminalRefreshReachedLoadTurns
            let clearedTurn = await MainActor.run { model.activeTurnID == nil }
            return reachedRefresh && clearedTurn
        }
        try await Task.sleep(for: .milliseconds(10))

        #expect(model.presentationState == testCase.outcome.presentationState)
        #expect(!model.isActiveOperation)
        #expect(await probe.availabilityCalls == 1)

        await probe.releaseInitialRefresh()
        await submission.value

        #expect(await probe.availabilityCalls == 1)
        #expect(model.voiceState == testCase.availability)
        #expect(model.canStartLiveVoice == (testCase.availability == .available))
    }

    @Test(arguments: SuspendedProviderMutation.allCases)
    fileprivate func suspendedProviderMutationFencesLiveAdmission(
        mutation: SuspendedProviderMutation
    ) async throws {
        let probe = ProviderMutationRaceProbe(suspended: mutation)
        let submits = SubmitProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        model.draft = "typed"
        let operation = Task { await perform(mutation, on: model) }
        try await waitUntil { await probe.entered }

        #expect(model.isActiveOperation)
        #expect(!model.canStartLiveVoice)
        await model.startLiveVoice()
        await model.submit()
        #expect(await probe.liveStarts == 0)
        #expect(await submits.calls == 0)

        await probe.release()
        await operation.value

        #expect(await probe.commits == 1)
        #expect(await probe.activeFlags == mutation.expectedActiveFlags)
        #expect(!model.isActiveOperation)
    }

    @Test
    func providerMutationFenceClearsAfterThrow() async throws {
        let probe = ProviderMutationRaceProbe(
            suspended: .select,
            throwsAfterRelease: true
        )
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.providerDependencies(),
            liveVoice: await probe.liveDependencies()
        )
        let operation = Task { await model.selectProvider(UUID()) }
        try await waitUntil { await probe.entered }

        #expect(model.isActiveOperation)
        await probe.release()
        await operation.value

        #expect(!model.isActiveOperation)
        #expect(model.canStartLiveVoice)
    }

    @Test(arguments: LiveCleanupAction.allCases)
    fileprivate func detachedLiveCleanupExplicitlyRefreshesReadiness(
        action: LiveCleanupAction
    ) async {
        let probe = DetachedCleanupReadinessProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.dependencies()
        )
        await model.startLiveVoice()

        switch action {
        case .interrupt:
            await model.interruptLiveVoice()
        case .end:
            await model.endLiveVoice()
        }

        #expect(model.voiceState == action.voiceState)
        #expect(!model.canStartLiveVoice)
        #expect(await probe.availabilityCalls == 1)
    }

    @Test
    func harnessArgumentRequiresOneAbsoluteHelperPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-live-helper-argument-\(UUID().uuidString.lowercased())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root)
        #expect(chmod(root.path, 0o700) == 0)

        #expect(try AppCoordinator.liveHelperURL(arguments: ["Miller"]) == nil)
        #expect(
            try AppCoordinator.liveHelperURL(arguments: [
                "Miller", "--gpt-live-app-server", root.path,
            ], helperVerifier: acceptingLiveHelperVerifier)?.path == root.path
        )
        #expect(throws: LiveProcessError.invalidConfiguration) {
            try AppCoordinator.liveHelperURL(arguments: [
                "Miller", "--gpt-live-app-server", "relative-helper",
            ])
        }
        #expect(throws: LiveProcessError.invalidConfiguration) {
            try AppCoordinator.liveHelperURL(arguments: [
                "Miller", "--gpt-live-app-server",
            ])
        }
    }

    @Test
    func appServerProcessConfigurationUsesExactStdioInvocation() throws {
        let helperURL = URL(fileURLWithPath: "/usr/bin/true")
        let temporaryParentURL = URL(fileURLWithPath: "/private/tmp")

        let configuration = try GPTLiveController.processConfiguration(
            helperURL: helperURL,
            temporaryParentURL: temporaryParentURL
        )

        #expect(configuration.executableURL == helperURL)
        #expect(configuration.arguments == [
            "app-server", "--listen", "stdio://", "--strict-config",
        ])
        #expect(configuration.temporaryParentURL == temporaryParentURL)
    }

    @Test
    func appServerProcessConfigurationCarriesItsSpawnedProcessVerifier() throws {
        let probe = SpawnedProcessVerifierProbe()
        let configuration = try GPTLiveController.processConfiguration(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: URL(fileURLWithPath: "/private/tmp"),
            spawnedProcessVerifier: { pid in probe.record(pid) }
        )

        try configuration.spawnedProcessVerifier(4242)

        #expect(probe.pid == 4242)
    }

    @Test
    func defaultLiveSessionFailsClosedBeforeLaunchingTheHelper() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/default-live-session-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(at: temporaryParent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryParent) }
        let launchMarker = temporaryParent.appendingPathComponent("helper-launched")
        let helper = temporaryParent.appendingPathComponent("fake-helper")
        try Data("#!/bin/sh\nprintf launched > \(launchMarker.path)\n".utf8).write(to: helper)
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
        let controller = try GPTLiveController(
            helperURL: helper,
            temporaryParentURL: temporaryParent,
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            helperVerifier: acceptingLiveHelperVerifier
        )

        await #expect(throws: LiveAudioPeerError.unavailable) {
            try await controller.dependencies().start { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
    }

    @Test
    func attachedPeerFactoryOwnsTheWebRTCSessionAndReleasesItAfterEnd() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/attached-peer-factory-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent,
            withIntermediateDirectories: true
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
        let lifecycle = AttachedPeerFactoryProbe()
        let controller = try GPTLiveController(
            helperURL: helper,
            temporaryParentURL: temporaryParent,
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            makePeer: { await lifecycle.makePeer() },
            releasePeer: { await lifecycle.releasePeer() },
            helperVerifier: acceptingLiveHelperVerifier,
            spawnedProcessVerifier: { _ in }
        )
        let base = controller.dependencies()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: LiveVoiceDependencies(
                initialAvailability: .available,
                availability: base.availability,
                start: base.start,
                mute: base.mute,
                interrupt: base.interrupt,
                end: base.end
            )
        )

        let run = Task { await model.startLiveVoice() }
        try await waitUntil { await MainActor.run { model.voiceState == .listening } }
        await model.endLiveVoice()
        await run.value

        // A completed call must release the overlay-owned peer before a new
        // Start action asks the factory for a different WebRTC peer.
        let secondRun = Task { await model.startLiveVoice() }
        try await waitUntil { await MainActor.run { model.voiceState == .listening } }
        await model.endLiveVoice()
        await secondRun.value
        await controller.shutdown()

        #expect(await lifecycle.created == 2)
        #expect(await lifecycle.released == 2)
        #expect(model.voiceState == .closed)
    }

    @Test
    func activeLiveSessionRefusesTypedSubmitAndRestoresItAfterEnd() async {
        let probe = VoiceProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.dependencies()
        )
        model.draft = "typed"

        await model.startLiveVoice()
        await model.submit()

        #expect(model.voiceState == .listening)
        #expect(!model.canSubmit)
        #expect(await probe.starts == 1)

        await model.endLiveVoice()

        #expect(model.voiceState == .closed)
        #expect(model.canSubmit)
        #expect(await probe.ends == 1)
    }

    @Test
    func interruptKeepsTypedAndSecondLiveStartsFencedUntilFakeHelperCleanup() async throws {
        let submits = SubmitProbe()
        let voice = try FakeHelperVoiceProbe(testName: #function)
        defer { voice.cleanArtifacts() }
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            liveVoice: await voice.dependencies()
        )
        model.draft = "typed"
        let liveRun = Task { await model.startLiveVoice() }
        try await waitUntil { await MainActor.run { model.voiceState == .listening } }

        let interrupt = Task { await model.interruptLiveVoice() }
        try await waitUntil {
            let stopWasReceived = await voice.stopWasReceived
            let terminalWasPresented = await MainActor.run {
                model.voiceState == .closed
            }
            return stopWasReceived && terminalWasPresented
        }
        #expect(await voice.privateRootExists)

        await model.startLiveVoice()
        await model.submit()

        #expect(!model.canSubmit)
        #expect(!model.canStartLiveVoice)
        #expect(await submits.calls == 0)
        #expect(await voice.startAttempts == 1)

        await interrupt.value

        #expect(!(await voice.privateRootExists))
        #expect(model.voiceState == .stopped)
        #expect(model.canSubmit)
        await model.submit()
        #expect(await submits.calls == 1)
        await liveRun.value
    }

    @Test
    func endKeepsTypedAndSecondLiveStartsFencedUntilFakeHelperCleanup() async throws {
        let submits = SubmitProbe()
        let voice = try FakeHelperVoiceProbe(testName: #function)
        defer { voice.cleanArtifacts() }
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            liveVoice: await voice.dependencies()
        )
        model.draft = "typed"
        let liveRun = Task { await model.startLiveVoice() }
        try await waitUntil { await MainActor.run { model.voiceState == .listening } }

        let end = Task { await model.endLiveVoice() }
        try await waitUntil { await voice.stopWasReceived }
        #expect(await voice.privateRootExists)

        await model.startLiveVoice()
        await model.submit()

        #expect(!model.canSubmit)
        #expect(!model.canStartLiveVoice)
        #expect(await submits.calls == 0)
        #expect(await voice.startAttempts == 1)

        await end.value

        #expect(!(await voice.privateRootExists))
        #expect(model.voiceState == .closed)
        #expect(model.canSubmit)
        await model.submit()
        #expect(await submits.calls == 1)
        await liveRun.value
    }

    @Test
    func typedSubmitStaysRefusedAfterTerminalUntilFakeHelperCleanupFinishes() async throws {
        let submits = SubmitProbe()
        let voice = try FakeHelperVoiceProbe(
            testName: #function,
            mode: "hold-terminal-cleanup"
        )
        defer { voice.cleanArtifacts() }
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            liveVoice: await voice.dependencies()
        )
        model.draft = "typed"
        let liveRun = Task { await model.startLiveVoice() }
        try await waitUntil { await MainActor.run { model.voiceState == .listening } }

        let interrupt = Task { await model.interruptLiveVoice() }
        try await waitUntil { await voice.stopWasReceived }

        #expect(model.voiceState == .closed)
        #expect(await voice.privateRootExists)
        await model.submit()
        #expect(await submits.calls == 0)

        await interrupt.value
        #expect(!(await voice.privateRootExists))
        #expect(model.canSubmit)
        await model.submit()
        #expect(await submits.calls == 1)
        await liveRun.value
    }

    @Test
    func cleanupPendingIsSanitizedAndFencedUntilAutomaticRecovery() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/cleanup-pending-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent,
            withIntermediateDirectories: true
        )
        defer {
            _ = chmod(temporaryParent.path, 0o700)
            try? FileManager.default.removeItem(at: temporaryParent)
        }
        let fixture = repository.appendingPathComponent(
            "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
        )
        let helper = temporaryParent.appendingPathComponent("fake-helper")
        try Data(
            "#!/bin/sh\nexec /opt/homebrew/opt/node@22/bin/node \(fixture.path) wait-stop\n".utf8
        ).write(to: helper)
        #expect(chmod(helper.path, 0o700) == 0)
        let reference = UUID()
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: reference,
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let capture = PresentationNoAudioCaptureDriver()
        let playback = PresentationNoAudioPlaybackDriver()
        let controller = try GPTLiveController(
            helperURL: helper,
            temporaryParentURL: temporaryParent,
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            cleanupPendingDelay: .milliseconds(100),
            makeSession: { client in
                LiveAudioSession(
                    client: client,
                    peer: PresentationTestPeer(),
                    capture: LiveAudioCapture(driver: capture),
                    playback: LiveAudioPlayback(driver: playback)
                )
            },
            helperVerifier: acceptingLiveHelperVerifier,
            spawnedProcessVerifier: { _ in }
        )
        let submits = SubmitProbe()
        let base = controller.dependencies()
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            liveVoice: LiveVoiceDependencies(
                initialAvailability: .available,
                availability: base.availability,
                start: base.start,
                mute: base.mute,
                interrupt: base.interrupt,
                end: base.end
            )
        )
        model.draft = "typed"
        let liveRun = Task { await model.startLiveVoice() }
        try await waitUntil { await MainActor.run { model.voiceState == .listening } }

        #expect(chmod(temporaryParent.path, 0o500) == 0)
        let end = Task { await model.endLiveVoice() }
        try await waitUntil {
            await MainActor.run { model.liveVoiceFailureCode == "cleanup_pending" }
        }

        #expect(model.voiceState == .failed)
        #expect(model.isActiveOperation)
        #expect(!model.canSubmit)
        #expect(!model.canStartLiveVoice)
        await model.submit()
        await model.startLiveVoice()
        #expect(await submits.calls == 0)

        #expect(chmod(temporaryParent.path, 0o700) == 0)
        await end.value
        await liveRun.value
        #expect(!model.isActiveOperation)
        #expect(model.canSubmit)
        #expect(model.canStartLiveVoice)
        await model.submit()
        #expect(await submits.calls == 1)
        #expect(await capture.starts == 0)
        #expect(await playback.plays == 0)
        #expect(await playback.interrupts == 0)
    }

    @Test
    func mutePeerFailureStopsTheHelperAndPresentsATerminalFailure() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/mute-peer-failure-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryParent) }
        let marker = temporaryParent.appendingPathComponent("stops.txt")
        let fixture = repository.appendingPathComponent(
            "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
        )
        let helper = temporaryParent.appendingPathComponent("fake-helper")
        try Data(
            "#!/bin/sh\nexec /opt/homebrew/opt/node@22/bin/node \(fixture.path) stop-on-sdp \(marker.path)\n".utf8
        ).write(to: helper)
        #expect(chmod(helper.path, 0o700) == 0)
        let reference = UUID()
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: reference,
            isSelected: true
        )
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let peer = MuteFailurePresentationPeer()
        let controller = try GPTLiveController(
            helperURL: helper,
            temporaryParentURL: temporaryParent,
            selectedProfile: { profile },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
            refreshCredential: {},
            microphonePermission: { .authorized },
            makeSession: { client in LiveAudioSession(client: client, peer: peer) },
            helperVerifier: acceptingLiveHelperVerifier,
            spawnedProcessVerifier: { _ in }
        )
        let base = controller.dependencies()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: LiveVoiceDependencies(
                initialAvailability: .available,
                availability: base.availability,
                start: base.start,
                mute: base.mute,
                interrupt: base.interrupt,
                end: base.end
            )
        )

        let run = Task { await model.startLiveVoice() }
        try await waitUntil { await MainActor.run { model.voiceState == .listening } }
        await model.toggleLiveMute()
        await run.value

        #expect(model.voiceState == .failed)
        #expect(model.liveVoiceFailureCode == "voice_failed")
        #expect(peer.closeCalls == 1)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "stop\n")
        #expect(!model.isActiveOperation)
    }

    @Test
    func interruptDuringControllerStartupWaitsForDurableTermination() async throws {
        try await assertControllerStartupStopIsFenced(
            action: .interrupt,
            suspension: .selectedProfile
        )
    }

    @Test
    func endDuringControllerStartupWaitsForDurableTermination() async throws {
        try await assertControllerStartupStopIsFenced(
            action: .end,
            suspension: .selectedProfile
        )
    }

    @Test
    func interruptDuringPermissionSuspensionWaitsForDurableTermination() async throws {
        try await assertControllerStartupStopIsFenced(
            action: .interrupt,
            suspension: .permission
        )
    }

    @Test
    func endDuringCredentialSuspensionWaitsForDurableTermination() async throws {
        try await assertControllerStartupStopIsFenced(
            action: .end,
            suspension: .credential
        )
    }

    @Test
    func interruptPreservesFailurePresentedDuringCleanup() async throws {
        try await assertFailureDuringCleanupIsPreserved(action: .interrupt)
    }

    @Test
    func endPreservesFailurePresentedDuringCleanup() async throws {
        try await assertFailureDuringCleanupIsPreserved(action: .end)
    }

    @Test
    func spontaneousCloseFencesAdmissionsAndNewConversationUntilCleanup() async throws {
        let voice = SpontaneousTerminalProbe(terminal: .closed)
        let submits = SubmitProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            liveVoice: await voice.dependencies()
        )
        model.draft = "typed"
        let conversation = model.selectedConversationID
        let liveRun = Task { await model.startLiveVoice() }
        try await waitUntil { await voice.terminalWasPresented }

        #expect(model.voiceState == .closed)
        #expect(model.isActiveOperation)
        #expect(!model.canSubmit)
        #expect(!model.canStartLiveVoice)
        await model.submit()
        model.newConversation()
        #expect(await submits.calls == 0)
        #expect(model.selectedConversationID == conversation)
        #expect(model.draft == "typed")

        await voice.finishCleanup()
        await liveRun.value
        #expect(!model.isActiveOperation)
        #expect(model.canSubmit)
        await model.submit()
        #expect(await submits.calls == 1)
    }

    @Test
    func spontaneousFailureFencesAdmissionsAndAvailabilityUntilCleanup() async throws {
        let voice = SpontaneousTerminalProbe(terminal: .failed)
        let submits = SubmitProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            liveVoice: await voice.dependencies()
        )
        model.draft = "typed"
        let liveRun = Task { await model.startLiveVoice() }
        try await waitUntil { await voice.terminalWasPresented }

        await model.refreshLiveVoiceAvailability()
        #expect(model.voiceState == .failed)
        #expect(model.isActiveOperation)
        #expect(!model.canSubmit)
        #expect(!model.canStartLiveVoice)
        #expect(await voice.availabilityCalls == 0)
        await model.submit()
        #expect(await submits.calls == 0)

        await voice.finishCleanup()
        await liveRun.value
        #expect(model.voiceState == .failed)
        #expect(!model.isActiveOperation)
        #expect(await voice.availabilityCalls == 1)
        #expect(model.canSubmit)
        await model.submit()
        #expect(await submits.calls == 1)
    }

    @Test
    func muteInterruptAndBoundedTranscriptsRemainVoiceOnly() async {
        let probe = VoiceProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await probe.dependencies()
        )
        await model.startLiveVoice()
        await model.applyLiveEvent(.transcriptDelta(role: .user, text: "partial"))
        await model.applyLiveEvent(.transcriptDone(role: .assistant, text: "reply"))
        await model.toggleLiveMute()
        await model.interruptLiveVoice()

        #expect(model.liveTranscriptTurns.map(\.role) == [.user, .assistant])
        #expect(model.liveTranscriptTurns.map(\.text) == ["partial", "reply"])
        #expect(model.voiceState == .stopped)
        #expect(await probe.mutes == [true])
        #expect(await probe.interrupts == 1)
    }

    @Test
    func liveTranscriptTurnsRemainInConversationOrder() async {
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: .unavailable
        )

        await model.applyLiveEvent(.transcriptDelta(role: .user, text: "Hello Miller"))
        await model.applyLiveEvent(.transcriptDelta(role: .assistant, text: "Hel"))
        await model.applyLiveEvent(.transcriptDone(role: .user, text: "Hello Miller"))
        await model.applyLiveEvent(.transcriptDelta(role: .assistant, text: "lo!"))
        await model.applyLiveEvent(.transcriptDone(role: .assistant, text: "Hello!"))
        await model.applyLiveEvent(.transcriptDelta(role: .user, text: "Where did that "))
        await model.applyLiveEvent(.transcriptDelta(role: .user, text: "answer come from?"))
        await model.applyLiveEvent(.transcriptDelta(role: .assistant, text: "From the "))
        await model.applyLiveEvent(.transcriptDone(
            role: .user,
            text: "Where did that answer come from?"
        ))
        await model.applyLiveEvent(.transcriptDelta(role: .assistant, text: "session context."))
        await model.applyLiveEvent(.transcriptDone(
            role: .assistant,
            text: "From the session context."
        ))

        #expect(model.liveTranscriptTurns.map(\.role) == [
            .user,
            .assistant,
            .user,
            .assistant,
        ])
        #expect(model.liveTranscriptTurns.map(\.text) == [
            "Hello Miller",
            "Hello!",
            "Where did that answer come from?",
            "From the session context.",
        ])
    }

    @Test
    func staleTerminalFromAnEarlierLiveSessionCannotFailALaterSession() async throws {
        let voice = StaleLiveSessionEventProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await voice.dependencies()
        )

        let first = Task { await model.startLiveVoice() }
        try await waitUntil { await voice.sessionCount == 1 }
        await voice.emit(.state(.closed), from: 0)
        await voice.finish(session: 0)
        await first.value

        let second = Task { await model.startLiveVoice() }
        try await waitUntil { await voice.sessionCount == 2 }
        await voice.emit(.state(.listening), from: 1)
        await voice.emit(.failed(code: "stale_peer_loss"), from: 0)

        #expect(model.voiceState == .listening)
        #expect(model.liveVoiceFailureCode == nil)

        await voice.emit(.failed(code: "current_peer_loss"), from: 1)
        await voice.finish(session: 1)
        await second.value
        #expect(model.voiceState == .failed)
        #expect(model.liveVoiceFailureCode == "voice_failed")
    }

    @Test
    func startupFailuresExposeOnlyActionableSanitizedClasses() async {
        await assertSanitizedLiveStartFailure(
            CodexAppServerClientError.timeout,
            expectedCode: "voice_timeout"
        )
        await assertSanitizedLiveStartFailure(
            CodexAppServerClientError.credentialRejected,
            expectedCode: "credential_rejected"
        )
        await assertSanitizedLiveStartFailure(
            LiveProcessError.helperExited,
            expectedCode: "helper_failed"
        )
        await assertSanitizedLiveStartFailure(
            LiveProtocolError.unknownField,
            expectedCode: "protocol_mismatch"
        )
    }

    @Test
    func realtimeStartDiagnosticsExposeOnlyTheirFixedSanitizedCodes() async {
        let expected: [(CodexRealtimeStartDiagnostic, String)] = [
            (.rejected, "realtime_start_rejected"),
            (.failed, "realtime_start_failed"),
            (.closed, "realtime_start_closed"),
            (.decodeOrFrameMismatch, "protocol_realtime_decode_frame"),
            (.responseOrder, "protocol_realtime_response_order"),
            (.threadStartOrder, "protocol_realtime_thread_start_order"),
            (.startedOrderOrVersion, "protocol_realtime_started_order_version"),
            (.sdpOrderOrThread, "protocol_realtime_sdp_order_thread"),
            (.credentialRefresh, "protocol_realtime_credential_refresh"),
            (.outOfBand, "protocol_realtime_out_of_band"),
            (.other, "protocol_realtime_other"),
            (.eof, "protocol_realtime_eof"),
        ]
        for (diagnostic, code) in expected {
            await assertSanitizedLiveStartFailure(
                CodexAppServerClientError.realtimeStartDiagnostic(diagnostic),
                expectedCode: code
            )
        }
    }

    private func dependencies(
        submits: SubmitProbe? = nil,
        loadTurn: @escaping @Sendable (TurnID) async throws -> Turn? = { _ in nil }
    ) -> HostDependencies {
        HostDependencies(
            submit: { _, _ in
                await submits?.record()
                return TurnID()
            }, stop: {}, loadTurn: loadTurn,
            loadConversations: { [] }, loadTurns: { _ in [] }, archive: { _ in },
            unarchive: { _ in }, delete: { _ in }
        )
    }

    private func typedTurn(
        id: TurnID,
        outcome: TypedTerminalOutcome
    ) -> Turn {
        Turn(
            id: id,
            conversationID: ConversationID(),
            sequence: 1,
            inputMode: .text,
            userText: "typed",
            assistantText: outcome == .completed ? "done" : "",
            state: outcome.turnState,
            generation: 2,
            errorCode: outcome == .failed ? "synthetic_failure" : nil,
            errorMessage: outcome == .failed ? "Synthetic failure." : nil,
            startedAt: Date(),
            terminalAt: Date()
        )
    }

    private func perform(
        _ mutation: SuspendedProviderMutation,
        on model: AppPresentationModel
    ) async {
        switch mutation {
        case .save:
            await model.saveOpenAICompatibleProfile(
                label: "DeepSeek",
                endpoint: "https://example.invalid",
                model: "deepseek-chat",
                apiKey: "synthetic"
            )
        case .codexModel:
            await model.selectCodexModel("gpt-5.6-terra")
        case .select:
            await model.selectProvider(UUID())
        case .login:
            await model.prepareCodexLogin()
        case .refresh:
            await model.refreshCodexAuthentication()
        case .retry:
            await model.retryProviderReadiness()
        case .logout:
            await model.localProviderLogout()
        case .delete:
            await model.deleteProvider(UUID())
        case .reset:
            await model.resetMiller()
        }
    }

    private func perform(
        _ mutation: ProviderMutationAttempt,
        on model: AppPresentationModel
    ) async {
        switch mutation {
        case .save:
            await model.saveOpenAICompatibleProfile(
                label: "DeepSeek",
                endpoint: "https://example.invalid",
                model: "deepseek-chat",
                apiKey: "synthetic"
            )
        case .codexModel:
            await model.selectCodexModel("gpt-5.6-terra")
        case .select:
            await model.selectProvider(UUID())
        case .login:
            await model.prepareCodexLogin()
        case .refresh:
            await model.refreshCodexAuthentication()
        case .retry:
            await model.retryProviderReadiness()
        case .logout:
            await model.localProviderLogout()
        case .delete:
            await model.deleteProvider(UUID())
        case .reset:
            await model.resetMiller()
        }
    }

    private func perform(
        _ mutation: PartialSnapshotMutation,
        on model: AppPresentationModel
    ) async {
        switch mutation {
        case .save:
            await model.saveOpenAICompatibleProfile(
                label: "DeepSeek",
                endpoint: "https://example.invalid",
                model: "deepseek-chat",
                apiKey: "synthetic"
            )
        case .codexModel:
            await model.selectCodexModel("gpt-5.6-terra")
        case .select:
            await model.selectProvider(UUID())
        case .login:
            await model.prepareCodexLogin()
        case .refresh:
            await model.refreshCodexAuthentication()
        case .logout:
            await model.localProviderLogout()
        case .delete:
            await model.deleteProvider(UUID())
        }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw LiveProcessError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertSanitizedLiveStartFailure(
        _ error: any Error & Sendable,
        expectedCode: String
    ) async {
        let voice = LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { _ in throw error },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: voice
        )

        await model.startLiveVoice()

        #expect(model.voiceState == .failed)
        #expect(model.liveVoiceFailureCode == expectedCode)
    }

    private func assertControllerStartupStopIsFenced(
        action: StartupStopAction,
        suspension: StartupSuspension
    ) async throws {
        let reference = UUID()
        let profile = try ProviderProfile(
            kind: .codexOAuth,
            label: "Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: reference,
            isSelected: true
        )
        let selection = StartupProfileGate(profile: profile)
        let permission = StartupPermissionGate()
        let credential = StartupCredentialGate()
        let credentialLoads = SubmitProbe()
        let envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryParent = repository.appendingPathComponent(
            ".artifacts/startup-stop-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: temporaryParent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryParent) }
        let controller = try GPTLiveController(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryParentURL: temporaryParent,
            selectedProfile: {
                if suspension == .selectedProfile {
                    return await selection.select()
                }
                return profile
            },
            credentialLoader: GPTLiveCredentialLoader(load: { _ in
                await credentialLoads.record()
                if suspension == .credential {
                    return await credential.load(envelope: envelope)
                }
                return envelope
            }),
            refreshCredential: {},
            microphonePermission: {
                if suspension == .permission {
                    return await permission.resolve()
                }
                return .authorized
            },
            helperVerifier: acceptingLiveHelperVerifier
        )
        let progress = StartupStopProgress()
        let base = controller.dependencies()
        let liveVoice = LiveVoiceDependencies(
            initialAvailability: .available,
            availability: base.availability,
            start: base.start,
            mute: base.mute,
            interrupt: {
                await progress.enter()
                await base.interrupt()
                await progress.complete()
            },
            end: {
                await progress.enter()
                await base.end()
                await progress.complete()
            }
        )
        let submits = SubmitProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(submits: submits),
            liveVoice: liveVoice
        )
        model.draft = "typed"
        let liveRun = Task { await model.startLiveVoice() }
        try await waitUntil {
            switch suspension {
            case .selectedProfile: await selection.entered
            case .permission: await permission.entered
            case .credential: await credential.entered
            }
        }

        let stop = Task {
            switch action {
            case .interrupt: await model.interruptLiveVoice()
            case .end: await model.endLiveVoice()
            }
        }
        try await waitUntil { await progress.entered }
        try await Task.sleep(for: .milliseconds(50))

        #expect(!(await progress.completed))
        #expect(model.isActiveOperation)
        #expect(!model.canSubmit)
        #expect(!model.canStartLiveVoice)
        #expect(
            await credentialLoads.calls
                == suspension.expectedCredentialLoadsBeforeCleanup
        )

        switch suspension {
        case .selectedProfile: await selection.release()
        case .permission: await permission.release()
        case .credential: await credential.release()
        }
        await stop.value
        await liveRun.value

        #expect(await progress.completed)
        #expect(
            await credentialLoads.calls
                == suspension.expectedCredentialLoadsAfterCleanup
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporaryParent.path).isEmpty)
        #expect(model.voiceState == action.expectedState)
        #expect(model.canSubmit)
        await model.submit()
        #expect(await submits.calls == 1)
    }

    private func assertFailureDuringCleanupIsPreserved(
        action: StartupStopAction
    ) async throws {
        let voice = FailureDuringCleanupProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            liveVoice: await voice.dependencies()
        )
        await model.startLiveVoice()

        let stop = Task {
            switch action {
            case .interrupt: await model.interruptLiveVoice()
            case .end: await model.endLiveVoice()
            }
        }
        try await waitUntil { await voice.failureWasPresented }

        #expect(model.voiceState == .failed)
        #expect(model.isActiveOperation)
        await voice.finishCleanup()
        await stop.value

        #expect(model.voiceState == .failed)
        #expect(!model.isActiveOperation)
    }

}

private enum SyntheticTranscriptPersistenceError: Error {
    case failed
}

private enum StartupStopAction {
    case interrupt
    case end

    var expectedState: LiveVoiceState {
        switch self {
        case .interrupt: .stopped
        case .end: .closed
        }
    }
}

private enum StartupSuspension: Sendable {
    case selectedProfile
    case permission
    case credential

    var expectedCredentialLoadsBeforeCleanup: Int {
        self == .credential ? 1 : 0
    }

    var expectedCredentialLoadsAfterCleanup: Int {
        expectedCredentialLoadsBeforeCleanup + 1
    }
}

private actor VoiceProbe {
    private(set) var starts = 0
    private(set) var mutes: [Bool] = []
    private(set) var interrupts = 0
    private(set) var ends = 0

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { [self] emit in
                await recordStart()
                await emit(.state(.listening))
            },
            mute: { [self] value in await recordMute(value) },
            interrupt: { [self] in await recordInterrupt() },
            end: { [self] in await recordEnd() }
        )
    }

    private func recordStart() { starts += 1 }
    private func recordMute(_ value: Bool) { mutes.append(value) }
    private func recordInterrupt() { interrupts += 1 }
    private func recordEnd() { ends += 1 }
}

private actor StaleLiveSessionEventProbe {
    private var emitters: [@MainActor @Sendable (LiveVoiceEvent) async -> Void] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>?] = []

    var sessionCount: Int { emitters.count }

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { [self] emit in await start(emit: emit) },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func emit(_ event: LiveVoiceEvent, from session: Int) async {
        guard emitters.indices.contains(session) else { return }
        await emitters[session](event)
    }

    func finish(session: Int) {
        guard completionWaiters.indices.contains(session) else { return }
        completionWaiters[session]?.resume()
        completionWaiters[session] = nil
    }

    private func start(
        emit: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async {
        emitters.append(emit)
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }
}

private enum LiveReadinessRemoval: CaseIterable, Sendable {
    case logout
    case delete
    case reset
}

private enum FailingReadinessMutation: CaseIterable, Sendable {
    case saveOpenAICompatible
    case select
    case login
    case refresh
    case logout
    case delete

    var resultingAvailability: LiveVoiceState {
        switch self {
        case .login, .refresh: .available
        case .saveOpenAICompatible, .select, .logout, .delete: .unavailable
        }
    }

    var failureStatus: String {
        switch self {
        case .saveOpenAICompatible: "Profile could not be saved."
        case .select: "Provider could not be selected."
        case .login: "Codex login could not start."
        case .refresh: "Codex refresh could not complete."
        case .logout: "Local logout incomplete."
        case .delete: "Profile could not be deleted."
        }
    }
}

private enum LiveTerminalOutcome: CaseIterable, Sendable {
    case closed
    case failed

    var voiceState: LiveVoiceState {
        switch self {
        case .closed: .closed
        case .failed: .failed
        }
    }
}

private enum StaleReadinessScenario: CaseIterable, Equatable, Sendable {
    case providerMutation
    case admissionFailure
    case terminal

    var initialVoiceState: LiveVoiceState {
        self == .providerMutation ? .unavailable : .available
    }

    var expectedVoiceState: LiveVoiceState {
        switch self {
        case .providerMutation: .unavailable
        case .admissionFailure: .failed
        case .terminal: .closed
        }
    }

    var expectedAvailabilityCalls: Int {
        self == .admissionFailure ? 1 : 2
    }
}

private enum CredentialAuthoritySuspension: CaseIterable, Equatable, Sendable {
    case permission
    case credentialLoad
}

private enum CredentialAuthorityChange: CaseIterable, Equatable, Sendable {
    case invalidate
    case switchReference
}

private struct CredentialAuthorityRaceCase: Sendable {
    let suspension: CredentialAuthoritySuspension
    let change: CredentialAuthorityChange

    static let all = CredentialAuthoritySuspension.allCases.flatMap { suspension in
        CredentialAuthorityChange.allCases.map { change in
            Self(suspension: suspension, change: change)
        }
    }

    var expectedCredentialLoads: Int {
        suspension == .permission ? 0 : 1
    }
}

private enum TypedTerminalOutcome: CaseIterable, Sendable {
    case completed
    case failed

    var turnState: TurnState {
        switch self {
        case .completed: .completed
        case .failed: .failed
        }
    }
}

private enum FastTypedTerminalOutcome: CaseIterable, Equatable, Sendable {
    case completed
    case stopped
    case failed

    var turnState: TurnState {
        switch self {
        case .completed: .completed
        case .stopped: .stopped
        case .failed: .failed
        }
    }

    var presentationState: PresentationState {
        switch self {
        case .completed: .completed
        case .stopped: .stopped
        case .failed: .failed
        }
    }
}

private struct FastTerminalReadinessCase: Sendable {
    let outcome: FastTypedTerminalOutcome
    let availability: LiveVoiceState

    static let all = FastTypedTerminalOutcome.allCases.flatMap { outcome in
        [LiveVoiceState.available, .unavailable].map { availability in
            Self(outcome: outcome, availability: availability)
        }
    }
}

private enum SuspendedProviderMutation: CaseIterable, Equatable, Sendable {
    case save
    case codexModel
    case select
    case login
    case refresh
    case retry
    case logout
    case delete
    case reset

    var expectedActiveFlags: [Bool] {
        switch self {
        case .save, .select, .login, .refresh, .logout, .delete: [false]
        case .codexModel, .retry, .reset: []
        }
    }
}

private enum ProviderMutationAttempt: CaseIterable, Sendable {
    case save
    case codexModel
    case select
    case login
    case refresh
    case retry
    case logout
    case delete
    case reset
}

private enum PartialSnapshotMutation: CaseIterable, Equatable, Sendable {
    case save
    case codexModel
    case select
    case login
    case refresh
    case logout
    case delete

    var committedLabel: String {
        "Committed \(self)"
    }

    var failureStatus: String {
        switch self {
        case .save: "Profile could not be saved."
        case .codexModel: "Codex model could not be saved."
        case .select: "Provider could not be selected."
        case .login: "Codex login could not start."
        case .refresh: "Codex refresh could not complete."
        case .logout: "Local logout incomplete."
        case .delete: "Profile could not be deleted."
        }
    }
}

private enum ResetSnapshotOutcome: CaseIterable, Equatable, Sendable {
    case success
    case partialFailure

    var status: String {
        switch self {
        case .success: "Reset completed; secure erasure is not claimed."
        case .partialFailure: "Reset incomplete; review failed roots."
        }
    }

    var expectedSelectedProfiles: Int {
        self == .success ? 0 : 1
    }
}

private enum StandaloneProviderStatusTransition: CaseIterable, Sendable {
    case activeRefusal
    case endpointValidation

    var expectedStatus: String {
        switch self {
        case .activeRefusal: "Finish the active response before switching."
        case .endpointValidation: "Endpoint is not allowed."
        }
    }
}

private enum ActiveProviderMutationInterference: CaseIterable, Sendable {
    case ordinaryRefresh
    case refusedMutation
}

private enum StaleConversationProjection: CaseIterable, Sendable {
    case conversations
    case turns
}

private enum LiveCleanupAction: CaseIterable, Sendable {
    case interrupt
    case end

    var voiceState: LiveVoiceState {
        switch self {
        case .interrupt: .stopped
        case .end: .closed
        }
    }
}

private enum SyntheticProviderMutationError: Error {
    case failed
}

private enum SyntheticTypedSubmissionError: Error {
    case failed
}

private actor OrderedReadinessProbe {
    private let scenario: StaleReadinessScenario
    private var firstContinuation: CheckedContinuation<LiveVoiceState, Never>?
    private var currentAvailability: LiveVoiceState = .unavailable
    private(set) var firstAvailabilityEntered = false
    private(set) var availabilityCalls = 0

    init(scenario: StaleReadinessScenario) {
        self.scenario = scenario
    }

    func liveDependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: scenario.initialVoiceState,
            availability: { [self] in await availability() },
            start: { [self] emit in try await start(emit: emit) },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func providerDependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            saveOpenAICompatible: { _, _ in },
            saveCodexModel: { _ in },
            select: { [self] _, _ in await commitUnavailable() },
            beginCodexLogin: { _ in },
            refreshCodexAuthentication: { _ in },
            retryReadiness: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            localLogout: { _ in },
            delete: { _, _ in },
            reset: { ResetResult(roots: []) }
        )
    }

    func releaseFirstAvailability() {
        firstContinuation?.resume(returning: .available)
        firstContinuation = nil
    }

    private func availability() async -> LiveVoiceState {
        availabilityCalls += 1
        guard availabilityCalls == 1 else { return currentAvailability }
        firstAvailabilityEntered = true
        return await withCheckedContinuation { firstContinuation = $0 }
    }

    private func start(
        emit: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async throws {
        switch scenario {
        case .providerMutation:
            return
        case .admissionFailure:
            throw GPTLiveCredentialError.unavailable
        case .terminal:
            await emit(.state(.listening))
            currentAvailability = .unavailable
            await emit(.state(.closed))
        }
    }

    private func commitUnavailable() {
        currentAvailability = .unavailable
    }
}

private actor PrivilegedReadinessProbe {
    private var continuation: CheckedContinuation<LiveVoiceState, Never>?
    private(set) var availabilityEntered = false
    private(set) var availabilityCalls = 0

    nonisolated func hostDependencies() -> HostDependencies {
        HostDependencies(
            submit: { _, _ in throw SyntheticTypedSubmissionError.failed },
            stop: {},
            loadTurn: { _ in nil },
            loadConversations: { [] },
            loadTurns: { _ in [] },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    func liveDependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .unavailable,
            availability: { [self] in await availability() },
            start: { _ in },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func releaseAvailability() {
        continuation?.resume(returning: .available)
        continuation = nil
    }

    private func availability() async -> LiveVoiceState {
        availabilityCalls += 1
        availabilityEntered = true
        return await withCheckedContinuation { continuation = $0 }
    }
}

private actor PartialProviderSnapshotProbe {
    nonisolated let committedSnapshot: ProviderSettingsSnapshot

    private let mutation: PartialSnapshotMutation
    private var snapshot: ProviderSettingsSnapshot
    private(set) var loadCalls = 0

    init(mutation: PartialSnapshotMutation) {
        self.mutation = mutation
        snapshot = ProviderSettingsSnapshot(
            profiles: [
                ProviderSettingsProfile(
                    id: UUID(),
                    label: "Initial",
                    kind: .openAICompatible,
                    endpoint: "https://example.invalid",
                    model: "initial",
                    credentialReference: UUID(),
                    isSelected: true
                ),
            ],
            readiness: "Ready"
        )
        committedSnapshot = ProviderSettingsSnapshot(
            profiles: [
                ProviderSettingsProfile(
                    id: UUID(),
                    label: mutation.committedLabel,
                    kind: mutation == .codexModel || mutation == .login
                        || mutation == .refresh ? .codexOAuth : .openAICompatible,
                    endpoint: mutation == .codexModel || mutation == .login
                        || mutation == .refresh ? nil : "https://committed.invalid",
                    model: "committed-model",
                    credentialReference: UUID(),
                    isSelected: true
                ),
            ],
            readiness: "Committed authority"
        )
    }

    func dependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: { [self] in await load() },
            saveOpenAICompatible: { [self] _, _ in try await commit(.save) },
            saveCodexModel: { [self] _ in try await commit(.codexModel) },
            select: { [self] _, _ in try await commit(.select) },
            beginCodexLogin: { [self] _ in try await commit(.login) },
            refreshCodexAuthentication: { [self] _ in try await commit(.refresh) },
            retryReadiness: { [self] in await load() },
            localLogout: { [self] _ in try await commit(.logout) },
            delete: { [self] _, _ in try await commit(.delete) },
            reset: { ResetResult(roots: []) }
        )
    }

    private func load() -> ProviderSettingsSnapshot {
        loadCalls += 1
        return snapshot
    }

    private func commit(_ invoked: PartialSnapshotMutation) throws {
        guard invoked == mutation else { return }
        snapshot = committedSnapshot
        throw SyntheticProviderMutationError.failed
    }
}

private actor ProviderSnapshotGenerationProbe {
    nonisolated let startupSnapshot: ProviderSettingsSnapshot
    nonisolated let mutationSnapshot: ProviderSettingsSnapshot

    private var firstContinuation:
        CheckedContinuation<ProviderSettingsSnapshot, Never>?
    private var selectedMutation = false
    private(set) var firstLoadEntered = false
    private(set) var loadCalls = 0

    init() {
        startupSnapshot = Self.snapshot(label: "Stale startup")
        mutationSnapshot = Self.snapshot(label: "Mutation authority")
    }

    func dependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: { [self] in await load() },
            saveOpenAICompatible: { _, _ in },
            saveCodexModel: { _ in },
            select: { [self] _, _ in await select() },
            beginCodexLogin: { _ in },
            refreshCodexAuthentication: { _ in },
            retryReadiness: { [self] in await load() },
            localLogout: { _ in },
            delete: { _, _ in },
            reset: { ResetResult(roots: []) }
        )
    }

    func releaseFirstLoad() {
        firstContinuation?.resume(returning: startupSnapshot)
        firstContinuation = nil
    }

    private func load() async -> ProviderSettingsSnapshot {
        loadCalls += 1
        if loadCalls == 1 {
            firstLoadEntered = true
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return selectedMutation ? mutationSnapshot : startupSnapshot
    }

    private func select() {
        selectedMutation = true
    }

    nonisolated private static func snapshot(
        label: String
    ) -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot(
            profiles: [
                ProviderSettingsProfile(
                    id: UUID(),
                    label: label,
                    kind: .openAICompatible,
                    endpoint: "https://example.invalid",
                    model: "fixture-model",
                    credentialReference: UUID(),
                    isSelected: true
                ),
            ],
            readiness: label
        )
    }
}

private actor StandaloneProviderStatusProbe {
    private let staleSnapshot = ProviderSettingsSnapshot(
        profiles: [
            ProviderSettingsProfile(
                id: UUID(),
                label: "Stale startup",
                kind: .openAICompatible,
                endpoint: "https://example.invalid",
                model: "fixture-model",
                credentialReference: UUID(),
                isSelected: true
            ),
        ],
        readiness: "Stale startup"
    )
    private var continuation:
        CheckedContinuation<ProviderSettingsSnapshot, Never>?
    private(set) var loadEntered = false

    func dependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: { [self] in await load() },
            saveOpenAICompatible: { _, _ in },
            saveCodexModel: { _ in },
            select: { _, _ in },
            beginCodexLogin: { _ in },
            refreshCodexAuthentication: { _ in },
            retryReadiness: { [staleSnapshot] in staleSnapshot },
            localLogout: { _ in },
            delete: { _, _ in },
            reset: { ResetResult(roots: []) }
        )
    }

    func releaseLoad() {
        continuation?.resume(returning: staleSnapshot)
        continuation = nil
    }

    private func load() async -> ProviderSettingsSnapshot {
        loadEntered = true
        return await withCheckedContinuation { continuation = $0 }
    }
}

private actor ActiveProviderMutationOwnershipProbe {
    nonisolated let committedSnapshot = ProviderSettingsSnapshot(
        profiles: [
            ProviderSettingsProfile(
                id: UUID(),
                label: "Committed owner",
                kind: .openAICompatible,
                endpoint: "https://committed.invalid",
                model: "committed-model",
                credentialReference: UUID(),
                isSelected: true
            ),
        ],
        readiness: "Committed owner"
    )

    private var snapshot = ProviderSettingsSnapshot(
        profiles: [],
        readiness: "Initial snapshot"
    )
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var mutationEntered = false

    func dependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: { [self] in await load() },
            saveOpenAICompatible: { _, _ in },
            saveCodexModel: { _ in },
            select: { [self] _, _ in await select() },
            beginCodexLogin: { _ in },
            refreshCodexAuthentication: { _ in },
            retryReadiness: { [self] in await load() },
            localLogout: { _ in },
            delete: { _, _ in },
            reset: { ResetResult(roots: []) }
        )
    }

    func releaseMutation() {
        continuation?.resume()
        continuation = nil
    }

    private func load() -> ProviderSettingsSnapshot {
        snapshot
    }

    private func select() async {
        mutationEntered = true
        await withCheckedContinuation { continuation = $0 }
        snapshot = committedSnapshot
    }
}

private actor ResetSnapshotProbe {
    nonisolated let committedSnapshot: ProviderSettingsSnapshot
    nonisolated let resetResult: ResetResult

    private var snapshot: ProviderSettingsSnapshot
    private(set) var loadCalls = 0

    init(outcome: ResetSnapshotOutcome) {
        let committedProfiles: [ProviderSettingsProfile]
        switch outcome {
        case .success:
            committedProfiles = []
        case .partialFailure:
            committedProfiles = [
                ProviderSettingsProfile(
                    id: UUID(),
                    label: "Surviving authority",
                    kind: .openAICompatible,
                    endpoint: "https://committed.invalid",
                    model: "committed",
                    credentialReference: UUID(),
                    isSelected: true
                ),
            ]
        }
        snapshot = ProviderSettingsSnapshot(
            profiles: [
                ProviderSettingsProfile(
                    id: UUID(),
                    label: "Initial",
                    kind: .openAICompatible,
                    endpoint: "https://initial.invalid",
                    model: "initial",
                    credentialReference: UUID(),
                    isSelected: true
                ),
            ],
            readiness: "Ready"
        )
        committedSnapshot = ProviderSettingsSnapshot(
            profiles: committedProfiles,
            readiness: outcome == .success
                ? "Not configured"
                : "Surviving readiness"
        )
        resetResult = ResetResult(
            roots: [
                ResetRootResult(root: "helper", succeeded: true),
                ResetRootResult(
                    root: "database",
                    succeeded: outcome == .success
                ),
            ]
        )
    }

    func dependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: { [self] in await load() },
            saveOpenAICompatible: { _, _ in },
            saveCodexModel: { _ in },
            select: { _, _ in },
            beginCodexLogin: { _ in },
            refreshCodexAuthentication: { _ in },
            retryReadiness: { [self] in await load() },
            localLogout: { _ in },
            delete: { _, _ in },
            reset: { [self] in await reset() }
        )
    }

    private func load() -> ProviderSettingsSnapshot {
        loadCalls += 1
        return snapshot
    }

    private func reset() -> ResetResult {
        snapshot = committedSnapshot
        return resetResult
    }
}

private actor ResetPresentationStateProbe {
    nonisolated let conversationID = ConversationID()
    nonisolated let staleSnapshot = ProviderSettingsSnapshot(
        profiles: [
            ProviderSettingsProfile(
                id: UUID(),
                label: "Stale provider",
                kind: .openAICompatible,
                endpoint: "https://example.invalid",
                model: "stale-model",
                credentialReference: UUID(),
                isSelected: true
            ),
        ],
        readiness: "Stale readiness",
        codexModels: [GatewayModelChoice(id: "stale", name: "Stale")],
        codexDefaultModel: "stale"
    )

    private var didReset = false
    private var providerLoads = 0

    nonisolated func hostDependencies() -> HostDependencies {
        HostDependencies(
            submit: { _, _ in throw SyntheticTypedSubmissionError.failed },
            stop: {},
            loadTurn: { _ in nil },
            loadConversations: { [self] in await conversations() },
            loadTurns: { [self] _ in await turns() },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    func providerDependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: { [self] in try await loadProviderSnapshot() },
            saveOpenAICompatible: { _, _ in },
            saveCodexModel: { _ in },
            select: { _, _ in },
            beginCodexLogin: { _ in },
            refreshCodexAuthentication: { _ in },
            retryReadiness: { [staleSnapshot] in staleSnapshot },
            localLogout: { _ in },
            delete: { _, _ in },
            reset: { [self] in await reset() }
        )
    }

    func liveDependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .unavailable,
            availability: { .unavailable },
            start: { _ in },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    private func conversations() -> [Conversation] {
        guard !didReset else { return [] }
        let now = Date()
        return [
            Conversation(
                id: conversationID,
                title: "Stale conversation",
                createdAt: now,
                updatedAt: now
            ),
        ]
    }

    private func turns() -> [Turn] {
        guard !didReset else { return [] }
        return [
            Turn(
                id: TurnID(),
                conversationID: conversationID,
                sequence: 1,
                inputMode: .text,
                userText: "stale turn",
                assistantText: "stale answer",
                state: .completed,
                generation: 1,
                errorCode: nil,
                errorMessage: nil,
                startedAt: Date(),
                terminalAt: Date()
            ),
        ]
    }

    private func loadProviderSnapshot() throws -> ProviderSettingsSnapshot {
        providerLoads += 1
        guard providerLoads == 1 else {
            throw SyntheticProviderMutationError.failed
        }
        return staleSnapshot
    }

    private func reset() -> ResetResult {
        didReset = true
        return ResetResult(roots: [
            ResetRootResult(root: "runtime.resume", succeeded: true),
        ])
    }
}

private actor ConversationProjectionResetProbe {
    private let projection: StaleConversationProjection
    private let staleConversation: Conversation
    private let staleTurn: Turn
    private var conversationContinuation:
        CheckedContinuation<[Conversation], Never>?
    private var turnContinuation: CheckedContinuation<[Turn], Never>?
    private var didReset = false
    private var conversationLoads = 0
    private var turnLoads = 0
    private(set) var staleLoadEntered = false

    init(projection: StaleConversationProjection) {
        self.projection = projection
        let conversationID = ConversationID()
        let now = Date()
        staleConversation = Conversation(
            id: conversationID,
            title: "Deleted conversation",
            createdAt: now,
            updatedAt: now
        )
        staleTurn = Turn(
            id: TurnID(),
            conversationID: conversationID,
            sequence: 1,
            inputMode: .text,
            userText: "deleted turn",
            assistantText: "deleted answer",
            state: .completed,
            generation: 1,
            errorCode: nil,
            errorMessage: nil,
            startedAt: now,
            terminalAt: now
        )
    }

    nonisolated func hostDependencies() -> HostDependencies {
        HostDependencies(
            submit: { _, _ in throw SyntheticTypedSubmissionError.failed },
            stop: {},
            loadTurn: { _ in nil },
            loadConversations: { [self] in await loadConversations() },
            loadTurns: { [self] _ in await loadTurns() },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    func providerDependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: { ProviderSettingsSnapshot(profiles: [], readiness: "Ready") },
            saveOpenAICompatible: { _, _ in },
            saveCodexModel: { _ in },
            select: { _, _ in },
            beginCodexLogin: { _ in },
            refreshCodexAuthentication: { _ in },
            retryReadiness: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Ready")
            },
            localLogout: { _ in },
            delete: { _, _ in },
            reset: { [self] in await reset() }
        )
    }

    func releaseStaleLoad() {
        conversationContinuation?.resume(returning: [staleConversation])
        conversationContinuation = nil
        turnContinuation?.resume(returning: [staleTurn])
        turnContinuation = nil
    }

    private func loadConversations() async -> [Conversation] {
        conversationLoads += 1
        guard !didReset else { return [] }
        guard projection == .conversations, conversationLoads == 1 else {
            return [staleConversation]
        }
        staleLoadEntered = true
        return await withCheckedContinuation {
            conversationContinuation = $0
        }
    }

    private func loadTurns() async -> [Turn] {
        turnLoads += 1
        guard !didReset else { return [] }
        guard projection == .turns, turnLoads == 1 else {
            return [staleTurn]
        }
        staleLoadEntered = true
        return await withCheckedContinuation { turnContinuation = $0 }
    }

    private func reset() -> ResetResult {
        didReset = true
        return ResetResult(roots: [])
    }
}

private actor LiveReadinessMutationProbe {
    private var availability: LiveVoiceState
    private let codexID: UUID?
    private let failingMutation: FailingReadinessMutation?
    private let mutateBeforeFailure: Bool
    private(set) var availabilityCalls = 0
    private(set) var mutationCalls = 0
    private(set) var startCalls = 0

    init(
        initialAvailability: LiveVoiceState,
        codexID: UUID? = nil,
        failingMutation: FailingReadinessMutation? = nil,
        mutateBeforeFailure: Bool = false
    ) {
        availability = initialAvailability
        self.codexID = codexID
        self.failingMutation = failingMutation
        self.mutateBeforeFailure = mutateBeforeFailure
    }

    func liveDependencies(
        initialAvailability: LiveVoiceState
    ) -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: initialAvailability,
            availability: { [self] in await currentAvailability() },
            start: { [self] emit in
                await recordStart()
                await emit(.state(.listening))
            },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func providerDependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            saveOpenAICompatible: { [self] _, _ in
                try await mutate(.saveOpenAICompatible, availability: .unavailable)
            },
            saveCodexModel: { _ in },
            select: { [self] id, _ in
                try await select(id)
            },
            beginCodexLogin: { [self] _ in
                try await mutate(.login, availability: .available)
            },
            refreshCodexAuthentication: { [self] _ in
                try await mutate(.refresh, availability: .available)
            },
            retryReadiness: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            localLogout: { [self] _ in
                try await mutate(.logout, availability: .unavailable)
            },
            delete: { [self] _, _ in
                try await mutate(.delete, availability: .unavailable)
            },
            reset: { [self] in
                await resetAvailability()
            }
        )
    }

    private func currentAvailability() -> LiveVoiceState {
        availabilityCalls += 1
        return availability
    }

    private func recordStart() {
        startCalls += 1
    }

    private func select(_ id: UUID) throws {
        try mutate(
            .select,
            availability: id == codexID ? .available : .unavailable
        )
    }

    private func resetAvailability() -> ResetResult {
        mutationCalls += 1
        availability = .unavailable
        return ResetResult(roots: [])
    }

    private func mutate(
        _ mutation: FailingReadinessMutation,
        availability: LiveVoiceState
    ) throws {
        mutationCalls += 1
        if failingMutation == mutation {
            if mutateBeforeFailure {
                self.availability = availability
            }
            throw SyntheticProviderMutationError.failed
        }
        self.availability = availability
    }
}

private actor StartAdmissionProbe {
    private(set) var availabilityCalls = 0
    private(set) var credentialLoads = 0

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { [self] in await availability() },
            start: { [self] _ in try await start() },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    private func availability() -> LiveVoiceState {
        availabilityCalls += 1
        return .unavailable
    }

    private func start() throws {
        credentialLoads += 1
        throw GPTLiveCredentialError.unavailable
    }
}

private actor TerminalReadinessProbe {
    private var availability: LiveVoiceState = .available
    private var emit: (@MainActor @Sendable (LiveVoiceEvent) async -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var readyForFinish = false

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { [self] in await currentAvailability() },
            start: { [self] emit in await start(emit: emit) },
            mute: { _ in },
            interrupt: { [self] in await interrupt() },
            end: { [self] in await interrupt() }
        )
    }

    func setAvailability(_ availability: LiveVoiceState) {
        self.availability = availability
    }

    func finish(
        _ outcome: LiveTerminalOutcome,
        availability: LiveVoiceState
    ) async {
        self.availability = availability
        switch outcome {
        case .closed:
            await emit?(.state(.closed))
        case .failed:
            await emit?(.failed(code: "synthetic_failure"))
        }
        resume()
    }

    private func currentAvailability() -> LiveVoiceState {
        availability
    }

    private func start(
        emit: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async {
        self.emit = emit
        await emit(.state(.listening))
        await withCheckedContinuation {
            continuation = $0
            readyForFinish = true
        }
    }

    private func interrupt() async {
        await emit?(.state(.closed))
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
        readyForFinish = false
    }
}

private actor TypedTurnGate {
    private let turn: Turn
    private var continuation: CheckedContinuation<Turn?, Never>?
    private(set) var entered = false

    init(turn: Turn) {
        self.turn = turn
    }

    func load() async -> Turn? {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: turn)
        continuation = nil
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func record() {
        lock.withLock { count += 1 }
    }
}

private actor CredentialInvalidationProbe {
    private var invalidated: Bool

    init(invalidated: Bool) {
        self.invalidated = invalidated
    }

    func isInvalidated(reference _: UUID) -> Bool {
        invalidated
    }

    func setInvalidated(_ invalidated: Bool) {
        self.invalidated = invalidated
    }
}

private actor GPTLiveAuthorityRaceProbe {
    private let testCase: CredentialAuthorityRaceCase
    private let originalProfile: ProviderProfile
    private let replacementProfile: ProviderProfile
    private let envelope: CredentialEnvelope
    private var selected: ProviderProfile
    private var invalidatedReferences: Set<UUID> = []
    private var permissionContinuation:
        CheckedContinuation<MicrophonePermission, Never>?
    private var credentialContinuation:
        CheckedContinuation<CredentialEnvelope, Never>?
    private var permissionEntered = false
    private var credentialEntered = false
    private(set) var credentialLoads = 0

    init(testCase: CredentialAuthorityRaceCase) throws {
        self.testCase = testCase
        let original = try ProviderProfile(
            kind: .codexOAuth,
            label: "Original Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        let replacement = try ProviderProfile(
            kind: .codexOAuth,
            label: "Replacement Codex",
            baseURL: nil,
            model: "gpt-5.6-terra",
            credentialReference: UUID(),
            isSelected: true
        )
        originalProfile = original
        replacementProfile = replacement
        selected = original
        envelope = try CredentialEnvelope(
            providerKind: .codexOAuth,
            payload: Data(
                #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"synthetic-account"}"#.utf8
            )
        )
    }

    var suspensionEntered: Bool {
        switch testCase.suspension {
        case .permission: permissionEntered
        case .credentialLoad: credentialEntered
        }
    }

    func selectedProfile() -> ProviderProfile? {
        selected
    }

    func isInvalidated(reference: UUID) -> Bool {
        invalidatedReferences.contains(reference)
    }

    func microphonePermission() async -> MicrophonePermission {
        guard testCase.suspension == .permission else { return .authorized }
        permissionEntered = true
        return await withCheckedContinuation { permissionContinuation = $0 }
    }

    func loadCredential(reference _: UUID) async throws -> CredentialEnvelope {
        credentialLoads += 1
        guard testCase.suspension == .credentialLoad else { return envelope }
        credentialEntered = true
        return await withCheckedContinuation { credentialContinuation = $0 }
    }

    func changeAuthority() {
        switch testCase.change {
        case .invalidate:
            invalidatedReferences.insert(originalProfile.credentialReference)
        case .switchReference:
            selected = replacementProfile
        }
    }

    func releaseSuspension() {
        switch testCase.suspension {
        case .permission:
            permissionContinuation?.resume(returning: .authorized)
            permissionContinuation = nil
        case .credentialLoad:
            credentialContinuation?.resume(returning: envelope)
            credentialContinuation = nil
        }
    }
}

private actor FastTypedTerminalProbe {
    nonisolated let turnID = TurnID()

    private let testCase: FastTerminalReadinessCase
    private var initialRefreshContinuation: CheckedContinuation<Void, Never>?
    private var initialRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadConversationCalls = 0
    private var loadTurnDelivered = false
    private(set) var initialRefreshEntered = false
    private(set) var terminalRefreshReachedLoadTurns = false
    private(set) var availabilityCalls = 0

    init(testCase: FastTerminalReadinessCase) {
        self.testCase = testCase
    }

    func hostDependencies() -> HostDependencies {
        HostDependencies(
            submit: { [turnID] _, _ in turnID },
            stop: {},
            loadTurn: { [self] id in await terminalTurn(id: id) },
            loadConversations: { [self] in await loadConversations() },
            loadTurns: { [self] _ in await loadTurns() },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    func liveDependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { [self] in await currentAvailability() },
            start: { _ in },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func releaseInitialRefresh() {
        initialRefreshContinuation?.resume()
        initialRefreshContinuation = nil
    }

    private func terminalTurn(id: TurnID) async -> Turn? {
        guard id == turnID, !loadTurnDelivered else { return nil }
        if !initialRefreshEntered {
            await withCheckedContinuation { initialRefreshWaiters.append($0) }
        }
        loadTurnDelivered = true
        return Turn(
            id: turnID,
            conversationID: ConversationID(),
            sequence: 1,
            inputMode: .text,
            userText: "typed",
            assistantText: testCase.outcome == .completed ? "done" : "",
            state: testCase.outcome.turnState,
            generation: 2,
            errorCode: testCase.outcome == .failed ? "synthetic_failure" : nil,
            errorMessage: testCase.outcome == .failed ? "Synthetic failure." : nil,
            startedAt: Date(),
            terminalAt: Date()
        )
    }

    private func loadConversations() async -> [Conversation] {
        loadConversationCalls += 1
        guard loadConversationCalls == 1 else { return [] }
        initialRefreshEntered = true
        let waiters = initialRefreshWaiters
        initialRefreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { initialRefreshContinuation = $0 }
        return []
    }

    private func loadTurns() -> [Turn] {
        terminalRefreshReachedLoadTurns = true
        return []
    }

    private func currentAvailability() -> LiveVoiceState {
        availabilityCalls += 1
        return testCase.availability
    }
}

private actor TypedSubmissionRaceProbe {
    nonisolated let turnID = TurnID()

    private let submitFails: Bool
    private var submitContinuation: CheckedContinuation<Void, Never>?
    private var availability: LiveVoiceState = .available
    private(set) var submitEntered = false
    private(set) var providerMutationCalls = 0
    private(set) var activeFlags: [Bool] = []
    private(set) var liveStarts = 0
    private(set) var availabilityCalls = 0

    init(submitFails: Bool = false) {
        self.submitFails = submitFails
    }

    func hostDependencies() -> HostDependencies {
        HostDependencies(
            submit: { [self] _, _ in try await suspendSubmit() },
            stop: {},
            loadTurn: { _ in nil },
            loadConversations: { [] },
            loadTurns: { _ in [] },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    func providerDependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            saveOpenAICompatible: { [self] _, active in
                await recordProviderMutation(active: active)
            },
            saveCodexModel: { [self] _ in
                await recordProviderMutation(active: nil)
            },
            select: { [self] _, active in
                await recordProviderMutation(active: active)
            },
            beginCodexLogin: { [self] active in
                await recordProviderMutation(active: active)
            },
            refreshCodexAuthentication: { [self] active in
                await recordProviderMutation(active: active)
            },
            retryReadiness: { [self] in
                await recordProviderMutation(active: nil)
                return ProviderSettingsSnapshot(
                    profiles: [],
                    readiness: "Not configured"
                )
            },
            localLogout: { [self] active in
                await recordProviderMutation(active: active)
            },
            delete: { [self] _, active in
                await recordProviderMutation(active: active)
            },
            reset: { [self] in
                await recordProviderMutation(active: nil)
                return ResetResult(roots: [])
            }
        )
    }

    func liveDependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { [self] in await currentAvailability() },
            start: { [self] _ in await recordLiveStart() },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func releaseSubmit() {
        submitContinuation?.resume()
        submitContinuation = nil
    }

    func revokeAvailability() {
        availability = .unavailable
    }

    private func suspendSubmit() async throws -> TurnID {
        submitEntered = true
        await withCheckedContinuation { submitContinuation = $0 }
        if submitFails { throw SyntheticTypedSubmissionError.failed }
        return turnID
    }

    private func recordProviderMutation(active: Bool?) {
        providerMutationCalls += 1
        if let active { activeFlags.append(active) }
    }

    private func recordLiveStart() {
        liveStarts += 1
    }

    private func currentAvailability() -> LiveVoiceState {
        availabilityCalls += 1
        return availability
    }
}

private actor ProviderMutationRaceProbe {
    private let suspended: SuspendedProviderMutation
    private let throwsAfterRelease: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var commits = 0
    private(set) var liveStarts = 0
    private(set) var activeFlags: [Bool] = []

    init(
        suspended: SuspendedProviderMutation,
        throwsAfterRelease: Bool = false
    ) {
        self.suspended = suspended
        self.throwsAfterRelease = throwsAfterRelease
    }

    func providerDependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            saveOpenAICompatible: { [self] _, active in
                try await mutate(.save, active: active)
            },
            saveCodexModel: { [self] _ in try await mutate(.codexModel) },
            select: { [self] _, active in try await mutate(.select, active: active) },
            beginCodexLogin: { [self] active in try await mutate(.login, active: active) },
            refreshCodexAuthentication: { [self] active in
                try await mutate(.refresh, active: active)
            },
            retryReadiness: { [self] in
                try await mutate(.retry)
                return ProviderSettingsSnapshot(
                    profiles: [], readiness: "Not configured"
                )
            },
            localLogout: { [self] active in try await mutate(.logout, active: active) },
            delete: { [self] _, active in try await mutate(.delete, active: active) },
            reset: { [self] in
                await mutateReset()
                return ResetResult(roots: [])
            }
        )
    }

    func liveDependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { [self] emit in
                await recordLiveStart()
                await emit(.state(.listening))
            },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func mutate(
        _ mutation: SuspendedProviderMutation,
        active: Bool? = nil
    ) async throws {
        guard mutation == suspended else { return }
        if let active { activeFlags.append(active) }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        if throwsAfterRelease {
            throw SyntheticProviderMutationError.failed
        }
        commits += 1
    }

    private func mutateReset() async {
        guard suspended == .reset else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        commits += 1
    }

    private func recordLiveStart() {
        liveStarts += 1
    }
}

private actor DetachedCleanupReadinessProbe {
    private var availability: LiveVoiceState = .available
    private(set) var availabilityCalls = 0

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { [self] in await currentAvailability() },
            start: { emit in await emit(.state(.listening)) },
            mute: { _ in },
            interrupt: { [self] in await invalidate() },
            end: { [self] in await invalidate() }
        )
    }

    private func currentAvailability() -> LiveVoiceState {
        availabilityCalls += 1
        return availability
    }

    private func invalidate() {
        availability = .unavailable
    }
}

private actor SubmitProbe {
    private(set) var calls = 0

    func record() { calls += 1 }
}

private actor StartupProfileGate {
    private let profile: ProviderProfile
    private var continuation: CheckedContinuation<ProviderProfile?, Never>?
    private var isReleased = false
    private(set) var entered = false

    init(profile: ProviderProfile) {
        self.profile = profile
    }

    func select() async -> ProviderProfile? {
        if isReleased { return profile }
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume(returning: profile)
        continuation = nil
    }
}

private actor StartupPermissionGate {
    private var continuation: CheckedContinuation<MicrophonePermission, Never>?
    private var isReleased = false
    private(set) var entered = false

    func resolve() async -> MicrophonePermission {
        if isReleased { return .authorized }
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume(returning: .authorized)
        continuation = nil
    }
}

private actor StartupCredentialGate {
    private var envelope: CredentialEnvelope?
    private var releasedEnvelope: CredentialEnvelope?
    private var continuation: CheckedContinuation<CredentialEnvelope, Never>?
    private(set) var entered = false

    func load(envelope: CredentialEnvelope) async -> CredentialEnvelope {
        if let releasedEnvelope { return releasedEnvelope }
        entered = true
        self.envelope = envelope
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        guard let envelope else { return }
        releasedEnvelope = envelope
        continuation?.resume(returning: envelope)
        continuation = nil
    }
}

private actor StartupStopProgress {
    private(set) var entered = false
    private(set) var completed = false

    func enter() { entered = true }
    func complete() { completed = true }
}

private actor FailureDuringCleanupProbe {
    private var emit: (@MainActor @Sendable (LiveVoiceEvent) async -> Void)?
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private(set) var failureWasPresented = false

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { [self] emit in await start(emit: emit) },
            mute: { _ in },
            interrupt: { [self] in await failAndWaitForCleanup() },
            end: { [self] in await failAndWaitForCleanup() }
        )
    }

    func finishCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    private func start(
        emit: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async {
        self.emit = emit
        await emit(.state(.listening))
    }

    private func failAndWaitForCleanup() async {
        await emit?(.failed(code: "synthetic_failure"))
        failureWasPresented = true
        await withCheckedContinuation { cleanupContinuation = $0 }
    }
}

private actor SpontaneousTerminalProbe {
    enum Terminal {
        case closed
        case failed
    }

    private let terminal: Terminal
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private(set) var terminalWasPresented = false
    private(set) var availabilityCalls = 0

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { [self] in await availability() },
            start: { [self] emit in await start(emit: emit) },
            mute: { _ in },
            interrupt: {},
            end: {}
        )
    }

    func finishCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    private func availability() -> LiveVoiceState {
        availabilityCalls += 1
        return .available
    }

    private func start(
        emit: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async {
        await emit(.state(.listening))
        switch terminal {
        case .closed:
            await emit(.state(.closed))
        case .failed:
            await emit(.failed(code: "synthetic_failure"))
        }
        terminalWasPresented = true
        await withCheckedContinuation { cleanupContinuation = $0 }
    }
}

private actor FakeHelperVoiceProbe {
    private let artifacts: URL
    nonisolated let marker: URL
    private let mode: String
    private var process: CodexAppServerProcess?
    private var session: LiveAudioSession?
    private(set) var startAttempts = 0

    init(testName: String, mode: String = "delay-stop") throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        artifacts = repository.appendingPathComponent(".artifacts")
        marker = artifacts.appendingPathComponent(
            "\(testName)-\(UUID().uuidString.lowercased()).txt"
        )
        self.mode = mode
        try FileManager.default.createDirectory(
            at: artifacts, withIntermediateDirectories: true
        )
    }

    var stopWasReceived: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    var privateRootExists: Bool {
        guard let process else { return false }
        return FileManager.default.fileExists(atPath: process.temporaryRootURL.path)
    }

    func dependencies() -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: .available,
            availability: { .available },
            start: { [self] emit in try await start(emit: emit) },
            mute: { _ in },
            interrupt: { [self] in await session?.interrupt() },
            end: { [self] in await session?.end() }
        )
    }

    nonisolated func cleanArtifacts() {
        try? FileManager.default.removeItem(at: marker)
    }

    private func start(
        emit: @escaping @MainActor @Sendable (LiveVoiceEvent) async -> Void
    ) async throws {
        startAttempts += 1
        guard session == nil else {
            throw CodexAppServerClientError.sessionAlreadyActive
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(
            "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
        )
        let process = CodexAppServerProcess(configuration: try .init(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node"),
            arguments: [fixture.path, mode, marker.path],
            temporaryParentURL: artifacts,
            terminationGrace: .milliseconds(100)
        ))
        let session = LiveAudioSession(
            client: CodexAppServerClient(process: process),
            peer: await MainActor.run { PresentationTestPeer() }
        )
        self.process = process
        self.session = session
        defer { self.session = nil }
        try await session.run(
            identity: .init(
                requestID: UUID().uuidString.lowercased(),
                threadID: UUID().uuidString.lowercased(),
                generation: 1
            ),
            credential: .init(
                accessToken: Data("synthetic".utf8),
                accountID: "account-1",
                planType: nil
            ),
            permission: .authorized
        ) { event in
            switch event {
            case .started:
                await emit(.state(.listening))
            case .closed:
                await emit(.state(.closed))
            default:
                break
            }
        }
    }
}

private actor PresentationNoAudioCaptureDriver: LiveAudioCaptureDriving {
    private(set) var starts = 0

    func start(
        _ receive: @escaping @Sendable (Result<Data, Error>) -> Void
    ) async throws { starts += 1 }
    func stop() async {}
}

private let presentationSyntheticOffer = """
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

@MainActor
private final class PresentationTestPeer: LiveAudioPeer {
    nonisolated init() {}

    func prepareOffer() async throws -> String { presentationSyntheticOffer }
    func applyAnswerAndWaitForConnected(_ answer: String) async throws {}
    func setMuted(_ muted: Bool) async throws {}
    func close() async {}
}

private actor AttachedPeerFactoryProbe {
    private(set) var created = 0
    private(set) var released = 0

    func makePeer() async -> any LiveAudioPeer {
        created += 1
        return await MainActor.run { PresentationTestPeer() }
    }

    func releasePeer() {
        released += 1
    }
}

@MainActor
private final class MuteFailurePresentationPeer: LiveAudioPeer {
    private(set) var closeCalls = 0

    func prepareOffer() async throws -> String { presentationSyntheticOffer }
    func applyAnswerAndWaitForConnected(_ answer: String) async throws {}
    func setMuted(_ muted: Bool) async throws { throw LiveAudioPeerError.connectionFailed }
    func close() async { closeCalls += 1 }
}

private actor PresentationNoAudioPlaybackDriver: LiveAudioPlaybackDriving {
    private(set) var plays = 0
    private(set) var interrupts = 0

    func play(_ frame: LiveAudioFrame) async throws { plays += 1 }
    func interrupt() async { interrupts += 1 }
}
