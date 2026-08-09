import Darwin
import Foundation

public enum WakeWordKeywordMaterializerError: Error, Equatable, Sendable {
    case tokensFileMissing
    case malformedTokensFile
    case tokensFileTooLarge
    case unsafePath
    case writeFailed
}

public struct WakeWordMaterializedPhrase: Equatable, Sendable {
    public let normalizedPhrase: String
    public let url: URL
    let previousContents: Data?

    init(normalizedPhrase: String, url: URL, previousContents: Data?) {
        self.normalizedPhrase = normalizedPhrase
        self.url = url
        self.previousContents = previousContents
    }
}

/// Parses the pinned Sherpa vocabulary and atomically materializes one private
/// keyword definition. Audio and phrase text never leave the caller's process.
public struct WakeWordKeywordMaterializer: Sendable {
    public static let maximumTokensFileBytes = 2 * 1024 * 1024
    public static let maximumVocabularyEntries = 100_000
    public static let keywordFileName = "wake-keywords.txt"

    private let tokensFile: URL
    private let applicationSupportDirectory: URL
    private let keywordFileName: String
    private let vocabulary: [String]

    public init(
        tokensFile: URL,
        applicationSupportDirectory: URL,
        keywordFileName: String = Self.keywordFileName
    ) throws {
        guard tokensFile.isFileURL,
              applicationSupportDirectory.isFileURL,
              !keywordFileName.isEmpty,
              !keywordFileName.contains("/")
        else { throw WakeWordKeywordMaterializerError.unsafePath }
        self.tokensFile = tokensFile
        self.applicationSupportDirectory = applicationSupportDirectory
        self.keywordFileName = keywordFileName
        let data: Data
        do {
            data = try Data(contentsOf: tokensFile)
        } catch {
            throw WakeWordKeywordMaterializerError.tokensFileMissing
        }
        guard data.count <= Self.maximumTokensFileBytes,
              let text = String(data: data, encoding: .utf8),
              !text.utf8.contains(0)
        else { throw WakeWordKeywordMaterializerError.tokensFileTooLarge }
        let parsed = try Self.parseVocabulary(text)
        guard !parsed.isEmpty else {
            throw WakeWordKeywordMaterializerError.malformedTokensFile
        }
        let maximumID = parsed.values.max() ?? -1
        var ordered = Array(repeating: "", count: maximumID + 1)
        for (token, id) in parsed { ordered[id] = token }
        vocabulary = ordered
    }

    public var url: URL {
        applicationSupportDirectory.appendingPathComponent(
            keywordFileName,
            isDirectory: false
        )
    }

    public func materialize(_ phrase: String) throws -> WakeWordMaterializedPhrase {
        let compiler = WakeWordPhraseCompiler(tokens: vocabulary)
        let normalized = try compiler.normalize(phrase)
        let tokens = try compiler.tokenize(normalized)
        let contents = Data((tokens.joined(separator: " ") + "\n").utf8)
        try ensurePrivateDirectory()
        let previousContents = try readExistingFile()
        try atomicReplace(contents)
        return WakeWordMaterializedPhrase(
            normalizedPhrase: normalized,
            url: url,
            previousContents: previousContents
        )
    }

    public func restore(_ materialized: WakeWordMaterializedPhrase) throws {
        guard materialized.url == url else {
            throw WakeWordKeywordMaterializerError.unsafePath
        }
        if let previousContents = materialized.previousContents {
            try atomicReplace(previousContents)
        } else {
            try remove()
        }
    }

    public func remove() throws {
        guard !isSymbolicLink(url) else {
            throw WakeWordKeywordMaterializerError.unsafePath
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
    }

    private static func parseVocabulary(_ text: String) throws -> [String: Int] {
        var result = [String: Int]()
        var usedIDs = Set<Int>()
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2,
                  let id = Int(fields[1]),
                  id >= 0,
                  id < maximumVocabularyEntries,
                  !fields[0].isEmpty,
                  result[String(fields[0])] == nil,
                  usedIDs.insert(id).inserted,
                  result.count < maximumVocabularyEntries
            else { throw WakeWordKeywordMaterializerError.malformedTokensFile }
            result[String(fields[0])] = id
        }
        return result
    }

    private func ensurePrivateDirectory() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: applicationSupportDirectory.path) {
            guard !isSymbolicLink(applicationSupportDirectory),
                  (try? fileManager.attributesOfItem(atPath: applicationSupportDirectory.path)[.type] as? FileAttributeType) == .typeDirectory
            else { throw WakeWordKeywordMaterializerError.unsafePath }
        } else {
            do {
                try fileManager.createDirectory(
                    at: applicationSupportDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: applicationSupportDirectory.path
        )
    }

    private func readExistingFile() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard !isSymbolicLink(url) else {
            throw WakeWordKeywordMaterializerError.unsafePath
        }
        do { return try Data(contentsOf: url) }
        catch { throw WakeWordKeywordMaterializerError.writeFailed }
    }

    private func atomicReplace(_ data: Data) throws {
        let fileManager = FileManager.default
        guard !isSymbolicLink(applicationSupportDirectory), !isSymbolicLink(url) else {
            throw WakeWordKeywordMaterializerError.unsafePath
        }
        let temporaryURL = applicationSupportDirectory.appendingPathComponent(
            ".\(keywordFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let backupURL = applicationSupportDirectory.appendingPathComponent(
            ".\(keywordFileName).\(UUID().uuidString).bak",
            isDirectory: false
        )
        var replacementComplete = false
        var oldFileMovedToBackup = false
        var newFileInstalled = false
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            if replacementComplete {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
            } else if oldFileMovedToBackup {
                if newFileInstalled,
                   fileManager.fileExists(atPath: url.path),
                   !isSymbolicLink(url)
                {
                    try? fileManager.removeItem(at: url)
                }
                _ = rename(backupURL.path, url.path)
            } else if newFileInstalled,
                      fileManager.fileExists(atPath: url.path),
                      !isSymbolicLink(url)
            {
                try? fileManager.removeItem(at: url)
            }
        }

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), !isSymbolicLink(temporaryURL) else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        var writeSucceeded = true
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    writeSucceeded = false
                    return
                }
                offset += written
            }
        }
        if Darwin.fsync(descriptor) != 0 { writeSucceeded = false }
        Darwin.close(descriptor)
        guard writeSucceeded else { throw WakeWordKeywordMaterializerError.writeFailed }

        if fileManager.fileExists(atPath: url.path) {
            guard !isSymbolicLink(url), rename(url.path, backupURL.path) == 0 else {
                throw WakeWordKeywordMaterializerError.unsafePath
            }
            oldFileMovedToBackup = true
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        newFileInstalled = true
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let directoryDescriptor = applicationSupportDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY)
        }
        guard directoryDescriptor >= 0 else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        let directorySyncSucceeded = Darwin.fsync(directoryDescriptor) == 0
        Darwin.close(directoryDescriptor)
        guard directorySyncSucceeded else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        replacementComplete = true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}
