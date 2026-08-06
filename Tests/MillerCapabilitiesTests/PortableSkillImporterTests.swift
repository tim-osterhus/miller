import Darwin
import Foundation
import MillerCore
import Testing
@testable import MillerCapabilities

@Suite(.serialized)
struct PortableSkillImporterTests {
    @Test
    func importsOneRegularUTF8SkillWithDeterministicIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = """
        ---
        name: Example Skill
        description: A bounded example.
        ---
        Follow these instructions.
        """
        try Data(markdown.utf8).write(to: root.appending(path: "SKILL.md"))

        let first = try PortableSkillImporter().importSkill(at: root)
        let second = try PortableSkillImporter().importSkill(at: root)

        #expect(first == second)
        #expect(first.name == "Example Skill")
        #expect(first.description == "A bounded example.")
        #expect(first.id == "skill-\(first.sourceHash)")
        #expect(first.sourceHash.count == 64)
        #expect(!first.enabled)
    }

    @Test
    func rejectsFilesMissingMetadataOversizeSymlinksAndGlobalOverflow() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "SKILL.md")

        try Data("plain text".utf8).write(to: file)
        #expect(throws: PortableSkillImportError.invalidFrontmatter) {
            _ = try PortableSkillImporter().importSkill(at: root)
        }

        try Data(("---\nname: N\ndescription: D\n---\n" + String(repeating: "x", count: 65_537)).utf8)
            .write(to: file)
        #expect(throws: PortableSkillImportError.markdownTooLarge) {
            _ = try PortableSkillImporter().importSkill(at: root)
        }

        try FileManager.default.removeItem(at: file)
        let outside = root.deletingLastPathComponent().appending(path: UUID().uuidString)
        try Data("---\nname: N\ndescription: D\n---\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(throws: PortableSkillImportError.unsafeSource) {
            _ = try PortableSkillImporter().importSkill(at: root)
        }

        #expect(throws: PortableSkillImportError.skillLimitExceeded) {
            _ = try PortableSkillImporter().importSkill(at: root, existingSkillCount: 128)
        }
    }

    @Test
    func rejectsNonDirectoriesHiddenSourcesAndNonUTF8Markdown() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinaryFile = root.appending(path: "ordinary")
        try Data("file".utf8).write(to: ordinaryFile)
        #expect(throws: PortableSkillImportError.sourceNotDirectory) {
            _ = try PortableSkillImporter().importSkill(at: ordinaryFile)
        }

        let hidden = root.appending(path: ".hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        try Data("---\nname: N\ndescription: D\n---\n".utf8)
            .write(to: hidden.appending(path: "SKILL.md"))
        #expect(throws: PortableSkillImportError.unsafeSource) {
            _ = try PortableSkillImporter().importSkill(at: hidden)
        }

        try Data([0xff, 0xfe]).write(to: root.appending(path: "SKILL.md"))
        #expect(throws: PortableSkillImportError.invalidUTF8) {
            _ = try PortableSkillImporter().importSkill(at: root)
        }
    }

    @Test
    func parsesBoundedYAMLStringsIncludingCRLFAndBlockScalars() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, String, String)] = [
            (
                "---\r\nname: \"Quoted: skill\"\r\ndescription: 'Owner''s helper'\r\n---\r\nBody\r\n",
                "Quoted: skill", "Owner's helper"
            ),
            (
                "---\nname: >\n  Multi\n  line\ndescription: |\n  First line\n  Second line\n---\nBody\n",
                "Multi line", "First line\nSecond line"
            ),
        ]
        for (markdown, name, description) in cases {
            try Data(markdown.utf8).write(to: root.appending(path: "SKILL.md"))
            let imported = try PortableSkillImporter().importSkill(at: root)
            #expect(imported.name == name)
            #expect(imported.description == description)
        }
    }

    @Test
    func rejectsNonStringEmptyMalformedAndDuplicateYAMLMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for markdown in [
            "---\nname: [not, a, string]\ndescription: valid\n---\n",
            "---\nname: \"\"\ndescription: valid\n---\n",
            "---\nname: \"unterminated\ndescription: valid\n---\n",
            "---\nname: one\nname: two\ndescription: valid\n---\n",
            "---\nname: valid\ndescription:\n---\n",
            "---\nname: true\ndescription: valid\n---\n",
            "---\nname: valid\ndescription: 42\n---\n",
            "---\nname: valid\ndescription: FALSE\n---\n",
        ] {
            try Data(markdown.utf8).write(to: root.appending(path: "SKILL.md"))
            #expect(throws: PortableSkillImportError.invalidFrontmatter) {
                _ = try PortableSkillImporter().importSkill(at: root)
            }
        }
    }

    @Test
    func projectorBoundsProviderSpecificAttachmentsAndUsesPrivateRoots() throws {
        let provider = UUID()
        let other = UUID()
        let skill = PortableSkillSnapshot(
            id: "skill-a", pluginID: nil, name: "A", description: "D",
            markdown: "---\nname: A\ndescription: D\n---\nDo A", sourceHash: String(repeating: "a", count: 64)
        )
        let projection = PortableSkillProjector().attachment(
            skills: [skill], enabledProviderIDs: ["skill-a": [provider]],
            providerProfileID: provider
        )
        #expect(projection.skills.map(\.id) == ["skill-a"])
        #expect(PortableSkillProjector().attachment(
            skills: [skill], enabledProviderIDs: ["skill-a": [provider]],
            providerProfileID: other
        ).skills.isEmpty)

        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try PortableSkillProjector().materialize(
            projection, under: parent, sessionID: UUID()
        )
        let materialized = root.appending(path: "skills/skill-a/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: materialized.path))
        #expect((try FileManager.default.attributesOfItem(atPath: materialized.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try PortableSkillProjector().removeMaterializedRoot(root, under: parent)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "miller-skill-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}
