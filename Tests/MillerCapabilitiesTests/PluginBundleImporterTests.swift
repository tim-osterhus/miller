import Foundation
import Testing
@testable import MillerCapabilities

@Suite(.serialized)
struct PluginBundleImporterTests {
    @Test
    func importsSupportedComponentsAsDisabledReviewableSnapshots() throws {
        let root = try pluginRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(["name": "example", "version": "1.0"], to: root.appending(path: ".codex-plugin/plugin.json"))
        let skill = root.appending(path: "skills/review")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: Review\ndescription: Reviews text.\n---\nReview.".utf8)
            .write(to: skill.appending(path: "SKILL.md"))
        try writeJSON(["mcpServers": ["notes": ["command": "bin/server", "args": ["--stdio"], "env": ["TOKEN": "${TOKEN}"]]]], to: root.appending(path: ".mcp.json"))
        try writeJSON(["apps": [["id": "gmail", "name": "Gmail"]]], to: root.appending(path: ".app.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "hooks"), withIntermediateDirectories: false)

        let imported = try PluginBundleImporter().importBundle(at: root)

        #expect(imported.plugin.id == "example")
        #expect(imported.skills.count == 1)
        #expect(imported.skills.allSatisfy { !$0.enabled })
        #expect(imported.mcpDrafts.count == 1)
        #expect(imported.mcpDrafts[0].enabled == false)
        #expect(imported.mcpDrafts[0].relativeExecutablePath == "bin/server")
        #expect(imported.mcpDrafts[0].unresolvedSecrets == ["TOKEN"])
        #expect(imported.apps[0].availabilityLabel == "Codex only")
        #expect(imported.ignoredComponents.contains("hooks"))
    }

    @Test
    func atomicallyRejectsDuplicatesEscapesSymlinksAndLimits() throws {
        let root = try pluginRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(["name": "example"], to: root.appending(path: ".codex-plugin/plugin.json"))
        try writeJSON(["mcpServers": [
            "one": ["command": "../escape"],
            "ONE": ["command": "bin/other"],
        ]], to: root.appending(path: ".mcp.json"))
        #expect(throws: PluginBundleImportError.invalidBundle) {
            _ = try PluginBundleImporter().importBundle(at: root)
        }

        try writeJSON(["mcpServers": ["one": ["command": "bin/server"]]], to: root.appending(path: ".mcp.json"))
        let outside = root.deletingLastPathComponent().appending(path: UUID().uuidString)
        try Data("binary".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "payload"), withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(throws: PluginBundleImportError.unsafeSource) {
            _ = try PluginBundleImporter().importBundle(at: root)
        }
    }

    @Test
    func rejectsComponentAndInspectedByteLimitsWithoutCopyingExecutables() throws {
        let root = try pluginRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(["name": "bounded"], to: root.appending(path: ".codex-plugin/plugin.json"))
        let definitions = Dictionary(uniqueKeysWithValues: (0...16).map {
            ("server-\($0)", ["command": "bin/server-\($0)"])
        })
        try writeJSON(["mcpServers": definitions], to: root.appending(path: ".mcp.json"))
        #expect(throws: PluginBundleImportError.componentLimitExceeded) {
            _ = try PluginBundleImporter().importBundle(at: root)
        }

        try FileManager.default.removeItem(at: root.appending(path: ".mcp.json"))
        for index in 0...16 {
            let skill = root.appending(path: "skills/skill-\(index)")
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: Skill \(index)\ndescription: Bounded\n---\nUse it.".utf8)
                .write(to: skill.appending(path: "SKILL.md"))
        }
        #expect(throws: PluginBundleImportError.componentLimitExceeded) {
            _ = try PluginBundleImporter().importBundle(at: root)
        }
        try FileManager.default.removeItem(at: root.appending(path: "skills"))
        try Data(repeating: 0x41, count: PluginBundleImporter.maximumInspectedBytes + 1)
            .write(to: root.appending(path: "opaque.bin"))
        #expect(throws: PluginBundleImportError.bundleTooLarge) {
            _ = try PluginBundleImporter().importBundle(at: root)
        }
    }
}

private func pluginRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "miller-plugin-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appending(path: ".codex-plugin"), withIntermediateDirectories: true)
    return root
}

private func writeJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
}
