import Foundation
import Testing
@testable import MillerWake

@Suite("Wakeword keyword materialization", .serialized)
struct WakeWordKeywordMaterializerTests {
    @Test
    func normalizesPhraseSerializesTokensAndUsesOwnerOnlyFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-wake-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tokens = root.appendingPathComponent("tokens.txt")
        try "<blk> 0\n▁hey 1\n▁miller 2\n".write(
            to: tokens,
            atomically: true,
            encoding: .utf8
        )

        let materializer = try WakeWordKeywordMaterializer(
            tokensFile: tokens,
            applicationSupportDirectory: root.appendingPathComponent("Support", isDirectory: true)
        )
        let materialized = try materializer.materialize("  Hey   Miller ")

        #expect(materialized.normalizedPhrase == "hey miller")
        #expect(
            try String(contentsOf: materialized.url, encoding: .utf8)
                == "▁hey ▁miller\n"
        )
        #expect(
            try FileManager.default.attributesOfItem(atPath: materialized.url.path)[.posixPermissions]
                as? NSNumber == NSNumber(value: 0o600)
        )
        #expect(
            try FileManager.default.attributesOfItem(atPath: materialized.url.deletingLastPathComponent().path)[.posixPermissions]
                as? NSNumber == NSNumber(value: 0o700)
        )
    }

    @Test
    func invalidPhraseLeavesTheLastWorkingKeywordFileUntouched() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = try makeMaterializer(root: root)
        _ = try materializer.materialize("Hey Miller")

        #expect(throws: WakeWordPhraseError.unsupportedToken("!")) {
            try materializer.materialize("Hey!")
        }
        #expect(
            try String(contentsOf: materializer.url, encoding: .utf8)
                == "▁hey ▁miller\n"
        )
    }

    @Test
    func previousKeywordCanBeRestoredAtomically() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = try makeMaterializer(root: root)
        _ = try materializer.materialize("Hey Miller")
        let second = try materializer.materialize("Hey")
        try materializer.restore(second)

        #expect(
            try String(contentsOf: materializer.url, encoding: .utf8)
                == "▁hey ▁miller\n"
        )
    }

    @Test
    func symlinkReplacementIsRejectedWithoutTouchingTheOutsideFile() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = try makeMaterializer(root: root)
        _ = try materializer.materialize("Hey Miller")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: materializer.url)
        try FileManager.default.createSymbolicLink(
            at: materializer.url,
            withDestinationURL: outside
        )

        #expect(throws: WakeWordKeywordMaterializerError.unsafePath) {
            try materializer.materialize("Hey")
        }
        #expect(String(data: try Data(contentsOf: outside), encoding: .utf8) == "outside")
    }

    @Test
    func directorySymlinkCreatedAfterInitializationIsRejected() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let materializer = try makeMaterializer(root: root)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: support,
            withDestinationURL: outside
        )

        #expect(throws: WakeWordKeywordMaterializerError.unsafePath) {
            try materializer.materialize("Hey Miller")
        }
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("wake-keywords.txt").path
        ))
    }

    @Test
    func injectedInstallFailureRollsBackAndPreservesLastWorkingPhrase() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = try makeMaterializer(root: root)
        _ = try materializer.materialize("Hey Miller")
        let failing = try WakeWordKeywordMaterializer(
            tokensFile: root.appendingPathComponent("tokens.txt"),
            applicationSupportDirectory: root.appendingPathComponent(
                "Support", isDirectory: true
            ),
            faultInjection: .failAfterInstall
        )

        #expect(throws: WakeWordKeywordMaterializerError.writeFailed) {
            try failing.materialize("Hey")
        }
        #expect(
            try String(contentsOf: materializer.url, encoding: .utf8)
                == "▁hey ▁miller\n"
        )
    }

    @Test
    func injectedRollbackFailureIsReportedInsteadOfSuppressed() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = try makeMaterializer(root: root)
        _ = try materializer.materialize("Hey Miller")
        let failing = try WakeWordKeywordMaterializer(
            tokensFile: root.appendingPathComponent("tokens.txt"),
            applicationSupportDirectory: root.appendingPathComponent(
                "Support", isDirectory: true
            ),
            faultInjection: .failAfterInstallAndRollback
        )

        #expect(throws: WakeWordKeywordMaterializerError.rollbackFailed) {
            try failing.materialize("Hey")
        }
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miller-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try "<blk> 0\n▁hey 1\n▁miller 2\n".write(
            to: root.appendingPathComponent("tokens.txt"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func makeMaterializer(root: URL) throws -> WakeWordKeywordMaterializer {
        try WakeWordKeywordMaterializer(
            tokensFile: root.appendingPathComponent("tokens.txt"),
            applicationSupportDirectory: root.appendingPathComponent(
                "Support", isDirectory: true
            )
        )
    }
}
