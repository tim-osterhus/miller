import CryptoKit
import Foundation
import MillerCore

public enum PortableSkillImportError: Error, Equatable, Sendable {
    case sourceNotDirectory
    case unsafeSource
    case missingSkillFile
    case invalidUTF8
    case invalidFrontmatter
    case markdownTooLarge
    case skillLimitExceeded
}

public struct PortableSkillImporter: Sendable {
    public static let maximumMarkdownBytes = 64 * 1_024
    public static let maximumSkills = 128

    public init() {}

    public func importSkill(
        at directory: URL,
        pluginID: String? = nil,
        existingSkillCount: Int = 0
    ) throws -> PortableSkillSnapshot {
        guard existingSkillCount >= 0,
              existingSkillCount < Self.maximumSkills
        else { throw PortableSkillImportError.skillLimitExceeded }
        let root = directory.standardizedFileURL
        let values = try root.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true else {
            throw PortableSkillImportError.sourceNotDirectory
        }
        guard values.isSymbolicLink != true,
              !root.lastPathComponent.hasPrefix(".")
        else { throw PortableSkillImportError.unsafeSource }
        let file = root.appending(path: "SKILL.md")
        let fileValues = try file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard fileValues.isSymbolicLink != true else {
            throw PortableSkillImportError.unsafeSource
        }
        guard fileValues.isRegularFile == true else {
            throw PortableSkillImportError.missingSkillFile
        }
        guard (fileValues.fileSize ?? Self.maximumMarkdownBytes + 1)
                <= Self.maximumMarkdownBytes
        else { throw PortableSkillImportError.markdownTooLarge }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard data.count <= Self.maximumMarkdownBytes else {
            throw PortableSkillImportError.markdownTooLarge
        }
        guard let markdown = String(data: data, encoding: .utf8),
              Data(markdown.utf8) == data
        else { throw PortableSkillImportError.invalidUTF8 }
        let metadata = try Self.frontmatter(markdown)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PortableSkillSnapshot(
            id: "skill-\(hash)", pluginID: pluginID,
            name: metadata.name, description: metadata.description,
            markdown: markdown, sourceHash: hash
        )
    }

    private static func frontmatter(_ markdown: String) throws
        -> (name: String, description: String)
    {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---"), end > 1
        else { throw PortableSkillImportError.invalidFrontmatter }
        var values: [String: String] = [:]
        for line in lines[1..<end] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\""
                || value.first == "'" && value.last == "'")
            {
                value.removeFirst(); value.removeLast()
            }
            guard !values.keys.contains(key) else {
                throw PortableSkillImportError.invalidFrontmatter
            }
            values[key] = value
        }
        guard let name = values["name"], let description = values["description"],
              !name.isEmpty, !description.isEmpty,
              name.utf8.count <= 256, description.utf8.count <= 1_024,
              !name.contains("\0"), !description.contains("\0")
        else { throw PortableSkillImportError.invalidFrontmatter }
        return (name, description)
    }
}
