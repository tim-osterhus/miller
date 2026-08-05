import Foundation

final class TestDatabase: @unchecked Sendable {
    let directory: URL
    let path: String

    init(named name: String) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = repositoryRoot
            .appendingPathComponent(".artifacts/tests/MillerStorageTests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let safeName = name
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        directory = root.appendingPathComponent(
            "\(safeName)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        path = directory.appendingPathComponent("miller.sqlite3").path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func directoryPermissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
