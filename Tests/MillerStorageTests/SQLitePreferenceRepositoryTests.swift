import Foundation
@testable import MillerStorage
import Testing

@Suite
struct SQLitePreferenceRepositoryTests {
    private struct ExampleValue: Codable, Equatable, Sendable {
        let label: String
        let count: Int
    }

    @Test
    func defaultsUpdatesRoundTripsAndResetsTypedValues() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)
        #expect(try await repository.value(for: .voiceTranscriptSavingEnabled))
        #expect(try await repository.value(for: .selectedSettingsTab) == "general")
        #expect(try await repository.value(for: .wakeKeywordScore) == 5.0)
        #expect(try await repository.value(for: .wakeDetectionThreshold) == 0.05)

        try await repository.set(false, for: .voiceTranscriptSavingEnabled)
        #expect(!(try await repository.value(for: .voiceTranscriptSavingEnabled)))
        try await repository.delete(.voiceTranscriptSavingEnabled)
        #expect(try await repository.value(for: .voiceTranscriptSavingEnabled))

        let key = MillerPreferenceKey<ExampleValue>.testOnly(
            rawValue: "selected_settings_tab",
            defaultValue: ExampleValue(label: "default", count: 0)
        )
        let expected = ExampleValue(label: "tools", count: 3)
        try await repository.set(expected, for: key)
        #expect(try await repository.value(for: key) == expected)
        try await repository.reset()
        #expect(try await repository.value(for: key) == key.defaultValue)
    }

    @Test
    func remoteLiveBridgeIsDisabledByDefaultAndPersistsAsATypedPreference() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)

        #expect(try await repository.value(for: .remoteLiveEnabled) == false)
        try await repository.set(true, for: .remoteLiveEnabled)
        #expect(try await repository.value(for: .remoteLiveEnabled))
        try await repository.delete(.remoteLiveEnabled)
        #expect(try await repository.value(for: .remoteLiveEnabled) == false)
    }

    @Test
    func malformedAndOversizeValuesAreRefusedWithoutChangingExistingValue() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)
        try await repository.set("general", for: .selectedSettingsTab)
        await #expect(throws: PreferenceRepositoryError.valueTooLarge) {
            try await repository.set(
                String(repeating: "x", count: 65_537),
                for: .selectedSettingsTab
            )
        }
        #expect(try await repository.value(for: .selectedSettingsTab) == "general")

        let database = try SQLiteDatabase(path: fixture.path)
        try database.execute("PRAGMA ignore_check_constraints = ON")
        try database.execute(
            "UPDATE miller_preferences SET value_json = 'not-json' WHERE key = 'selected_settings_tab'"
        )
        await #expect(throws: PreferenceRepositoryError.malformedValue) {
            _ = try await repository.value(for: .selectedSettingsTab)
        }
    }

    @Test
    func injectedReadOnlyFailureLeavesPreferencesUnchanged() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)
        let readOnly = try SQLitePreferenceRepository(
            path: fixture.path,
            simulatedWriteFailure: .writeFailed
        )
        await #expect(throws: SQLiteError.writeFailed) {
            try await readOnly.set(false, for: .voiceTranscriptSavingEnabled)
        }
        #expect(try await repository.value(for: .voiceTranscriptSavingEnabled))
    }

    @Test
    func wakeTuningWritesBothExistingKeysAtomically() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)

        try await repository.setWakeTuning(
            keywordScore: 7.0,
            detectionThreshold: 0.08
        )

        #expect(try await repository.value(for: .wakeKeywordScore) == 7.0)
        #expect(try await repository.value(for: .wakeDetectionThreshold) == 0.08)

        let readOnly = try SQLitePreferenceRepository(
            path: fixture.path,
            simulatedWriteFailure: .writeFailed
        )
        await #expect(throws: SQLiteError.writeFailed) {
            try await readOnly.setWakeTuning(
                keywordScore: 9.0,
                detectionThreshold: 0.2
            )
        }
        #expect(try await repository.value(for: .wakeKeywordScore) == 7.0)
        #expect(try await repository.value(for: .wakeDetectionThreshold) == 0.08)
    }

    @Test
    func avatarPreferencesAreOffByDefaultPersistStrictlyAndResetByDeletion() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)

        let defaults = try await repository.avatarPreferences()
        #expect(defaults.enabled == false)
        #expect(defaults.selectedProfileID == nil)
        #expect(defaults.reduceMotion == false)
        #expect(defaults.mouthCuesEnabled)
        #expect(defaults.importQualityMode == "lightweight")

        let selected = UUID()
        try await repository.set(true, for: .avatarEnabled)
        try await repository.set(selected, for: .selectedAvatarProfileID)
        try await repository.set(true, for: .reduceAvatarMotion)
        try await repository.set(false, for: .avatarMouthCuesEnabled)
        try await repository.set("high_quality", for: .avatarImportQualityMode)
        #expect(try await repository.avatarPreferences() == .init(
            enabled: true,
            selectedProfileID: selected,
            reduceMotion: true,
            mouthCuesEnabled: false,
            importQualityMode: "high_quality"
        ))

        let database = try SQLiteDatabase(path: fixture.path)
        try database.execute("PRAGMA ignore_check_constraints = ON")
        try database.execute(
            "UPDATE miller_preferences SET value_json = 'not-json' WHERE key = 'avatar_enabled'"
        )
        let malformed = try await repository.avatarPreferences()
        #expect(malformed.enabled == false)
        #expect(malformed.selectedProfileID == selected)
        #expect(malformed.reduceMotion)

        try database.execute(
            "UPDATE miller_preferences SET value_json = 'not-json' WHERE key = 'avatar_selected_profile_id'"
        )
        let malformedSelection = try await repository.avatarPreferences()
        #expect(!malformedSelection.enabled)
        #expect(malformedSelection.selectedProfileID == nil)
        #expect(malformedSelection.reduceMotion)

        try database.execute(
            "UPDATE miller_preferences SET value_json = 'not-json' WHERE key = 'avatar_reduce_motion'"
        )
        let malformedMotion = try await repository.avatarPreferences()
        #expect(!malformedMotion.enabled)
        #expect(malformedMotion.selectedProfileID == nil)
        #expect(!malformedMotion.reduceMotion)
        #expect(!malformedMotion.mouthCuesEnabled)
        #expect(malformedMotion.importQualityMode == "high_quality")

        try database.execute(
            "UPDATE miller_preferences SET value_json = 'not-json' WHERE key = 'avatar_import_quality_mode'"
        )
        let malformedQuality = try await repository.avatarPreferences()
        #expect(malformedQuality.importQualityMode == "lightweight")

        try await repository.delete(.avatarEnabled)
        try await repository.delete(.selectedAvatarProfileID)
        try await repository.delete(.reduceAvatarMotion)
        try await repository.delete(.avatarMouthCuesEnabled)
        try await repository.delete(.avatarImportQualityMode)
        #expect(try await repository.avatarPreferences() == .init(
            enabled: false,
            selectedProfileID: nil,
            reduceMotion: false,
            mouthCuesEnabled: true,
            importQualityMode: "lightweight"
        ))

        try await repository.set(true, for: .avatarEnabled)
        try await repository.set(selected, for: .selectedAvatarProfileID)
        try await repository.set(true, for: .reduceAvatarMotion)
        try await repository.delete(.avatarEnabled)
        try await repository.delete(.selectedAvatarProfileID)
        try await repository.delete(.reduceAvatarMotion)
        try await repository.delete(.avatarMouthCuesEnabled)
        try await repository.delete(.avatarImportQualityMode)
        #expect(try await repository.avatarPreferences() == .init(
            enabled: false,
            selectedProfileID: nil,
            reduceMotion: false,
            mouthCuesEnabled: true,
            importQualityMode: "lightweight"
        ))
    }

    @Test
    func avatarPreferencesPropagateClosedDatabaseErrors() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)

        await repository.close()

        await #expect(throws: SQLiteError.writeFailed) {
            _ = try await repository.avatarPreferences()
        }
    }

    @Test
    func avatarPaneWidthsRoundTripByProfileAndResetWithAvatarPreferences() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)
        let first = UUID()
        let second = UUID()

        #expect(try await repository.avatarPaneWidths().isEmpty)
        try await repository.setAvatarPaneWidth(240, for: first)
        try await repository.setAvatarPaneWidth(320, for: second)
        #expect(try await repository.avatarPaneWidths() == [
            first: 240,
            second: 320,
        ])

        try await repository.delete(.avatarPaneWidths)
        #expect(try await repository.avatarPaneWidths().isEmpty)
    }

    @Test
    func malformedAvatarPaneWidthsFailClosedToEmpty() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLitePreferenceRepository(path: fixture.path)
        try await repository.setAvatarPaneWidth(240, for: UUID())
        let database = try SQLiteDatabase(path: fixture.path)
        try database.execute("PRAGMA ignore_check_constraints = ON")
        try database.execute(
            """
            UPDATE miller_preferences
            SET value_json = 'not-json'
            WHERE key = 'avatar_pane_widths'
            """
        )
        #expect(try await repository.avatarPaneWidths().isEmpty)
    }

    @Test
    func distinctAvatarPreferenceWritesSurviveConcurrentChanges() async throws {
        let fixture = try TestDatabase(named: #function)
        let first = try SQLitePreferenceRepository(path: fixture.path)
        let second = try SQLitePreferenceRepository(path: fixture.path)

        async let enabled: Void = first.set(true, for: .avatarEnabled)
        async let reduced: Void = second.set(true, for: .reduceAvatarMotion)
        _ = try await (enabled, reduced)

        #expect(try await first.value(for: .avatarEnabled))
        #expect(try await first.value(for: .reduceAvatarMotion))
    }
}
