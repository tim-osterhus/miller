import Darwin
import Foundation

public enum WakeWordKeywordMaterializerError: Error, Equatable, Sendable {
    case tokensFileMissing
    case malformedTokensFile
    case tokensFileTooLarge
    case bpeModelMissing
    case malformedBPEModel
    case bpeModelTooLarge
    case unsafePath
    case writeFailed
    case rollbackFailed
}

enum WakeWordKeywordMaterializerFaultInjection: Sendable {
    case none
    case failAfterInstall
    case failAfterInstallAndRollback
}

private enum SentencePieceScoreParser {
    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            for byteIndex in 0..<10 {
                guard index < bytes.count else { throw malformed }
                let byte = bytes[index]
                index += 1
                if byteIndex == 9 {
                    guard byte & 0x80 == 0, byte & 0x7f <= 1 else {
                        throw malformed
                    }
                }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            throw malformed
        }

        mutating func readLengthDelimited() throws -> [UInt8] {
            let length = try readVarint()
            guard length <= UInt64(bytes.count - index) else { throw malformed }
            let end = index + Int(length)
            defer { index = end }
            return Array(bytes[index..<end])
        }

        mutating func readFloat() throws -> Float {
            guard bytes.count - index >= 4 else { throw malformed }
            let bits = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            index += 4
            return Float(bitPattern: bits)
        }

        mutating func skip(wireType: UInt64) throws {
            switch wireType {
            case 0:
                _ = try readVarint()
            case 1:
                guard bytes.count - index >= 8 else { throw malformed }
                index += 8
            case 2:
                _ = try readLengthDelimited()
            case 5:
                guard bytes.count - index >= 4 else { throw malformed }
                index += 4
            default:
                throw malformed
            }
        }
    }

    private static var malformed: WakeWordKeywordMaterializerError {
        .malformedBPEModel
    }

    static func parse(
        _ data: Data,
        allowedTokens: Set<String>
    ) throws -> [String: Float] {
        var reader = Reader(bytes: Array(data))
        var scores = [String: Float]()
        var modelType: UInt64?
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let field = tag >> 3
            let wire = tag & 7
            if field == 1, wire == 2 {
                let piece = try parsePiece(reader.readLengthDelimited())
                if piece.type == 1,
                   piece.score.isFinite,
                   allowedTokens.contains(piece.token)
                {
                    scores[piece.token] = piece.score
                }
            } else if field == 2, wire == 2 {
                modelType = try parseModelType(reader.readLengthDelimited())
            } else {
                try reader.skip(wireType: wire)
            }
        }
        guard modelType == 1, !scores.isEmpty else { throw malformed }
        return scores
    }

    private static func parseModelType(_ bytes: [UInt8]) throws -> UInt64? {
        var reader = Reader(bytes: bytes)
        var modelType: UInt64?
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let field = tag >> 3
            let wire = tag & 7
            if field == 3, wire == 0 {
                modelType = try reader.readVarint()
            } else {
                try reader.skip(wireType: wire)
            }
        }
        return modelType
    }

    private static func parsePiece(
        _ bytes: [UInt8]
    ) throws -> (token: String, score: Float, type: UInt64) {
        var reader = Reader(bytes: bytes)
        var token: String?
        var score: Float?
        var type: UInt64 = 1
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let field = tag >> 3
            let wire = tag & 7
            switch (field, wire) {
            case (1, 2):
                guard let value = String(
                    bytes: try reader.readLengthDelimited(),
                    encoding: .utf8
                ) else { throw malformed }
                token = value
            case (2, 5):
                score = try reader.readFloat()
            case (3, 0):
                type = try reader.readVarint()
            default:
                try reader.skip(wireType: wire)
            }
        }
        guard let token, !token.isEmpty, let score else { throw malformed }
        return (token, score, type)
    }
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
    public static let maximumBPEModelBytes = 2 * 1024 * 1024
    public static let keywordFileName = "wake-keywords.txt"

    private let tokensFile: URL
    private let applicationSupportDirectory: URL
    private let keywordFileName: String
    private let vocabulary: [String]
    private let tokenScores: [String: Float]
    private let faultInjection: WakeWordKeywordMaterializerFaultInjection

    public init(
        tokensFile: URL,
        bpeModel: URL? = nil,
        applicationSupportDirectory: URL,
        keywordFileName: String = Self.keywordFileName
    ) throws {
        try self.init(
            tokensFile: tokensFile,
            bpeModel: bpeModel,
            applicationSupportDirectory: applicationSupportDirectory,
            keywordFileName: keywordFileName,
            faultInjection: .none
        )
    }

    init(
        tokensFile: URL,
        bpeModel: URL? = nil,
        applicationSupportDirectory: URL,
        keywordFileName: String = Self.keywordFileName,
        faultInjection: WakeWordKeywordMaterializerFaultInjection
    ) throws {
        guard tokensFile.isFileURL,
              applicationSupportDirectory.isFileURL,
              !keywordFileName.isEmpty,
              !keywordFileName.contains("/"),
              keywordFileName != ".",
              keywordFileName != "..",
              !keywordFileName.contains("\0")
        else { throw WakeWordKeywordMaterializerError.unsafePath }
        self.tokensFile = tokensFile
        self.applicationSupportDirectory = applicationSupportDirectory
        self.keywordFileName = keywordFileName
        let data = try Self.readBoundedRegularFile(
            at: tokensFile,
            maximumBytes: Self.maximumTokensFileBytes,
            missing: .tokensFileMissing,
            tooLarge: .tokensFileTooLarge
        )
        guard let text = String(data: data, encoding: .utf8),
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
        if let bpeModel {
            guard bpeModel.isFileURL else {
                throw WakeWordKeywordMaterializerError.unsafePath
            }
            let modelData = try Self.readBoundedRegularFile(
                at: bpeModel,
                maximumBytes: Self.maximumBPEModelBytes,
                missing: .bpeModelMissing,
                tooLarge: .bpeModelTooLarge
            )
            tokenScores = try SentencePieceScoreParser.parse(
                modelData,
                allowedTokens: Set(parsed.keys)
            )
        } else {
            tokenScores = [:]
        }
        self.faultInjection = faultInjection
    }

    private static func readBoundedRegularFile(
        at url: URL,
        maximumBytes: Int,
        missing: WakeWordKeywordMaterializerError,
        tooLarge: WakeWordKeywordMaterializerError
    ) throws -> Data {
        guard url.isFileURL else {
            throw WakeWordKeywordMaterializerError.unsafePath
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw WakeWordKeywordMaterializerError.unsafePath
            }
            throw missing
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw missing }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw WakeWordKeywordMaterializerError.unsafePath
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
            throw tooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw missing
            }
            guard data.count + count <= maximumBytes else { throw tooLarge }
            data.append(buffer, count: count)
        }
        return data
    }

    public var url: URL {
        applicationSupportDirectory.appendingPathComponent(
            keywordFileName,
            isDirectory: false
        )
    }

    public func materialize(_ phrase: String) throws -> WakeWordMaterializedPhrase {
        let compiler = WakeWordPhraseCompiler(
            tokens: vocabulary,
            tokenScores: tokenScores
        )
        let normalized = try compiler.normalize(phrase)
        let tokens = try compiler.tokenize(normalized)
        let contents = Data((tokens.joined(separator: " ") + "\n").utf8)
        let directoryDescriptor = try openPrivateDirectory()
        defer { Darwin.close(directoryDescriptor) }
        let previousContents = try readExistingFile(
            in: directoryDescriptor
        )
        try atomicReplace(contents, in: directoryDescriptor)
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
        let directoryDescriptor = try openPrivateDirectory()
        defer { Darwin.close(directoryDescriptor) }
        if let previousContents = materialized.previousContents {
            try atomicReplace(previousContents, in: directoryDescriptor)
        } else {
            try Self.remove(named: keywordFileName, in: directoryDescriptor)
        }
    }

    public func remove() throws {
        let directoryDescriptor = try openPrivateDirectory()
        defer { Darwin.close(directoryDescriptor) }
        try Self.remove(
            named: keywordFileName,
            in: directoryDescriptor
        )
    }

    public static func removeKeywordFile(at fileURL: URL) throws {
        guard fileURL.isFileURL,
              fileURL.lastPathComponent == Self.keywordFileName
        else { throw WakeWordKeywordMaterializerError.unsafePath }
        let directory = try Self.openPrivateDirectory(
            at: fileURL.deletingLastPathComponent()
        )
        defer { Darwin.close(directory) }
        try Self.remove(named: Self.keywordFileName, in: directory)
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

    private func openPrivateDirectory() throws -> Int32 {
        try Self.openPrivateDirectory(at: applicationSupportDirectory)
    }

    private static func openPrivateDirectory(at directory: URL) throws -> Int32 {
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(
            atPath: directory.path
        ), let type = attributes[.type] as? FileAttributeType {
            guard type == .typeDirectory else {
                throw WakeWordKeywordMaterializerError.unsafePath
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
        }
        let descriptor = directory.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw WakeWordKeywordMaterializerError.unsafePath
            }
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0 else {
            Darwin.close(descriptor)
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw WakeWordKeywordMaterializerError.unsafePath
        }
        guard fchmod(descriptor, 0o700) == 0 else {
            Darwin.close(descriptor)
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        return descriptor
    }

    private enum EntryKind: Equatable {
        case absent
        case regular
        case symbolicLink
        case other
    }

    private static func entryKind(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> EntryKind {
        var info = stat()
        let result = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &info,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else {
            if errno == ENOENT { return .absent }
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    private func readExistingFile(in directoryDescriptor: Int32) throws -> Data? {
        switch try Self.entryKind(named: keywordFileName, in: directoryDescriptor) {
        case .absent:
            return nil
        case .symbolicLink, .other:
            throw WakeWordKeywordMaterializerError.unsafePath
        case .regular:
            let descriptor = keywordFileName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                if errno == ELOOP { throw WakeWordKeywordMaterializerError.unsafePath }
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            defer { Darwin.close(descriptor) }
            return try readData(from: descriptor)
        }
    }

    private func readData(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            guard count > 0 else { return result }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 64 * 1_024 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
        }
    }

    private static func remove(
        named name: String,
        in directoryDescriptor: Int32
    ) throws {
        switch try Self.entryKind(named: name, in: directoryDescriptor) {
        case .absent:
            return
        case .symbolicLink, .other:
            throw WakeWordKeywordMaterializerError.unsafePath
        case .regular:
            let result = name.withCString {
                unlinkat(directoryDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
        }
    }

    private func atomicReplace(
        _ data: Data,
        in directoryDescriptor: Int32
    ) throws {
        let temporaryName = ".\(keywordFileName).\(UUID().uuidString).tmp"
        let backupName = ".\(keywordFileName).\(UUID().uuidString).bak"
        var temporaryDescriptor: Int32 = -1
        var temporaryCreated = false
        var oldFileMovedToBackup = false
        var newFileInstalled = false

        do {
            temporaryDescriptor = temporaryName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
            }
            guard temporaryDescriptor >= 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            temporaryCreated = true
            guard fchmod(temporaryDescriptor, 0o600) == 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            try writeAndSync(data, to: temporaryDescriptor)

        switch try Self.entryKind(named: keywordFileName, in: directoryDescriptor) {
            case .absent:
                break
            case .symbolicLink, .other:
                throw WakeWordKeywordMaterializerError.unsafePath
            case .regular:
                let result = renameat(
                    directoryDescriptor,
                    keywordFileName,
                    directoryDescriptor,
                    backupName
                )
                guard result == 0 else {
                    throw WakeWordKeywordMaterializerError.unsafePath
                }
                oldFileMovedToBackup = true
            }

            guard renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                keywordFileName
            ) == 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            temporaryCreated = false
            newFileInstalled = true
            guard Darwin.fsync(temporaryDescriptor) == 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            guard try installedFileIsCurrent(
                descriptor: temporaryDescriptor,
                in: directoryDescriptor
            ) else {
                throw WakeWordKeywordMaterializerError.unsafePath
            }
            if faultInjection == .failAfterInstall
                || faultInjection == .failAfterInstallAndRollback
            {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw WakeWordKeywordMaterializerError.writeFailed
            }
            if oldFileMovedToBackup {
                guard unlinkat(directoryDescriptor, backupName, 0) == 0 else {
                    throw WakeWordKeywordMaterializerError.writeFailed
                }
            }
            Darwin.close(temporaryDescriptor)
            temporaryDescriptor = -1
        } catch let error as WakeWordKeywordMaterializerError {
            if temporaryDescriptor >= 0 {
                Darwin.close(temporaryDescriptor)
                temporaryDescriptor = -1
            }
            guard rollback(
                directoryDescriptor: directoryDescriptor,
                temporaryName: temporaryName,
                backupName: backupName,
                temporaryCreated: temporaryCreated,
                oldFileMovedToBackup: oldFileMovedToBackup,
                newFileInstalled: newFileInstalled
            ) else {
                throw WakeWordKeywordMaterializerError.rollbackFailed
            }
            throw error
        } catch {
            if temporaryDescriptor >= 0 {
                Darwin.close(temporaryDescriptor)
                temporaryDescriptor = -1
            }
            guard rollback(
                directoryDescriptor: directoryDescriptor,
                temporaryName: temporaryName,
                backupName: backupName,
                temporaryCreated: temporaryCreated,
                oldFileMovedToBackup: oldFileMovedToBackup,
                newFileInstalled: newFileInstalled
            ) else {
                throw WakeWordKeywordMaterializerError.rollbackFailed
            }
            throw WakeWordKeywordMaterializerError.writeFailed
        }
    }

    private func writeAndSync(_ data: Data, to descriptor: Int32) throws {
        var succeeded = true
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    succeeded = false
                    return
                }
                offset += written
            }
        }
        guard succeeded, Darwin.fsync(descriptor) == 0 else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
    }

    private func installedFileIsCurrent(
        descriptor: Int32,
        in directoryDescriptor: Int32
    ) throws -> Bool {
        var installed = stat()
        guard fstat(descriptor, &installed) == 0 else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        var current = stat()
        guard keywordFileName.withCString({
            fstatat(
                directoryDescriptor,
                $0,
                &current,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0 else {
            throw WakeWordKeywordMaterializerError.writeFailed
        }
        return installed.st_dev == current.st_dev
            && installed.st_ino == current.st_ino
    }

    private func rollback(
        directoryDescriptor: Int32,
        temporaryName: String,
        backupName: String,
        temporaryCreated: Bool,
        oldFileMovedToBackup: Bool,
        newFileInstalled: Bool
    ) -> Bool {
        if faultInjection == .failAfterInstallAndRollback {
            return false
        }
        var succeeded = true
        if temporaryCreated {
            let result = temporaryName.withCString {
                unlinkat(directoryDescriptor, $0, 0)
            }
            if result != 0, errno != ENOENT { succeeded = false }
        }
        if oldFileMovedToBackup {
            guard renameat(
                directoryDescriptor,
                backupName,
                directoryDescriptor,
                keywordFileName
            ) == 0 else { return false }
        } else if newFileInstalled {
            do {
                guard try Self.entryKind(
                    named: keywordFileName,
                    in: directoryDescriptor
                ) == .regular else { return false }
                guard keywordFileName.withCString({
                    unlinkat(directoryDescriptor, $0, 0)
                }) == 0 else { return false }
            } catch {
                return false
            }
        }
        if Darwin.fsync(directoryDescriptor) != 0 { succeeded = false }
        return succeeded
    }
}
