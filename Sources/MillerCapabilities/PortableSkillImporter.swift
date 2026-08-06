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
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---"), end > 1
        else { throw PortableSkillImportError.invalidFrontmatter }
        var values: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            guard !line.isEmpty, line.first?.isWhitespace != true,
                  let separator = line.firstIndex(of: ":")
            else { throw PortableSkillImportError.invalidFrontmatter }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !values.keys.contains(key) else {
                throw PortableSkillImportError.invalidFrontmatter
            }
            let value: String
            if raw == "|" || raw == ">" {
                var block: [String] = []
                index += 1
                while index < end, lines[index].first?.isWhitespace == true {
                    let blockLine = lines[index]
                    guard blockLine.hasPrefix("  ") else {
                        throw PortableSkillImportError.invalidFrontmatter
                    }
                    block.append(String(blockLine.dropFirst(2)))
                    index += 1
                }
                guard !block.isEmpty else {
                    throw PortableSkillImportError.invalidFrontmatter
                }
                value = raw == "|" ? block.joined(separator: "\n")
                    : foldBlock(block)
                index -= 1
            } else {
                value = try parseScalar(String(raw))
            }
            guard !value.isEmpty, !value.contains("\0") else {
                throw PortableSkillImportError.invalidFrontmatter
            }
            values[String(key)] = value
            index += 1
        }
        guard let name = values["name"], let description = values["description"],
              name.utf8.count <= 256, description.utf8.count <= 1_024,
              !name.contains("\n")
        else { throw PortableSkillImportError.invalidFrontmatter }
        return (name, description)
    }

    private static func parseScalar(_ raw: String) throws -> String {
        guard !raw.isEmpty else { throw PortableSkillImportError.invalidFrontmatter }
        if raw.first == "\"" {
            guard raw.last == "\"",
                  let data = "[\(raw)]".data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String],
                  decoded.count == 1
            else { throw PortableSkillImportError.invalidFrontmatter }
            return decoded[0]
        }
        if raw.first == "'" {
            guard raw.count >= 2, raw.last == "'" else {
                throw PortableSkillImportError.invalidFrontmatter
            }
            let inner = raw.dropFirst().dropLast()
            var result = "", cursor = inner.startIndex
            while cursor < inner.endIndex {
                if inner[cursor] == "'" {
                    let next = inner.index(after: cursor)
                    guard next < inner.endIndex, inner[next] == "'" else {
                        throw PortableSkillImportError.invalidFrontmatter
                    }
                    result.append("'")
                    cursor = inner.index(after: next)
                } else {
                    result.append(inner[cursor])
                    cursor = inner.index(after: cursor)
                }
            }
            return result
        }
        let primitive = raw.lowercased()
        guard raw.first != "[", raw.first != "{", raw.first != "&",
              raw.first != "*", raw.first != "!", raw.first != "|",
              raw.first != ">", raw.first != "%", raw.first != "@",
              raw.first != "`", !raw.hasPrefix("- "), !raw.hasPrefix("? "),
              !["true", "false", "null", "~", ".nan", ".inf", "+.inf", "-.inf"]
                .contains(primitive),
              Double(raw) == nil
        else { throw PortableSkillImportError.invalidFrontmatter }
        return raw
    }

    private static func foldBlock(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            if line.isEmpty {
                if !result.hasSuffix("\n") { result.append("\n") }
            } else {
                if !result.isEmpty, !result.hasSuffix("\n") { result.append(" ") }
                result.append(line)
            }
        }
        return result
    }
}
