public enum SQLiteError: Error, Equatable, Sendable {
    case openFailed
    case invalidHeader
    case newerSchema(found: Int, supported: Int)
    case integrityFailed
    case migrationFailed(version: Int)
    case constraintFailed
    case storageFull
    case writeFailed
}
