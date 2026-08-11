import Foundation
import Testing
@testable import MillerWake

@Suite("Wakeword keyword materialization", .serialized)
struct WakeWordKeywordMaterializerTests {
    @Test
    func productionSentencePieceModelEncodesTheDefaultPhrase() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = root.appendingPathComponent("production-tokens.txt")
        try [
            "<blk> 0", "<sos/eos> 1", "<unk> 2", "Y 3", "ER 4",
            "LL 5", "▁HE 6", "▁MI 7",
        ].joined(separator: "\n").appending("\n").write(
            to: tokens,
            atomically: true,
            encoding: .utf8
        )
        let model = root.appendingPathComponent("bpe.model")
        try sentencePieceModel([
            ("<blk>", 0, 4), ("<sos/eos>", 0, 4), ("<unk>", 0, 2),
            ("Y", -4, 1), ("ER", -5, 1), ("LL", -5, 1),
            ("▁HE", -3, 1), ("▁MI", -3, 1),
        ]).write(to: model)
        let materializer = try WakeWordKeywordMaterializer(
            tokensFile: tokens,
            bpeModel: model,
            applicationSupportDirectory: root.appendingPathComponent(
                "ProductionSupport", isDirectory: true
            )
        )

        let materialized = try materializer.materialize("Hey Miller")

        #expect(materialized.normalizedPhrase == "hey miller")
        #expect(
            try String(contentsOf: materialized.url, encoding: .utf8)
                == "▁HE Y ▁MI LL ER\n"
        )
    }

    @Test
    func productionUnigramModelUsesScoresInsteadOfGreedyLongestMatch() throws {
        let compiler = WakeWordPhraseCompiler(
            tokens: ["<blk>", "<sos/eos>", "<unk>", "▁S", "I", "RI", "IR"],
            tokenScores: ["▁S": -1, "I": -1, "RI": -1, "IR": -5]
        )

        #expect(try compiler.tokenize("Siri") == ["▁S", "I", "RI"])
    }

    @Test
    func rejectsAMergeBasedModelInsteadOfApplyingUnigramScoring() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("bpe.model")
        try sentencePieceModel([("a", -1, 1)], modelType: 2).write(to: model)

        #expect(throws: WakeWordKeywordMaterializerError.malformedBPEModel) {
            try WakeWordKeywordMaterializer(
                tokensFile: root.appendingPathComponent("tokens.txt"),
                bpeModel: model,
                applicationSupportDirectory: root.appendingPathComponent("Support")
            )
        }
    }

    @Test
    func rejectsAnOversizedModelBeforeParsing() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("bpe.model")
        try Data(
            repeating: 0,
            count: WakeWordKeywordMaterializer.maximumBPEModelBytes + 1
        ).write(to: model)

        #expect(throws: WakeWordKeywordMaterializerError.bpeModelTooLarge) {
            try WakeWordKeywordMaterializer(
                tokensFile: root.appendingPathComponent("tokens.txt"),
                bpeModel: model,
                applicationSupportDirectory: root.appendingPathComponent("Support")
            )
        }
    }

    @Test
    func rejectsAnOverflowingProtobufVarintBeforeValidContent() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("bpe.model")
        var malformed = Data([0x22])
        malformed.append(contentsOf: Array(repeating: 0x80, count: 9))
        malformed.append(0x02)
        malformed.append(sentencePieceModel([("a", -1, 1)]))
        try malformed.write(to: model)

        #expect(throws: WakeWordKeywordMaterializerError.malformedBPEModel) {
            try WakeWordKeywordMaterializer(
                tokensFile: root.appendingPathComponent("tokens.txt"),
                bpeModel: model,
                applicationSupportDirectory: root.appendingPathComponent("Support")
            )
        }
    }

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

    private func sentencePieceModel(
        _ pieces: [(String, Float, UInt64)],
        modelType: UInt64 = 1
    ) -> Data {
        var model = Data()
        for (piece, score, type) in pieces {
            var message = Data()
            appendLengthDelimited(field: 1, Data(piece.utf8), to: &message)
            message.append(UInt8((2 << 3) | 5))
            var bits = score.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { message.append(contentsOf: $0) }
            appendVarint(field: 3, value: type, to: &message)
            appendLengthDelimited(field: 1, message, to: &model)
        }
        var trainer = Data()
        appendVarint(field: 3, value: modelType, to: &trainer)
        appendLengthDelimited(field: 2, trainer, to: &model)
        return model
    }

    private func appendLengthDelimited(
        field: UInt64,
        _ value: Data,
        to data: inout Data
    ) {
        appendRawVarint((field << 3) | 2, to: &data)
        appendRawVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private func appendVarint(
        field: UInt64,
        value: UInt64,
        to data: inout Data
    ) {
        appendRawVarint(field << 3, to: &data)
        appendRawVarint(value, to: &data)
    }

    private func appendRawVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}
