import CSQLite
import Darwin
import Foundation

enum SQLiteValue: Equatable, Sendable {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let path: String

    init(path: String) throws {
        self.path = path
        try reopen()
    }

    func reopen() throws {
        guard handle == nil else {
            return
        }
        try Self.prepareFilesystem(for: path)
        try Self.validateHeader(at: path)

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK,
              let opened
        else {
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw SQLiteError.openFailed
        }
        handle = opened

        do {
            try secureDatabaseFiles()
            guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
                throw SQLiteError.openFailed
            }
            try execute("PRAGMA foreign_keys = ON")

            let version = try scalarInt("PRAGMA user_version")
            guard version <= SQLiteMigrations.latestVersion else {
                throw SQLiteError.newerSchema(
                    found: version,
                    supported: SQLiteMigrations.latestVersion
                )
            }
            try qualifyIntegrity()
            try validateMigrationLedger(userVersion: version)
            try applyMigrations(after: version)

            _ = try scalarText("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try qualifyIntegrity()
            try secureDatabaseFiles()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else {
            return
        }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    func execute(
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw mappedError(result)
        }
    }

    func executeScript(_ sql: String) throws {
        guard let handle else {
            throw SQLiteError.writeFailed
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard result == SQLITE_OK else {
            throw mappedError(result)
        }
    }

    func query(
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [[SQLiteValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(readRow(from: statement))
            case SQLITE_DONE:
                return rows
            case let result:
                throw mappedError(result)
            }
        }
    }

    func scalarInt(
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> Int {
        let rows = try query(sql, bindings: bindings)
        guard case let .integer(value)? = rows.first?.first else {
            throw SQLiteError.writeFailed
        }
        return Int(value)
    }

    func scalarText(
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> String {
        let rows = try query(sql, bindings: bindings)
        guard case let .text(value)? = rows.first?.first else {
            throw SQLiteError.writeFailed
        }
        return value
    }

    func transaction<T>(
        mode: String = "IMMEDIATE",
        _ operation: () throws -> T
    ) throws -> T {
        try execute("BEGIN \(mode) TRANSACTION")
        do {
            let result = try operation()
            try execute("COMMIT")
            try secureDatabaseFiles()
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changes: Int {
        guard let handle else {
            return 0
        }
        return Int(sqlite3_changes(handle))
    }

    private func applyMigrations(after currentVersion: Int) throws {
        let pending = SQLiteMigrations.all.filter { $0.version > currentVersion }
        guard !pending.isEmpty else {
            return
        }

        try transaction(mode: "EXCLUSIVE") {
            for migration in pending {
                do {
                    try executeScript(migration.sql)
                    try execute(
                        "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                        bindings: [
                            .integer(Int64(migration.version)),
                            .text(Self.timestamp()),
                        ]
                    )
                    try execute("PRAGMA user_version = \(migration.version)")
                } catch {
                    throw SQLiteError.migrationFailed(version: migration.version)
                }
            }
        }
    }

    private func validateMigrationLedger(userVersion: Int) throws {
        guard userVersion > 0 else {
            return
        }
        do {
            let ledgerVersion = try scalarInt(
                "SELECT COALESCE(MAX(version), 0) FROM schema_migrations"
            )
            guard ledgerVersion == userVersion else {
                throw SQLiteError.integrityFailed
            }
        } catch let error as SQLiteError where error == .integrityFailed {
            throw error
        } catch {
            throw SQLiteError.integrityFailed
        }
    }

    private func qualifyIntegrity() throws {
        do {
            guard try scalarText("PRAGMA quick_check") == "ok" else {
                throw SQLiteError.integrityFailed
            }
        } catch let error as SQLiteError {
            switch error {
            case .storageFull:
                throw error
            default:
                throw SQLiteError.integrityFailed
            }
        } catch {
            throw SQLiteError.integrityFailed
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else {
            throw SQLiteError.writeFailed
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw mappedError(result)
        }
        return statement
    }

    private func bind(
        _ bindings: [SQLiteValue],
        to statement: OpaquePointer
    ) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case let .text(text):
                result = text.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, Self.transient)
                }
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        Self.transient
                    )
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw mappedError(result)
            }
        }
    }

    private func readRow(from statement: OpaquePointer) -> [SQLiteValue] {
        (0..<sqlite3_column_count(statement)).map { index in
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                .integer(sqlite3_column_int64(statement, index))
            case SQLITE_TEXT:
                sqlite3_column_text(statement, index).map {
                    .text(String(cString: $0))
                } ?? .null
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(statement, index) {
                    .blob(
                        Data(
                            bytes: bytes,
                            count: Int(sqlite3_column_bytes(statement, index))
                        )
                    )
                } else {
                    .blob(Data())
                }
            default:
                .null
            }
        }
    }

    private func mappedError(_ result: Int32) -> SQLiteError {
        let primary = result & 0xFF
        switch primary {
        case SQLITE_FULL:
            return .storageFull
        case SQLITE_CONSTRAINT:
            return .constraintFailed
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .integrityFailed
        case SQLITE_CANTOPEN:
            return .openFailed
        default:
            return .writeFailed
        }
    }

    private func secureDatabaseFiles() throws {
        for candidate in [path, path + "-wal", path + "-shm"] {
            guard FileManager.default.fileExists(atPath: candidate) else {
                continue
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: candidate
                )
            } catch {
                throw SQLiteError.writeFailed
            }
        }
    }

    private static func prepareFilesystem(for path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            let existed = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !existed || directory.lastPathComponent == "ai.millrace.miller" {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }
        } catch {
            throw SQLiteError.openFailed
        }
    }

    private static func validateHeader(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            return
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw SQLiteError.openFailed
        }
        defer { try? handle.close() }
        let header = try? handle.read(upToCount: 16)
        guard header == Data("SQLite format 3\u{0}".utf8) else {
            throw SQLiteError.invalidHeader
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}
