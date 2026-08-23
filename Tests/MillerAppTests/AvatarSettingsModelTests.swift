import AppKit
import Foundation
import MillerAvatarCore
import MillerAvatarHost
import MillerStorage
import Testing
@testable import MillerApp

@Suite
struct AvatarSettingsModelTests {
    @Test
    @MainActor
    func loadRestoresPersistedEnablementSelectionAndUserMotionPreference() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 2)
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: true
            ),
            profiles: [profile],
            importMotion: { _, _, _ in
                .init(profileID: profileID, profileRevision: 3)
            }
        ))

        await model.load()

        #expect(model.isEnabled)
        #expect(model.selectedProfileID == profileID)
        #expect(model.reduceMotion)
        #expect(model.selectedProfile == profile)
    }

    @Test
    @MainActor
    func loadRestoresLipSyncAndNextImportQualityAndPersistsChanges() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 2)
        let writes = AvatarPresentationPreferenceRecorder()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: false,
                selectedProfileID: profileID,
                reduceMotion: false,
                mouthCuesEnabled: false,
                importQualityMode: AvatarAssetQualityMode.highQuality.rawValue
            ),
            profiles: [profile],
            setMouthCuesEnabled: { value in await writes.recordMouth(value) },
            setImportQualityMode: { value in await writes.recordQuality(value) },
            importMotion: { _, _, _ in
                .init(profileID: profileID, profileRevision: 3)
            }
        ))

        await model.load()

        #expect(!model.mouthCuesEnabled)
        #expect(model.importQualityMode == .highQuality)
        #expect(await model.setMouthCuesEnabled(true))
        #expect(await model.setImportQualityMode(.lightweight))
        #expect(model.mouthCuesEnabled)
        #expect(model.importQualityMode == .lightweight)
        #expect(await writes.values == [
            .mouth(true),
            .quality(.lightweight),
        ])
    }

    @Test
    @MainActor
    func importUsesSelectedQualityOnceWithoutReclassifyingExistingProfiles() async {
        let profileID = UUID()
        let profile = makeProfile(
            id: profileID,
            revision: 2,
            qualityMode: .lightweight
        )
        let imported = AvatarCommittedProfileChange(
            profileID: UUID(),
            profileRevision: 1
        )
        let qualities = AvatarQualityRecorder()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: false,
                importQualityMode: AvatarAssetQualityMode.highQuality.rawValue
            ),
            profiles: [profile],
            importModelWithQuality: { _, _, quality in
                await qualities.record(quality)
                return imported
            },
            importMotion: { _, _, _ in
                .init(profileID: profileID, profileRevision: 3)
            }
        ))

        await model.load()
        #expect(model.selectedProfile?.qualityMode == .lightweight)
        #expect(await model.importModel(
            at: URL(fileURLWithPath: "/tmp/quality.vrm"),
            displayName: "Quality"
        ) == imported)
        #expect(await qualities.values == [.highQuality])
        #expect(model.profiles.first?.qualityMode == .lightweight)
    }

    @Test
    @MainActor
    func importCapturesQualityBeforeAnInFlightOperationCanChangeTheSelection() async {
        let profile = makeProfile(id: UUID(), revision: 2)
        let imported = AvatarCommittedProfileChange(
            profileID: UUID(),
            profileRevision: 1
        )
        let qualities = AvatarQualityRecorder()
        let gate = AvatarSettingsGate()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: false,
                selectedProfileID: nil,
                reduceMotion: false,
                importQualityMode: AvatarAssetQualityMode.highQuality.rawValue
            ),
            profiles: [profile],
            importModelWithQuality: { _, _, quality in
                await qualities.record(quality)
                await gate.waitUntilReleased()
                return imported
            },
            importMotion: { _, _, _ in
                .init(profileID: profile.id, profileRevision: 3)
            }
        ))

        await model.load()
        let pendingImport = Task {
            await model.importModel(
                at: URL(fileURLWithPath: "/tmp/quality.vrm"),
                displayName: "Quality"
            )
        }
        await gate.waitUntilEntered()
        #expect(await model.setImportQualityMode(.lightweight))
        await gate.release()

        #expect(await pendingImport.value == imported)
        #expect(await qualities.values == [.highQuality])
    }

    @Test
    @MainActor
    func loadRestoresProfileLocalPaneWidthAndUsesDefaultWhenMissing() async {
        let profileID = UUID()
        let otherProfileID = UUID()
        let profile = makeProfile(id: profileID, revision: 2)
        let otherProfile = makeProfile(id: otherProfileID, revision: 2)
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: false
            ),
            profiles: [profile, otherProfile],
            paneWidths: [profileID: 340],
            importMotion: { _, _, _ in
                .init(profileID: profileID, profileRevision: 3)
            }
        ))

        await model.load()

        #expect(model.paneWidth(for: profileID) == 340)
        #expect(model.selectedPaneWidth == 340)
        #expect(model.paneWidth(for: otherProfileID) == AvatarPaneWidth.defaultValue)
    }

    @Test
    @MainActor
    func paneWidthMutationClampsInvalidValuesAndPersistsByProfile() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 2)
        let writes = AvatarPaneWidthWriteRecorder()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: false
            ),
            profiles: [profile],
            setPaneWidth: { id, width in await writes.record(id: id, width: width) },
            importMotion: { _, _, _ in
                .init(profileID: profileID, profileRevision: 3)
            }
        ))

        #expect(await model.setPaneWidth(999, for: profileID))
        #expect(model.paneWidth(for: profileID) == AvatarPaneWidth.maximum)
        #expect(await model.setPaneWidth(.nan, for: profileID))
        #expect(model.paneWidth(for: profileID) == AvatarPaneWidth.defaultValue)
        #expect(await writes.values == [
            .init(id: profileID, width: AvatarPaneWidth.maximum),
            .init(id: profileID, width: AvatarPaneWidth.defaultValue),
        ])
    }

    @Test
    @MainActor
    func authoritativeProfileRefreshPrunesRemovedProfilePaneWidths() async {
        let retainedID = UUID()
        let removedID = UUID()
        let retained = makeProfile(id: retainedID, revision: 2)
        let replacements = AvatarPaneWidthReplacementRecorder()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: retainedID,
                reduceMotion: false
            ),
            profiles: [retained],
            paneWidths: [retainedID: 240, removedID: 320],
            replacePaneWidths: { values in await replacements.record(values) },
            importMotion: { _, _, _ in
                .init(profileID: retainedID, profileRevision: 3)
            }
        ))

        await model.load()
        #expect(model.paneWidths == [retainedID: 240])
        #expect(await replacements.values == [[retainedID: 240]])
    }

    @Test
    @MainActor
    func reducedMotionComposesUserAndSystemSettings() {
        #expect(!AvatarSettingsModel.effectiveReducedMotion(
            userReduceMotion: false,
            systemReduceMotion: false
        ))
        #expect(AvatarSettingsModel.effectiveReducedMotion(
            userReduceMotion: true,
            systemReduceMotion: false
        ))
        #expect(AvatarSettingsModel.effectiveReducedMotion(
            userReduceMotion: false,
            systemReduceMotion: true
        ))
    }

    @Test
    @MainActor
    func successfulMutationEmitsExactlyOneBoundedChange() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 3)
        var changes: [AvatarCommittedProfileChange] = []
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: false
            ),
            profiles: [profile],
            importMotion: { _, _, _ in
                .init(profileID: profileID, profileRevision: 4)
            }
        ))
        model.onCommittedProfileChange = { changes.append($0) }

        let result = await model.importMotion(
            profileID: profileID,
            at: URL(fileURLWithPath: "/tmp/source.vrma"),
            displayName: "Wave"
        )

        #expect(result == .init(profileID: profileID, profileRevision: 4))
        #expect(changes == [.init(profileID: profileID, profileRevision: 4)])
    }

    @Test
    @MainActor
    func failedMutationEmitsNoChangeAndLeavesActiveSelectionStable() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 3)
        var changes: [AvatarCommittedProfileChange] = []
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: true
            ),
            profiles: [profile],
            importMotion: { _, _, _ in throw AvatarSettingsError.unavailable }
        ))
        model.onCommittedProfileChange = { changes.append($0) }
        await model.load()

        let result = await model.importMotion(
            profileID: profileID,
            at: URL(fileURLWithPath: "/tmp/rejected.vrma"),
            displayName: "Rejected"
        )

        #expect(result == nil)
        #expect(changes.isEmpty)
        #expect(model.selectedProfileID == profileID)
        #expect(model.profiles == [profile])
        #expect(model.effectiveReducedMotion)
    }

    @Test
    @MainActor
    func importingModelSelectsItThroughTheTypedPreferenceBoundary() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 4)
        let writes = AvatarPreferenceWriteRecorder()
        let change = AvatarCommittedProfileChange(
            profileID: profileID,
            profileRevision: profile.profileRevision
        )
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: nil,
                reduceMotion: false
            ),
            profiles: [profile],
            setSelectedProfile: { value in await writes.recordSelected(value) },
            importModelWithQuality: { _, _, _ in change },
            importMotion: { _, _, _ in throw AvatarSettingsError.unavailable }
        ))

        #expect(await model.importModel(
            at: URL(fileURLWithPath: "/tmp/synthetic.vrm"),
            displayName: "Synthetic"
        ) == change)
        #expect(model.selectedProfileID == profileID)
        #expect(await writes.values == [.selected(profileID)])
    }

    @Test
    @MainActor
    func failedAndQuarantinedMotionSummariesRemainVisibleWhileConsumerActionsForward() async {
        let profileID = UUID()
        let failedMotionID = UUID()
        let quarantinedMotionID = UUID()
        let failedMotion = AvatarMotionSummary(
            id: failedMotionID,
            displayName: "Rejected motion",
            capturedByteCount: 3,
            consecutiveLoadFailures: 1,
            lastFailure: .motionRejected
        )
        let quarantinedMotion = AvatarMotionSummary(
            id: quarantinedMotionID,
            displayName: "Quarantined motion",
            capturedByteCount: 3,
            consecutiveLoadFailures: 3,
            lastFailure: .resourceLimit
        )
        let profile = AvatarProfileSummary(
            id: profileID,
            displayName: "Failed model",
            profileRevision: 8,
            modelCapturedByteCount: 4,
            modelConsecutiveLoadFailures: 1,
            modelStatus: .quarantined,
            motions: [failedMotion, quarantinedMotion],
            motionBindings: [.speaking: failedMotionID]
        )
        let calls = AvatarMutationRecorder()
        let change = AvatarCommittedProfileChange(
            profileID: profileID,
            profileRevision: profile.profileRevision
        )
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: false
            ),
            profiles: [profile],
            renameProfile: { _, _ in await calls.record("renameProfile"); return change },
            removeProfile: { _ in await calls.record("removeProfile"); return change },
            importMotion: { _, _, _ in throw AvatarSettingsError.unavailable },
            renameMotion: { _, _, _ in await calls.record("renameMotion"); return change },
            removeMotion: { _, _ in await calls.record("removeMotion"); return change },
            bindMotion: { _, _, _ in await calls.record("bindMotion"); return change },
            retryProfile: { _ in await calls.record("retryProfile"); return change },
            retryMotion: { _, _ in await calls.record("retryMotion"); return change }
        ))

        await model.load()
        #expect(model.profiles == [profile])
        #expect(model.profiles[0].modelConsecutiveLoadFailures == 1)
        #expect(model.profiles[0].motions.map { $0.isQuarantined } == [false, true])

        _ = await model.renameProfile(id: profileID, displayName: "Renamed")
        _ = await model.removeProfile(id: profileID)
        _ = await model.renameMotion(
            profileID: profileID,
            motionID: failedMotionID,
            displayName: "Renamed motion"
        )
        _ = await model.removeMotion(profileID: profileID, motionID: failedMotionID)
        _ = await model.bindMotion(
            profileID: profileID,
            role: AvatarMotionRole.speaking,
            motionID: quarantinedMotionID
        )
        _ = await model.retryProfile(id: profileID)
        _ = await model.retryMotion(profileID: profileID, motionID: quarantinedMotionID)

        #expect(await calls.values == [
            "renameProfile",
            "removeProfile",
            "renameMotion",
            "removeMotion",
            "bindMotion",
            "retryProfile",
            "retryMotion",
        ])
    }

    @Test
    @MainActor
    func preferenceLoadFailureIsPresentedWhileProfilesStillRefresh() async {
        let profile = makeProfile(id: UUID(), revision: 3)
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profile.id,
                reduceMotion: false
            ),
            profiles: [profile],
            loadPreferences: { throw AvatarSettingsError.unavailable },
            importMotion: { _, _, _ in
                .init(profileID: profile.id, profileRevision: 4)
            }
        ))

        await model.load()

        #expect(model.status == "Avatar preferences unavailable")
        #expect(model.profiles == [profile])
        #expect(!model.isEnabled)
    }

    @Test
    @MainActor
    func concurrentPreferenceChangesUseDistinctWritesAndPreserveBothValues() async {
        let writes = AvatarPreferenceWriteRecorder()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: false,
                selectedProfileID: nil,
                reduceMotion: false
            ),
            profiles: [],
            setEnabled: { value in await writes.recordEnabled(value) },
            setReduceMotion: { value in await writes.recordReduceMotion(value) },
            importMotion: { _, _, _ in throw AvatarSettingsError.unavailable }
        ))

        async let enabled = model.setEnabled(true)
        async let reduced = model.setReduceMotion(true)

        #expect(await enabled)
        #expect(await reduced)
        #expect(model.isEnabled)
        #expect(model.reduceMotion)
        #expect(Set(await writes.values) == Set([
            .enabled(true),
            .reduceMotion(true),
        ]))
    }

    @Test
    @MainActor
    func resetFenceWaitsForInFlightWorkRejectsNewWorkAndResumesAfterFailure() async {
        let saveGate = AvatarSettingsGate()
        let resetGate = AvatarSettingsGate()
        let writes = AvatarPreferenceWriteRecorder()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: false,
                selectedProfileID: nil,
                reduceMotion: false
            ),
            profiles: [],
            setEnabled: { value in
                await saveGate.waitUntilReleased()
                await writes.recordEnabled(value)
            },
            setReduceMotion: { value in await writes.recordReduceMotion(value) },
            importMotion: { _, _, _ in throw AvatarSettingsError.unavailable }
        ))
        model.setSystemReduceMotion(true)

        let pendingSave = Task { await model.setEnabled(true) }
        await saveGate.waitUntilEntered()
        let pendingReset = Task {
            await model.withResetFence {
                await resetGate.waitUntilReleased()
                return false
            }
        }
        while !model.isResetting { await Task.yield() }

        model.setSystemReduceMotion(false)
        #expect(model.systemReduceMotion)
        #expect(await model.setReduceMotion(true) == false)
        await saveGate.release()
        #expect(await pendingSave.value == false)
        #expect(!model.isEnabled)

        await resetGate.release()
        #expect(await pendingReset.value == false)
        #expect(!model.isResetting)
        #expect(!model.systemReduceMotion)
        #expect(await model.setEnabled(true))
        #expect(model.isEnabled)
    }

    @Test
    @MainActor
    func fencedPrivacyResetClearsMetadataAndPreferencesOnlyAfterEachStepSucceeds() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 2)
        let calls = AvatarResetRecorder()
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: true,
                mouthCuesEnabled: false,
                importQualityMode: AvatarAssetQualityMode.highQuality.rawValue
            ),
            profiles: [profile],
            clearAvatarPreferences: { await calls.record("preferences") },
            resetMetadata: { await calls.record("metadata") },
            importMotion: { _, _, _ in throw AvatarSettingsError.unavailable }
        ))

        await model.load()
        #expect(!model.mouthCuesEnabled)
        #expect(model.importQualityMode == .highQuality)
        let result = await model.withResetFence {
            (
                await model.resetMetadataWhileFenced(),
                await model.clearPreferencesAfterReopenWhileFenced()
            )
        }

        #expect(result?.0.succeeded == true)
        #expect(result?.1.succeeded == true)
        #expect(await calls.values == ["metadata", "preferences"])
        #expect(model.profiles.isEmpty)
        #expect(!model.isEnabled)
        #expect(model.selectedProfileID == nil)
        #expect(!model.reduceMotion)
        #expect(model.mouthCuesEnabled)
        #expect(model.importQualityMode == .lightweight)
    }

    @Test
    @MainActor
    func fencedPrivacyResetReportsFailureAndReloadsAuthoritativeState() async {
        let profileID = UUID()
        let profile = makeProfile(id: profileID, revision: 2)
        let model = AvatarSettingsModel(dependencies: dependencies(
            preferences: .init(
                enabled: true,
                selectedProfileID: profileID,
                reduceMotion: true
            ),
            profiles: [profile],
            clearAvatarPreferences: {
                throw AvatarSettingsError.unavailable
            },
            resetMetadata: {
                throw AvatarSettingsError.unavailable
            },
            importMotion: { _, _, _ in throw AvatarSettingsError.unavailable }
        ))

        await model.load()
        let result = await model.withResetFence {
            (
                await model.resetMetadataWhileFenced(),
                await model.clearPreferencesAfterReopenWhileFenced()
            )
        }

        #expect(result?.0.succeeded == false)
        #expect(result?.1.succeeded == false)
        #expect(model.profiles == [profile])
        #expect(model.isEnabled)
        #expect(model.selectedProfileID == profileID)
        #expect(model.reduceMotion)
    }

    @Test
    @MainActor
    func persistentSystemReducedMotionSourceRefreshesFromInjectedNotification() async {
        let notifications = NotificationCenter()
        let systemValue = AvatarLockedBool(false)
        let source = SystemReducedMotionSource(
            read: { systemValue.value },
            notificationCenter: notifications,
            notificationName: .avatarSystemReduceMotionChanged
        )

        #expect(!source.value)
        source.start()
        systemValue.value = true
        notifications.post(name: .avatarSystemReduceMotionChanged, object: nil)
        await Task.yield()

        #expect(source.value)
    }

    private func makeProfile(
        id: UUID,
        revision: UInt64,
        qualityMode: AvatarAssetQualityMode = .lightweight
    ) -> AvatarProfileSummary {
        AvatarProfileSummary(
            id: id,
            displayName: "Miller",
            profileRevision: revision,
            modelCapturedByteCount: 12,
            modelConsecutiveLoadFailures: 0,
            modelStatus: .available,
            motions: [],
            motionBindings: [:],
            qualityMode: qualityMode
        )
    }

    private func dependencies(
        preferences: AvatarPreferences,
        profiles: [AvatarProfileSummary],
        paneWidths: [UUID: Double] = [:],
        loadPreferences: (@Sendable () async throws -> AvatarPreferences)? = nil,
        setEnabled: (@Sendable (Bool) async throws -> Void)? = nil,
        setSelectedProfile: (@Sendable (UUID?) async throws -> Void)? = nil,
        setReduceMotion: (@Sendable (Bool) async throws -> Void)? = nil,
        setMouthCuesEnabled: (@Sendable (Bool) async throws -> Void)? = nil,
        setImportQualityMode: (@Sendable (AvatarAssetQualityMode) async throws -> Void)? = nil,
        loadPaneWidths: (@Sendable () async throws -> [UUID: Double])? = nil,
        setPaneWidth: (@Sendable (UUID, Double) async throws -> Void)? = nil,
        replacePaneWidths: (@Sendable ([UUID: Double]) async throws -> Void)? = nil,
        clearAvatarPreferences: (@Sendable () async throws -> Void)? = nil,
        resetMetadata: (@Sendable () async throws -> Void)? = nil,
        importModelWithQuality: (@Sendable (URL, String, AvatarAssetQualityMode) async throws -> AvatarCommittedProfileChange)? = nil,
        renameProfile: (@Sendable (UUID, String) async throws -> AvatarCommittedProfileChange?)? = nil,
        removeProfile: (@Sendable (UUID) async throws -> AvatarCommittedProfileChange?)? = nil,
        importMotion: @escaping @Sendable (UUID, URL, String) async throws -> AvatarCommittedProfileChange?,
        renameMotion: (@Sendable (UUID, UUID, String) async throws -> AvatarCommittedProfileChange?)? = nil,
        removeMotion: (@Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange?)? = nil,
        bindMotion: (@Sendable (UUID, AvatarMotionRole, UUID?) async throws -> AvatarCommittedProfileChange?)? = nil,
        retryProfile: (@Sendable (UUID) async throws -> AvatarCommittedProfileChange?)? = nil,
        retryMotion: (@Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange?)? = nil
    ) -> AvatarSettingsDependencies {
        let resolvedLoadPreferences: @Sendable () async throws -> AvatarPreferences =
            loadPreferences ?? { preferences }
        let resolvedSetEnabled: @Sendable (Bool) async throws -> Void =
            setEnabled ?? { _ in }
        let resolvedSetSelectedProfile: @Sendable (UUID?) async throws -> Void =
            setSelectedProfile ?? { _ in }
        let resolvedSetReduceMotion: @Sendable (Bool) async throws -> Void =
            setReduceMotion ?? { _ in }
        let resolvedSetMouthCuesEnabled: @Sendable (Bool) async throws -> Void =
            setMouthCuesEnabled ?? { _ in }
        let resolvedSetImportQualityMode: @Sendable (AvatarAssetQualityMode) async throws -> Void =
            setImportQualityMode ?? { _ in }
        let resolvedLoadPaneWidths: @Sendable () async throws -> [UUID: Double] =
            loadPaneWidths ?? { paneWidths }
        let resolvedSetPaneWidth: @Sendable (UUID, Double) async throws -> Void =
            setPaneWidth ?? { _, _ in }
        let resolvedReplacePaneWidths: @Sendable ([UUID: Double]) async throws -> Void =
            replacePaneWidths ?? { _ in }
        let resolvedClearAvatarPreferences: @Sendable () async throws -> Void =
            clearAvatarPreferences ?? { }
        let resolvedListProfiles: @Sendable () async throws -> [AvatarProfileSummary] =
            { profiles }
        let resolvedImportModelWithQuality: @Sendable (URL, String, AvatarAssetQualityMode) async throws -> AvatarCommittedProfileChange =
            importModelWithQuality ?? { _, _, _ in
                throw AvatarSettingsError.unavailable
            }
        let resolvedRenameProfile: @Sendable (UUID, String) async throws -> AvatarCommittedProfileChange? =
            renameProfile ?? { _, _ in throw AvatarSettingsError.unavailable }
        let resolvedRemoveProfile: @Sendable (UUID) async throws -> AvatarCommittedProfileChange? =
            removeProfile ?? { _ in throw AvatarSettingsError.unavailable }
        let resolvedRenameMotion: @Sendable (UUID, UUID, String) async throws -> AvatarCommittedProfileChange? =
            renameMotion ?? { _, _, _ in throw AvatarSettingsError.unavailable }
        let resolvedRemoveMotion: @Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange? =
            removeMotion ?? { _, _ in throw AvatarSettingsError.unavailable }
        let resolvedBindMotion: @Sendable (UUID, AvatarMotionRole, UUID?) async throws -> AvatarCommittedProfileChange? =
            bindMotion ?? { _, _, _ in throw AvatarSettingsError.unavailable }
        let resolvedRetryProfile: @Sendable (UUID) async throws -> AvatarCommittedProfileChange? =
            retryProfile ?? { _ in throw AvatarSettingsError.unavailable }
        let resolvedRetryMotion: @Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange? =
            retryMotion ?? { _, _ in throw AvatarSettingsError.unavailable }
        let resolvedResetMetadata: @Sendable () async throws -> Void =
            resetMetadata ?? { }
        return AvatarSettingsDependencies(
            loadPreferences: resolvedLoadPreferences,
            setEnabled: resolvedSetEnabled,
            setSelectedProfile: resolvedSetSelectedProfile,
            setReduceMotion: resolvedSetReduceMotion,
            setMouthCuesEnabled: resolvedSetMouthCuesEnabled,
            setImportQualityMode: resolvedSetImportQualityMode,
            loadPaneWidths: resolvedLoadPaneWidths,
            setPaneWidth: resolvedSetPaneWidth,
            replacePaneWidths: resolvedReplacePaneWidths,
            clearAvatarPreferences: resolvedClearAvatarPreferences,
            listProfiles: resolvedListProfiles,
            importModelWithQuality: resolvedImportModelWithQuality,
            renameProfile: resolvedRenameProfile,
            removeProfile: resolvedRemoveProfile,
            importMotion: importMotion,
            renameMotion: resolvedRenameMotion,
            removeMotion: resolvedRemoveMotion,
            bindMotion: resolvedBindMotion,
            retryProfile: resolvedRetryProfile,
            retryMotion: resolvedRetryMotion,
            resetMetadata: resolvedResetMetadata
        )
    }
}

private struct AvatarPaneWidthWrite: Equatable, Sendable {
    let id: UUID
    let width: Double
}

private actor AvatarPaneWidthWriteRecorder {
    private(set) var values: [AvatarPaneWidthWrite] = []

    func record(id: UUID, width: Double) {
        values.append(.init(id: id, width: width))
    }
}

private actor AvatarPaneWidthReplacementRecorder {
    private(set) var values: [[UUID: Double]] = []

    func record(_ value: [UUID: Double]) {
        values.append(value)
    }
}

private enum AvatarPreferenceWrite: Hashable, Sendable {
    case enabled(Bool)
    case selected(UUID?)
    case reduceMotion(Bool)
}

private enum AvatarPresentationPreferenceWrite: Equatable, Sendable {
    case mouth(Bool)
    case quality(AvatarAssetQualityMode)
}

private actor AvatarPresentationPreferenceRecorder {
    private(set) var values: [AvatarPresentationPreferenceWrite] = []

    func recordMouth(_ value: Bool) {
        values.append(.mouth(value))
    }

    func recordQuality(_ value: AvatarAssetQualityMode) {
        values.append(.quality(value))
    }
}

private actor AvatarQualityRecorder {
    private(set) var values: [AvatarAssetQualityMode] = []

    func record(_ value: AvatarAssetQualityMode) {
        values.append(value)
    }
}

private actor AvatarPreferenceWriteRecorder {
    private(set) var values: [AvatarPreferenceWrite] = []

    func recordEnabled(_ value: Bool) {
        values.append(.enabled(value))
    }

    func recordReduceMotion(_ value: Bool) {
        values.append(.reduceMotion(value))
    }

    func recordSelected(_ value: UUID?) {
        values.append(.selected(value))
    }
}

private actor AvatarMutationRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private actor AvatarResetRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private final class AvatarLockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        storage = value
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private actor AvatarSettingsGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private extension Notification.Name {
    static let avatarSystemReduceMotionChanged = Self(
        "avatar-system-reduce-motion-changed"
    )
}
