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
}
