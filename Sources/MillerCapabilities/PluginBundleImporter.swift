import CryptoKit
import Foundation
import MillerCore

public enum PluginBundleImportError: Error, Equatable, Sendable {
    case sourceNotDirectory
    case unsafeSource
    case missingManifest
    case invalidBundle
    case componentLimitExceeded
    case bundleTooLarge
}

public struct PluginPackageSnapshot: Equatable, Sendable {
    public let id: String
    public let version: String?
    public let sourceHash: String
    public let enabled: Bool
}

public struct PluginMCPDraft: Equatable, Sendable {
    public let id: String
    public let command: String?
    public let arguments: [String]
    public let endpoint: String?
    public let relativeExecutablePath: String?
    public let unresolvedSecrets: [String]
    public let enabled: Bool
}

public struct PluginAppMetadata: Equatable, Sendable {
    public let id: String
    public let name: String
    public let availabilityLabel = "Codex only"
}

public struct PluginBundleSnapshot: Equatable, Sendable {
    public let plugin: PluginPackageSnapshot
    public let skills: [PortableSkillSnapshot]
    public let mcpDrafts: [PluginMCPDraft]
    public let apps: [PluginAppMetadata]
    public let ignoredComponents: [String]
}

public struct PluginBundleImporter: Sendable {
    public static let maximumSkills = 16
    public static let maximumMCPServers = 16
    public static let maximumInspectedBytes = 4 * 1_024 * 1_024
    public static let maximumIgnoredComponents = 256
    public static let maximumIgnoredLabelBytes = 4 * 1_024

    public init() {}

    public static func projectedServerID(
        pluginID: String,
        componentID: String
    ) -> String {
        let identity = "\(pluginID):\(componentID)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let stem = "plugin-\(pluginID)-\(componentID)"
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
        return "\(String(stem.prefix(79)))-\(digest)"
    }

    public func importBundle(at directory: URL) throws -> PluginBundleSnapshot {
        let root = directory.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true else {
            throw PluginBundleImportError.sourceNotDirectory
        }
        guard rootValues.isSymbolicLink != true else {
            throw PluginBundleImportError.unsafeSource
        }
        let inspected = try inspectTree(root)
        guard inspected.bytes <= Self.maximumInspectedBytes else {
            throw PluginBundleImportError.bundleTooLarge
        }

        let manifestURL = root.appending(path: ".codex-plugin/plugin.json")
        guard inspected.files.contains(manifestURL.standardizedFileURL.path) else {
            throw PluginBundleImportError.missingManifest
        }
        let manifest = try object(at: manifestURL)
        guard let rawID = (manifest["id"] ?? manifest["name"]) as? String,
              let id = safeIdentifier(rawID)
        else { throw PluginBundleImportError.invalidBundle }
        let version = manifest["version"] as? String
        if let version, version.utf8.count > 128 {
            throw PluginBundleImportError.invalidBundle
        }

        let skillRoot = root.appending(path: "skills")
        var skills: [PortableSkillSnapshot] = []
        if inspected.directories.contains(skillRoot.standardizedFileURL.path) {
            let entries = try FileManager.default.contentsOfDirectory(
                at: skillRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            let children = try entries.filter { entry in
                let values = try entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard values.isSymbolicLink != true else {
                    throw PluginBundleImportError.unsafeSource
                }
                if values.isDirectory == true { return true }
                guard values.isRegularFile == true else {
                    throw PluginBundleImportError.unsafeSource
                }
                return false
            }
            guard children.count <= Self.maximumSkills else {
                throw PluginBundleImportError.componentLimitExceeded
            }
            for child in children {
                guard !child.lastPathComponent.hasPrefix("."),
                      child.deletingLastPathComponent().standardizedFileURL == skillRoot.standardizedFileURL
                else { throw PluginBundleImportError.unsafeSource }
                skills.append(try PortableSkillImporter().importSkill(
                    at: child, pluginID: id, existingSkillCount: skills.count
                ))
            }
            guard Set(skills.map(\.id)).count == skills.count else {
                throw PluginBundleImportError.invalidBundle
            }
        }

        let mcpURL = root.appending(path: ".mcp.json")
        let mcpDrafts = inspected.files.contains(mcpURL.standardizedFileURL.path)
            ? try parseMCP(try object(at: mcpURL), root: root) : []
        guard mcpDrafts.count <= Self.maximumMCPServers else {
            throw PluginBundleImportError.componentLimitExceeded
        }
        let appURL = root.appending(path: ".app.json")
        let apps = inspected.files.contains(appURL.standardizedFileURL.path)
            ? try parseApps(try object(at: appURL)) : []

        var consumed = Set([
            manifestURL.standardizedFileURL.path,
            mcpURL.standardizedFileURL.path,
            appURL.standardizedFileURL.path,
        ])
        if inspected.directories.contains(skillRoot.standardizedFileURL.path) {
            for child in try FileManager.default.contentsOfDirectory(
                at: skillRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                consumed.insert(child.appending(path: "SKILL.md").standardizedFileURL.path)
            }
        }
        var ignored = Set(inspected.files.subtracting(consumed).map { path in
            String(path.dropFirst(root.path.count + 1))
        })
        if manifest["hooks"] != nil { ignored.insert("hooks") }
        if manifest["assets"] != nil { ignored.insert("assets") }
        if inspected.directories.contains(root.appending(path: "hooks").standardizedFileURL.path) {
            ignored.insert("hooks")
        }
        guard ignored.count <= Self.maximumIgnoredComponents,
              ignored.sorted().joined(separator: "\n").utf8.count
                <= Self.maximumIgnoredLabelBytes
        else { throw PluginBundleImportError.componentLimitExceeded }

        let digestSource = try inspected.files.sorted().reduce(into: Data()) { result, path in
            result.append(Data(path.replacingOccurrences(of: root.path, with: "").utf8))
            result.append(try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let hash = SHA256.hash(data: digestSource).map { String(format: "%02x", $0) }.joined()
        return PluginBundleSnapshot(
            plugin: .init(id: id, version: version, sourceHash: hash, enabled: false),
            skills: skills, mcpDrafts: mcpDrafts, apps: apps,
            ignoredComponents: ignored.sorted()
        )
    }

    private func inspectTree(_ root: URL) throws -> (files: Set<String>, directories: Set<String>, bytes: Int) {
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { throw PluginBundleImportError.invalidBundle }
        var files = Set<String>(), directories = Set<String>(), bytes = 0
        while let url = enumerator.nextObject() as? URL {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard !relative.split(separator: "/").contains("..") else {
                throw PluginBundleImportError.unsafeSource
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw PluginBundleImportError.unsafeSource
            }
            if values.isRegularFile == true {
                files.insert(url.standardizedFileURL.path)
                bytes += values.fileSize ?? 0
                guard bytes <= Self.maximumInspectedBytes else {
                    throw PluginBundleImportError.bundleTooLarge
                }
            } else if values.isDirectory == true {
                directories.insert(url.standardizedFileURL.path)
            } else {
                throw PluginBundleImportError.unsafeSource
            }
        }
        guard !enumerationFailed else {
            throw PluginBundleImportError.invalidBundle
        }
        return (files, directories, bytes)
    }

    private func object(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PluginBundleImportError.invalidBundle }
        return result
    }

    private func parseMCP(_ object: [String: Any], root: URL) throws -> [PluginMCPDraft] {
        guard let definitions = object["mcpServers"] as? [String: Any] else {
            throw PluginBundleImportError.invalidBundle
        }
        var seen = Set<String>(), drafts: [PluginMCPDraft] = []
        for rawID in definitions.keys.sorted() {
            guard let id = safeIdentifier(rawID), seen.insert(id).inserted,
                  let value = definitions[rawID] as? [String: Any]
            else { throw PluginBundleImportError.invalidBundle }
            let rawCommand = value["command"] as? String
            let endpoint = value["url"] as? String ?? value["endpoint"] as? String
            guard (rawCommand == nil) != (endpoint == nil) else {
                throw PluginBundleImportError.invalidBundle
            }
            var relative: String?
            var command = rawCommand
            if let rawCommand, !rawCommand.hasPrefix("/") {
                guard safeRelativePath(rawCommand) else {
                    throw PluginBundleImportError.invalidBundle
                }
                relative = rawCommand
                command = nil
            }
            if let endpoint {
                guard let url = URL(string: endpoint), url.scheme == "https",
                      url.host != nil else { throw PluginBundleImportError.invalidBundle }
            }
            let arguments = value["args"] as? [String] ?? []
            guard arguments.count <= 256,
                  arguments.allSatisfy({ $0.utf8.count <= 16 * 1_024 && !$0.contains("\0") })
            else { throw PluginBundleImportError.invalidBundle }
            let env = value["env"] as? [String: Any] ?? [:]
            guard env.count <= 128 else { throw PluginBundleImportError.invalidBundle }
            let unresolved = env.keys.sorted()
            _ = root
            drafts.append(.init(
                id: id, command: command, arguments: arguments,
                endpoint: endpoint, relativeExecutablePath: relative,
                unresolvedSecrets: unresolved, enabled: false
            ))
        }
        return drafts
    }

    private func parseApps(_ object: [String: Any]) throws -> [PluginAppMetadata] {
        guard let values = object["apps"] as? [[String: Any]], values.count <= 128
        else { throw PluginBundleImportError.invalidBundle }
        var seen = Set<String>()
        return try values.map { value in
            guard let rawID = value["id"] as? String,
                  let id = safeIdentifier(rawID), seen.insert(id).inserted,
                  let name = value["name"] as? String, !name.isEmpty,
                  name.utf8.count <= 256
            else { throw PluginBundleImportError.invalidBundle }
            return PluginAppMetadata(id: id, name: name)
        }
    }

    private func safeIdentifier(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 96,
              value.unicodeScalars.allSatisfy({
                  $0.isASCII && ($0.properties.isAlphabetic || (48...57).contains($0.value)
                      || $0 == "-" || $0 == "_" || $0 == ".")
              }) else { return nil }
        return value
    }

    private func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}
