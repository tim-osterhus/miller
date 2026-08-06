import Foundation
import MillerCore

public struct PortableSkillProjector: Sendable {
    public init() {}

    public func attachment(
        skills: [PortableSkillSnapshot],
        enabledProviderIDs: [String: Set<UUID>],
        providerProfileID: UUID
    ) -> PortableSkillAttachment {
        let eligible = skills.filter {
            enabledProviderIDs[$0.id, default: []].contains(providerProfileID)
        }.sorted { $0.id < $1.id }
        var admitted: [PortableSkillSnapshot] = []
        for skill in eligible {
            guard let value = try? PortableSkillAttachment(
                skills: admitted + [skill],
                omittedCount: eligible.count - admitted.count - 1
            ) else { break }
            admitted = value.skills
        }
        return try! PortableSkillAttachment(
            skills: admitted, omittedCount: eligible.count - admitted.count
        )
    }

    public func materialize(
        _ attachment: PortableSkillAttachment,
        under trustedParent: URL,
        sessionID: UUID
    ) throws -> URL {
        let parent = trustedParent.standardizedFileURL
        let root = parent.appending(path: "miller-skills-\(sessionID.uuidString.lowercased())")
        guard root.deletingLastPathComponent() == parent else {
            throw PortableSkillImportError.unsafeSource
        }
        try FileManager.default.createDirectory(
            at: root.appending(path: "skills"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            for skill in attachment.skills {
                guard Self.safeID(skill.id) else {
                    throw PortableSkillImportError.unsafeSource
                }
                let directory = root.appending(path: "skills/\(skill.id)")
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try Data(skill.markdown.utf8).write(
                    to: directory.appending(path: "SKILL.md"), options: [.atomic]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: directory.appending(path: "SKILL.md").path
                )
            }
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    public func removeMaterializedRoot(_ root: URL, under trustedParent: URL) throws {
        let parent = trustedParent.standardizedFileURL
        let candidate = root.standardizedFileURL
        guard candidate.deletingLastPathComponent() == parent,
              candidate.lastPathComponent.hasPrefix("miller-skills-")
        else { throw PortableSkillImportError.unsafeSource }
        let values = try candidate.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PortableSkillImportError.unsafeSource
        }
        try FileManager.default.removeItem(at: candidate)
    }

    public func removeStaleMaterializedRoots(under trustedParent: URL) throws {
        let parent = trustedParent.standardizedFileURL
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        let parentValues = try parent.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true
        else { throw PortableSkillImportError.unsafeSource }
        let children = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter { $0.lastPathComponent.hasPrefix("miller-skills-") }
        for child in children {
            try removeMaterializedRoot(child, under: parent)
        }
    }

    private static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 96 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || (48...57).contains($0.value)
                || $0 == "-" || $0 == "_")
        }
    }
}
