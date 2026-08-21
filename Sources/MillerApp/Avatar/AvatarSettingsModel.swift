import Foundation
import MillerAvatarCore
import MillerAvatarHost
import MillerStorage
import SwiftUI

enum AvatarPaneWidth {
    static let minimum: Double = 160
    static let maximum: Double = 400
    static let defaultValue: Double = 200

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, minimum), maximum)
    }
}

struct AvatarSettingsDependencies: Sendable {
    let loadPreferences: @Sendable () async throws -> AvatarPreferences
    let setEnabled: @Sendable (Bool) async throws -> Void
    let setSelectedProfile: @Sendable (UUID?) async throws -> Void
    let setReduceMotion: @Sendable (Bool) async throws -> Void
    let loadPaneWidths: @Sendable () async throws -> [UUID: Double]
    let setPaneWidth: @Sendable (UUID, Double) async throws -> Void
    let replacePaneWidths: @Sendable ([UUID: Double]) async throws -> Void
    let clearAvatarPreferences: @Sendable () async throws -> Void
    let listProfiles: @Sendable () async throws -> [AvatarProfileSummary]
    let importModel: @Sendable (URL, String) async throws -> AvatarCommittedProfileChange
    let renameProfile: @Sendable (UUID, String) async throws -> AvatarCommittedProfileChange?
    let removeProfile: @Sendable (UUID) async throws -> AvatarCommittedProfileChange?
    let importMotion: @Sendable (UUID, URL, String) async throws -> AvatarCommittedProfileChange?
    let renameMotion: @Sendable (UUID, UUID, String) async throws -> AvatarCommittedProfileChange?
    let removeMotion: @Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange?
    let bindMotion: @Sendable (UUID, AvatarMotionRole, UUID?) async throws -> AvatarCommittedProfileChange?
    let retryProfile: @Sendable (UUID) async throws -> AvatarCommittedProfileChange?
    let retryMotion: @Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange?
    let resetMetadata: @Sendable () async throws -> Void

    static let unavailable = Self(
        loadPreferences: {
            AvatarPreferences(enabled: false, selectedProfileID: nil, reduceMotion: false)
        },
        setEnabled: { _ in },
        setSelectedProfile: { _ in },
        setReduceMotion: { _ in },
        loadPaneWidths: { [:] },
        setPaneWidth: { _, _ in },
        replacePaneWidths: { _ in },
        clearAvatarPreferences: { throw AvatarSettingsError.unavailable },
        listProfiles: { [] },
        importModel: { _, _ in throw AvatarSettingsError.unavailable },
        renameProfile: { _, _ in throw AvatarSettingsError.unavailable },
        removeProfile: { _ in throw AvatarSettingsError.unavailable },
        importMotion: { _, _, _ in throw AvatarSettingsError.unavailable },
        renameMotion: { _, _, _ in throw AvatarSettingsError.unavailable },
        removeMotion: { _, _ in throw AvatarSettingsError.unavailable },
        bindMotion: { _, _, _ in throw AvatarSettingsError.unavailable },
        retryProfile: { _ in throw AvatarSettingsError.unavailable },
        retryMotion: { _, _ in throw AvatarSettingsError.unavailable },
        resetMetadata: { throw AvatarSettingsError.unavailable }
    )

    init(
        loadPreferences: @escaping @Sendable () async throws -> AvatarPreferences,
        setEnabled: @escaping @Sendable (Bool) async throws -> Void,
        setSelectedProfile: @escaping @Sendable (UUID?) async throws -> Void,
        setReduceMotion: @escaping @Sendable (Bool) async throws -> Void,
        loadPaneWidths: @escaping @Sendable () async throws -> [UUID: Double],
        setPaneWidth: @escaping @Sendable (UUID, Double) async throws -> Void,
        replacePaneWidths: @escaping @Sendable ([UUID: Double]) async throws -> Void,
        clearAvatarPreferences: @escaping @Sendable () async throws -> Void,
        listProfiles: @escaping @Sendable () async throws -> [AvatarProfileSummary],
        importModel: @escaping @Sendable (URL, String) async throws -> AvatarCommittedProfileChange,
        renameProfile: @escaping @Sendable (UUID, String) async throws -> AvatarCommittedProfileChange?,
        removeProfile: @escaping @Sendable (UUID) async throws -> AvatarCommittedProfileChange?,
        importMotion: @escaping @Sendable (UUID, URL, String) async throws -> AvatarCommittedProfileChange?,
        renameMotion: @escaping @Sendable (UUID, UUID, String) async throws -> AvatarCommittedProfileChange?,
        removeMotion: @escaping @Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange?,
        bindMotion: @escaping @Sendable (UUID, AvatarMotionRole, UUID?) async throws -> AvatarCommittedProfileChange?,
        retryProfile: @escaping @Sendable (UUID) async throws -> AvatarCommittedProfileChange?,
        retryMotion: @escaping @Sendable (UUID, UUID) async throws -> AvatarCommittedProfileChange?,
        resetMetadata: @escaping @Sendable () async throws -> Void
    ) {
        self.loadPreferences = loadPreferences
        self.setEnabled = setEnabled
        self.setSelectedProfile = setSelectedProfile
        self.setReduceMotion = setReduceMotion
        self.loadPaneWidths = loadPaneWidths
        self.setPaneWidth = setPaneWidth
        self.replacePaneWidths = replacePaneWidths
        self.clearAvatarPreferences = clearAvatarPreferences
        self.listProfiles = listProfiles
        self.importModel = importModel
        self.renameProfile = renameProfile
        self.removeProfile = removeProfile
        self.importMotion = importMotion
        self.renameMotion = renameMotion
        self.removeMotion = removeMotion
        self.bindMotion = bindMotion
        self.retryProfile = retryProfile
        self.retryMotion = retryMotion
        self.resetMetadata = resetMetadata
    }

    init(
        adapter: MillerAvatarProfileAdapter,
        preferences: SQLitePreferenceRepository
    ) {
        self.init(
            loadPreferences: { try await preferences.avatarPreferences() },
            setEnabled: { value in
                try await preferences.set(value, for: .avatarEnabled)
            },
            setSelectedProfile: { value in
                try await preferences.set(value, for: .selectedAvatarProfileID)
            },
            setReduceMotion: { value in
                try await preferences.set(value, for: .reduceAvatarMotion)
            },
            loadPaneWidths: { try await preferences.avatarPaneWidths() },
            setPaneWidth: { profileID, width in
                try await preferences.setAvatarPaneWidth(width, for: profileID)
            },
            replacePaneWidths: { values in
                try await preferences.replaceAvatarPaneWidths(values)
            },
            clearAvatarPreferences: {
                try await preferences.delete(.avatarEnabled)
                try await preferences.delete(.selectedAvatarProfileID)
                try await preferences.delete(.reduceAvatarMotion)
                try await preferences.delete(.avatarPaneWidths)
            },
            listProfiles: { try await adapter.list() },
            importModel: { url, displayName in
                try await adapter.importModel(at: url, displayName: displayName)
            },
            renameProfile: { id, displayName in
                try await adapter.rename(id: id, displayName: displayName)
            },
            removeProfile: { id in try await adapter.remove(id: id) },
            importMotion: { profileID, url, displayName in
                try await adapter.importMotion(
                    profileID: profileID,
                    at: url,
                    displayName: displayName
                )
            },
            renameMotion: { profileID, motionID, displayName in
                try await adapter.renameMotion(
                    profileID: profileID,
                    motionID: motionID,
                    displayName: displayName
                )
            },
            removeMotion: { profileID, motionID in
                try await adapter.removeMotion(
                    profileID: profileID,
                    motionID: motionID
                )
            },
            bindMotion: { profileID, role, motionID in
                try await adapter.bindMotion(
                    profileID: profileID,
                    role: role,
                    motionID: motionID
                )
            },
            retryProfile: { id in try await adapter.retry(id: id) },
            retryMotion: { profileID, motionID in
                try await adapter.retryMotion(
                    profileID: profileID,
                    motionID: motionID
                )
            },
            resetMetadata: { try await adapter.resetMetadata() }
        )
    }
}

enum AvatarSettingsError: Error, Equatable, Sendable {
    case unavailable
    case resetInProgress
}

@MainActor
final class AvatarSettingsModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var reduceMotion = false
    @Published private(set) var paneWidths: [UUID: Double] = [:]
    @Published private(set) var profiles: [AvatarProfileSummary] = []
    @Published private(set) var status = ""
    @Published private(set) var runtimeStatus = "Avatar disabled"
    @Published private(set) var runtimeRetryAvailable = false
    @Published private(set) var isBusy = false
    @Published private(set) var isResetting = false
    @Published private(set) var resetEpoch = 0

    private(set) var systemReduceMotion: Bool
    private let dependencies: AvatarSettingsDependencies
    private let preferenceWriteQueue = AvatarPreferenceWriteQueue()
    private var operationGeneration: UInt64 = 0
    private var inFlightOperations = 0
    private var resetWaiters: [CheckedContinuation<Void, Never>] = []
    private var preferenceGeneration: UInt64 = 0
    private var latestPreferenceOperation: [AvatarPreferenceField: UInt64] = [:]
    private var pendingSystemReduceMotion: Bool?
    var onCommittedProfileChange: ((AvatarCommittedProfileChange) -> Void)?
    var onStateChange: (() -> Void)?
    var onRuntimeRetry: (() -> Void)?

    init(
        dependencies: AvatarSettingsDependencies = .unavailable,
        systemReduceMotion: Bool = false
    ) {
        self.dependencies = dependencies
        self.systemReduceMotion = systemReduceMotion
    }

    convenience init(
        adapter: MillerAvatarProfileAdapter,
        preferences: SQLitePreferenceRepository,
        systemReduceMotion: Bool = false
    ) {
        self.init(
            dependencies: AvatarSettingsDependencies(
                adapter: adapter,
                preferences: preferences
            ),
            systemReduceMotion: systemReduceMotion
        )
    }

    var effectiveReducedMotion: Bool {
        Self.effectiveReducedMotion(
            userReduceMotion: reduceMotion,
            systemReduceMotion: systemReduceMotion
        )
    }
    var selectedProfile: AvatarProfileSummary? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    var selectedPaneWidth: Double {
        guard let selectedProfileID else { return AvatarPaneWidth.defaultValue }
        return paneWidth(for: selectedProfileID)
    }

    func paneWidth(for profileID: UUID) -> Double {
        AvatarPaneWidth.normalized(paneWidths[profileID] ?? AvatarPaneWidth.defaultValue)
    }

    static func effectiveReducedMotion(
        userReduceMotion: Bool,
        systemReduceMotion: Bool
    ) -> Bool {
        userReduceMotion || systemReduceMotion
    }

    func setSystemReduceMotion(_ value: Bool) {
        if isResetting {
            pendingSystemReduceMotion = value
            return
        }
        systemReduceMotion = value
        onStateChange?()
    }

    func setRuntimeReadiness(_ readiness: AvatarReadiness, canRetry: Bool) {
        runtimeRetryAvailable = canRetry
        switch readiness {
        case .disabled:
            runtimeStatus = "Avatar disabled"
        case .starting:
            runtimeStatus = "Avatar starting"
        case .ready:
            runtimeStatus = "Avatar ready"
        case .unavailable(let code), .failed(let code):
            runtimeStatus = "Avatar unavailable (\(code.rawValue))"
        }
    }

    func retryRuntime() {
        guard runtimeRetryAvailable else { return }
        onRuntimeRetry?()
    }

    func load() async {
        guard !isBusy, let token = beginOperation() else { return }
        isBusy = true
        status = ""
        let loadedPreferenceGeneration = preferenceGeneration
        defer {
            isBusy = false
            endOperation()
        }
        var authoritativeProfiles: [AvatarProfileSummary]?

        do {
            let preferences = try await dependencies.loadPreferences()
            guard isCurrentOperation(token),
                  loadedPreferenceGeneration == preferenceGeneration
            else { return }
            apply(preferences)
        } catch {
            guard isCurrentOperation(token) else { return }
            status = "Avatar preferences unavailable"
        }

        do {
            let profiles = try await dependencies.listProfiles()
            guard isCurrentOperation(token) else { return }
            self.profiles = profiles
            authoritativeProfiles = profiles
        } catch {
            guard isCurrentOperation(token) else { return }
            status = Self.message(for: error, fallback: "Avatar profiles unavailable")
        }

        do {
            let paneWidths = try await dependencies.loadPaneWidths()
            guard isCurrentOperation(token) else { return }
            if let authoritativeProfiles {
                self.paneWidths = await self.prunedPaneWidths(
                    paneWidths,
                    profiles: authoritativeProfiles
                )
            } else {
                self.paneWidths = Self.normalizedPaneWidths(paneWidths)
            }
            onStateChange?()
        } catch {
            guard isCurrentOperation(token) else { return }
            self.paneWidths = [:]
        }
    }

    func refreshProfiles() async {
        guard let token = beginOperation() else { return }
        defer { endOperation() }
        do {
            let profiles = try await dependencies.listProfiles()
            guard isCurrentOperation(token) else { return }
            self.profiles = profiles
            await prunePaneWidths(for: profiles)
        } catch {
            guard isCurrentOperation(token) else { return }
            status = Self.message(for: error, fallback: "Avatar profiles unavailable")
        }
    }

    @discardableResult
    func setEnabled(_ value: Bool) async -> Bool {
        let save = dependencies.setEnabled
        return await persistPreference(
            .enabled,
            operation: { try await save(value) },
            apply: { self.isEnabled = value }
        )
    }

    @discardableResult
    func selectProfile(_ id: UUID?) async -> Bool {
        guard !isResetting else { return false }
        if let id, !profiles.contains(where: { $0.id == id }) {
            status = "Avatar profile is unavailable"
            return false
        }
        let save = dependencies.setSelectedProfile
        return await persistPreference(
            .selectedProfile,
            operation: { try await save(id) },
            apply: { self.selectedProfileID = id }
        )
    }

    @discardableResult
    func setReduceMotion(_ value: Bool) async -> Bool {
        let save = dependencies.setReduceMotion
        return await persistPreference(
            .reduceMotion,
            operation: { try await save(value) },
            apply: { self.reduceMotion = value }
        )
    }

    @discardableResult
    func setPaneWidth(_ value: Double, for profileID: UUID) async -> Bool {
        let normalized = AvatarPaneWidth.normalized(value)
        let save = dependencies.setPaneWidth
        return await persistPreference(
            .paneWidth(profileID),
            operation: { try await save(profileID, normalized) },
            apply: { self.paneWidths[profileID] = normalized }
        )
    }

    @discardableResult
    func importModel(at url: URL, displayName: String) async -> AvatarCommittedProfileChange? {
        await performMutation(
            "Avatar model could not be imported",
            operation: {
                try await self.dependencies.importModel(url, displayName)
            },
            afterSuccess: { change in
                _ = await self.persistSelectedProfile(change.profileID)
            },
            notifyBeforeAfterSuccess: true
        )
    }

    @discardableResult
    func renameProfile(id: UUID, displayName: String) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar profile could not be renamed") {
            try await self.dependencies.renameProfile(id, displayName)
        }
    }

    @discardableResult
    func removeProfile(id: UUID) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar profile could not be removed") {
            try await self.dependencies.removeProfile(id)
        } afterSuccess: { [weak self] _ in
            guard let self, self.selectedProfileID == id else { return }
            _ = await self.persistSelectedProfile(nil)
        }
    }

    @discardableResult
    func importMotion(
        profileID: UUID,
        at url: URL,
        displayName: String
    ) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar motion could not be imported") {
            try await self.dependencies.importMotion(profileID, url, displayName)
        }
    }

    @discardableResult
    func renameMotion(
        profileID: UUID,
        motionID: UUID,
        displayName: String
    ) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar motion could not be renamed") {
            try await self.dependencies.renameMotion(profileID, motionID, displayName)
        }
    }

    @discardableResult
    func removeMotion(
        profileID: UUID,
        motionID: UUID
    ) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar motion could not be removed") {
            try await self.dependencies.removeMotion(profileID, motionID)
        }
    }

    @discardableResult
    func bindMotion(
        profileID: UUID,
        role: AvatarMotionRole,
        motionID: UUID?
    ) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar motion binding could not be saved") {
            try await self.dependencies.bindMotion(profileID, role, motionID)
        }
    }

    @discardableResult
    func retryProfile(id: UUID) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar profile retry failed") {
            try await self.dependencies.retryProfile(id)
        }
    }

    @discardableResult
    func retryMotion(profileID: UUID, motionID: UUID) async -> AvatarCommittedProfileChange? {
        await performMutation("Avatar motion retry failed") {
            try await self.dependencies.retryMotion(profileID, motionID)
        }
    }

    func withResetFence<Result: Sendable>(
        _ operation: () async -> Result
    ) async -> Result? {
        guard !isResetting else { return nil }
        isResetting = true
        isBusy = true
        operationGeneration &+= 1
        resetEpoch &+= 1
        await waitForInFlightOperations()
        let result = await operation()
        isBusy = false
        isResetting = false
        if let pendingSystemReduceMotion {
            self.systemReduceMotion = pendingSystemReduceMotion
            self.pendingSystemReduceMotion = nil
            onStateChange?()
        }
        operationGeneration &+= 1
        resetEpoch &+= 1
        return result
    }

    /// Resets only package-owned Avatar metadata. This must be called from the
    /// privacy reset operation while `withResetFence` is active.
    func resetMetadataWhileFenced() async -> ResetRootResult {
        guard isResetting else {
            return .init(root: "avatar.metadata", succeeded: false)
        }
        do {
            try await dependencies.resetMetadata()
            profiles = []
            status = ""
            return .init(root: "avatar.metadata", succeeded: true)
        } catch {
            await reloadProfilesAuthoritatively()
            status = Self.message(for: error, fallback: "Avatar metadata reset failed")
            return .init(root: "avatar.metadata", succeeded: false)
        }
    }

    /// Clears Avatar preference keys after the preference repository has been
    /// reopened. This must be called from the same reset fence as metadata
    /// reset, after the repository reopen step has succeeded.
    func clearPreferencesAfterReopenWhileFenced() async -> ResetRootResult {
        guard isResetting else {
            return .init(root: "preferences.avatar.reset", succeeded: false)
        }
        do {
            try await dependencies.clearAvatarPreferences()
            isEnabled = false
            selectedProfileID = nil
            reduceMotion = false
            paneWidths = [:]
            preferenceGeneration &+= 1
            status = ""
            onStateChange?()
            return .init(root: "preferences.avatar.reset", succeeded: true)
        } catch {
            await reloadPreferencesAuthoritatively()
            status = Self.message(for: error, fallback: "Avatar preference reset failed")
            return .init(root: "preferences.avatar.reset", succeeded: false)
        }
    }

    private func persistSelectedProfile(_ id: UUID?) async -> Bool {
        let save = dependencies.setSelectedProfile
        return await persistPreference(
            .selectedProfile,
            operation: { try await save(id) },
            apply: { self.selectedProfileID = id }
        )
    }

    private func persistPreference(
        _ field: AvatarPreferenceField,
        operation: @escaping @Sendable () async throws -> Void,
        apply: @escaping () -> Void
    ) async -> Bool {
        guard let token = beginOperation() else { return false }
        preferenceGeneration &+= 1
        let generation = preferenceGeneration
        latestPreferenceOperation[field] = generation
        defer { endOperation() }
        do {
            try await preferenceWriteQueue.enqueue(operation)
            guard isCurrentOperation(token),
                  latestPreferenceOperation[field] == generation
            else { return false }
            apply()
            status = ""
            onStateChange?()
            return true
        } catch {
            guard isCurrentOperation(token) else { return false }
            status = "Avatar preference could not be saved"
            return false
        }
    }

    private func performMutation(
        _ failure: String,
        operation: () async throws -> AvatarCommittedProfileChange?,
        afterSuccess: ((AvatarCommittedProfileChange) async -> Void)? = nil,
        notifyBeforeAfterSuccess: Bool = false
    ) async -> AvatarCommittedProfileChange? {
        guard !isBusy, let token = beginOperation() else { return nil }
        isBusy = true
        status = ""
        defer {
            isBusy = false
            endOperation()
        }
        do {
            let change = try await operation()
            guard isCurrentOperation(token) else { return nil }
            guard let change else { return nil }
            if let profiles = try? await dependencies.listProfiles(),
               isCurrentOperation(token)
            {
                self.profiles = profiles
                await prunePaneWidths(for: profiles)
            }
            if notifyBeforeAfterSuccess {
                onCommittedProfileChange?(change)
            }
            await afterSuccess?(change)
            guard isCurrentOperation(token) else { return nil }
            if !notifyBeforeAfterSuccess {
                onCommittedProfileChange?(change)
            }
            return change
        } catch {
            guard isCurrentOperation(token) else { return nil }
            status = Self.message(for: error, fallback: failure)
            return nil
        }
    }

    private func apply(_ preferences: AvatarPreferences) {
        isEnabled = preferences.enabled
        selectedProfileID = preferences.selectedProfileID
        reduceMotion = preferences.reduceMotion
        onStateChange?()
    }

    private static func normalizedPaneWidths(
        _ values: [UUID: Double]
    ) -> [UUID: Double] {
        values.reduce(into: [:]) { result, entry in
            result[entry.key] = AvatarPaneWidth.normalized(entry.value)
        }
    }

    private func prunedPaneWidths(
        _ values: [UUID: Double],
        profiles: [AvatarProfileSummary]
    ) async -> [UUID: Double] {
        let normalized = Self.normalizedPaneWidths(values)
        let profileIDs = Set(profiles.map(\.id))
        let pruned = normalized.filter { profileIDs.contains($0.key) }
        guard pruned != values else { return pruned }
        try? await dependencies.replacePaneWidths(pruned)
        return pruned
    }

    private func prunePaneWidths(for profiles: [AvatarProfileSummary]) async {
        let profileIDs = Set(profiles.map(\.id))
        let pruned = paneWidths.filter { profileIDs.contains($0.key) }
        guard pruned != paneWidths else { return }
        guard (try? await dependencies.replacePaneWidths(pruned)) != nil else { return }
        paneWidths = pruned
    }

    private func reloadPreferencesAuthoritatively() async {
        do {
            apply(try await dependencies.loadPreferences())
        } catch {
            status = "Avatar preferences unavailable"
        }
    }

    private func reloadProfilesAuthoritatively() async {
        do {
            profiles = try await dependencies.listProfiles()
        } catch {
            status = Self.message(for: error, fallback: "Avatar profiles unavailable")
        }
    }

    private func beginOperation() -> UInt64? {
        guard !isResetting else { return nil }
        inFlightOperations += 1
        return operationGeneration
    }

    private func endOperation() {
        inFlightOperations -= 1
        guard inFlightOperations == 0 else { return }
        let waiters = resetWaiters
        resetWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForInFlightOperations() async {
        guard inFlightOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            resetWaiters.append(continuation)
        }
    }

    private func isCurrentOperation(_ token: UInt64) -> Bool {
        !isResetting && token == operationGeneration
    }

    private static func message(for error: Error, fallback: String) -> String {
        if let error = error as? AvatarProfileStoreError {
            return error.description
        }
        return fallback
    }
}

private enum AvatarPreferenceField: Hashable {
    case enabled
    case selectedProfile
    case reduceMotion
    case paneWidth(UUID)
}

private actor AvatarPreferenceWriteQueue {
    private var tail: Task<Void, Never>?

    func enqueue(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let predecessor = tail
        let current = Task<Void, Error> {
            _ = await predecessor?.value
            try await operation()
        }
        tail = Task<Void, Never> {
            _ = try? await current.value
        }
        try await current.value
    }
}
