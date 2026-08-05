import Foundation
import MillerCore

public struct ResetRootResult: Equatable, Sendable {
    public let root: String
    public let succeeded: Bool

    public init(root: String, succeeded: Bool) {
        self.root = root
        self.succeeded = succeeded
    }
}

public struct ResetResult: Equatable, Sendable {
    public let roots: [ResetRootResult]

    public var failures: [ResetRootResult] {
        roots.filter { !$0.succeeded }
    }

    public init(roots: [ResetRootResult]) {
        self.roots = roots
    }
}

public actor ResetService {
    public typealias Action = @Sendable () async throws -> Void
    public typealias Removal = @Sendable (URL) async throws -> Void

    private let databaseURL: URL
    private let cacheURLs: [URL]
    private let credentialStore: any CredentialStore
    private let stopAndReapHelper: Action
    private let closeDatabase: Action
    private let reopenDatabase: Action
    private let resumeRuntime: Action
    private let removeItem: Removal

    public init(
        databaseURL: URL,
        cacheURLs: [URL],
        credentialStore: any CredentialStore,
        stopAndReapHelper: @escaping Action,
        closeDatabase: @escaping Action,
        reopenDatabase: @escaping Action,
        resumeRuntime: @escaping Action,
        removeItem: @escaping Removal = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) {
        self.databaseURL = databaseURL
        self.cacheURLs = cacheURLs
        self.credentialStore = credentialStore
        self.stopAndReapHelper = stopAndReapHelper
        self.closeDatabase = closeDatabase
        self.reopenDatabase = reopenDatabase
        self.resumeRuntime = resumeRuntime
        self.removeItem = removeItem
    }

    public func reset() async -> ResetResult {
        var results: [ResetRootResult] = []
        guard await run("helper", action: stopAndReapHelper, into: &results) else {
            return ResetResult(roots: results)
        }
        guard await run(
            "sqlite.close",
            action: closeDatabase,
            into: &results
        ) else {
            return ResetResult(roots: results)
        }

        let databaseRoots = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        for root in databaseRoots + cacheURLs {
            guard FileManager.default.fileExists(atPath: root.path) else {
                results.append(.init(root: root.path, succeeded: true))
                continue
            }
            do {
                try await removeItem(root)
                results.append(.init(root: root.path, succeeded: true))
            } catch {
                results.append(.init(
                    root: root.path,
                    succeeded: Self.fileAlreadyAbsent(error)
                ))
            }
        }

        do {
            for reference in try await credentialStore.allReferences() {
                let root = "keychain:\(reference.uuidString.lowercased())"
                do {
                    try await credentialStore.delete(for: reference)
                    results.append(.init(root: root, succeeded: true))
                } catch {
                    results.append(.init(
                        root: root,
                        succeeded: (error as? CredentialError) == .itemNotFound
                    ))
                }
            }
        } catch {
            results.append(.init(root: "keychain", succeeded: false))
        }
        guard await run(
            "sqlite.reopen",
            action: reopenDatabase,
            into: &results
        ) else { return ResetResult(roots: results) }
        _ = await run(
            "runtime.resume",
            action: resumeRuntime,
            into: &results
        )
        return ResetResult(roots: results)
    }

    private func run(
        _ root: String,
        action: Action,
        into results: inout [ResetRootResult]
    ) async -> Bool {
        do {
            try await action()
            results.append(.init(root: root, succeeded: true))
            return true
        } catch {
            results.append(.init(root: root, succeeded: false))
            return false
        }
    }

    private static func fileAlreadyAbsent(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .fileNoSuchFile
    }
}
