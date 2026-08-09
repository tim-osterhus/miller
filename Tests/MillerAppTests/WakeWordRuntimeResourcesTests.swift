import Foundation
import MillerWake
import Testing
@testable import MillerApp

@Suite("Wakeword runtime resources")
struct WakeWordRuntimeResourcesTests {
    @Test
    func resolvesOnlyThePinnedRuntimeFilesAndPrivateKeywordPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wake-resources-(UUID().uuidString)")
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["encoder.onnx", "decoder.onnx", "joiner.onnx", "bpe.model", "tokens.txt"] {
            try Data("pinned".utf8).write(to: model.appendingPathComponent(name))
        }

        let paths = try WakeWordRuntimeResources.resolve(
            resourceRoot: root,
            applicationSupportDirectory: root.appendingPathComponent("support")
        )

        #expect(paths.encoder == model.appendingPathComponent("encoder.onnx"))
        #expect(paths.tokens == model.appendingPathComponent("tokens.txt"))
        #expect(paths.keywords.path.hasSuffix("support/wake-keywords.txt"))
    }
}
