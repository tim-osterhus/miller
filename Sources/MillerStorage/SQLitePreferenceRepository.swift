import Foundation

public struct MillerPreferenceKey<Value: Codable & Sendable>: Sendable {
    public let rawValue: String
    public let defaultValue: Value

    private init(rawValue: String, defaultValue: Value) {
        self.rawValue = rawValue
        self.defaultValue = defaultValue
    }

    static func testOnly(
        rawValue: String,
        defaultValue: Value
    ) -> Self {
        Self(rawValue: rawValue, defaultValue: defaultValue)
    }
}

public extension MillerPreferenceKey where Value == Bool {
    static var voiceTranscriptSavingEnabled: Self {
        Self(
            rawValue: "voice_transcript_saving_enabled",
            defaultValue: true
        )
    }

    static var nextVoiceSessionSavingEnabled: Self {
        Self(
            rawValue: "next_voice_session_saving_enabled",
            defaultValue: true
        )
    }

    static var wakewordEnabled: Self {
        Self(rawValue: "wakeword_enabled", defaultValue: false)
    }

    static var menuBarEnabled: Self {
        Self(rawValue: "menu_bar_enabled", defaultValue: true)
    }

    static var launchAtLogin: Self {
        Self(rawValue: "launch_at_login", defaultValue: false)
    }
}

public extension MillerPreferenceKey where Value == String {
    static var wakePhrase: Self {
        Self(rawValue: "wake_phrase", defaultValue: "Hey Miller")
    }

    static var wakeMicrophoneID: Self {
        Self(rawValue: "wake_microphone_id", defaultValue: "")
    }

    static var selectedSettingsTab: Self {
        Self(rawValue: "selected_settings_tab", defaultValue: "general")
    }
}

public extension MillerPreferenceKey where Value == Double {
    static var wakeDetectionThreshold: Self {
        Self(rawValue: "wake_detection_threshold", defaultValue: 0.5)
    }

    static var wakeKeywordScore: Self {
        Self(rawValue: "wake_keyword_score", defaultValue: 0.0)
    }
}

public enum PreferenceRepositoryError: Error, Equatable, Sendable {
    case valueTooLarge
    case malformedValue
}

public actor SQLitePreferenceRepository {
    private static let maximumValueBytes = 64 * 1_024

    private let database: SQLiteDatabase
    private let simulatedWriteFailure: SQLiteError?

    public init(path: String = SQLiteConversationRepository.defaultPath) throws {
        database = try SQLiteDatabase(path: path)
        simulatedWriteFailure = nil
    }

    init(path: String, simulatedWriteFailure: SQLiteError) throws {
        database = try SQLiteDatabase(path: path)
        self.simulatedWriteFailure = simulatedWriteFailure
    }

    public func value<Value>(
        for key: MillerPreferenceKey<Value>
    ) throws -> Value where Value: Codable & Sendable {
        let rows = try database.query(
            "SELECT value_json FROM miller_preferences WHERE key = ?",
            bindings: [.text(key.rawValue)]
        )
        guard let value = rows.first?.first else {
            return key.defaultValue
        }
        guard case let .text(json) = value,
              let data = json.data(using: .utf8)
        else {
            throw PreferenceRepositoryError.malformedValue
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw PreferenceRepositoryError.malformedValue
        }
    }

    public func set<Value>(
        _ value: Value,
        for key: MillerPreferenceKey<Value>
    ) throws where Value: Codable & Sendable {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw PreferenceRepositoryError.malformedValue
        }
        guard data.count <= Self.maximumValueBytes,
              let json = String(data: data, encoding: .utf8)
        else {
            throw PreferenceRepositoryError.valueTooLarge
        }
        try preflightWrite()
        try database.transaction {
            try database.execute(
                """
                INSERT INTO miller_preferences(key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(key.rawValue),
                    .text(json),
                    .text(Self.timestamp()),
                ]
            )
        }
    }

    public func delete<Value>(
        _ key: MillerPreferenceKey<Value>
    ) throws where Value: Codable & Sendable {
        try preflightWrite()
        try database.transaction {
            try database.execute(
                "DELETE FROM miller_preferences WHERE key = ?",
                bindings: [.text(key.rawValue)]
            )
        }
    }

    public func reset() throws {
        try preflightWrite()
        try database.transaction {
            try database.execute("DELETE FROM miller_preferences")
        }
    }

    public func close() {
        database.close()
    }

    public func reopen() throws {
        try database.reopen()
    }

    private func preflightWrite() throws {
        if let simulatedWriteFailure {
            throw simulatedWriteFailure
        }
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
