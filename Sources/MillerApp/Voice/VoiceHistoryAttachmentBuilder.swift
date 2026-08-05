import Darwin
import Foundation
import MillerCore
import MillerStorage

enum VoiceHistoryAttachmentBuilderError: Error, Equatable {
    case emptySelection
    case selectedHistoryUnavailable
}

struct PreparedVoiceHistoryAttachment: Equatable, Sendable {
    let sessionIDs: [UUID]
    let attachment: VoiceHistoryAttachment
    let truncated: Bool
}

struct VoiceHistoryAttachmentBuilder {
    static let maximumBytes = 32 * 1_024

    func build(
        from projections: [VoiceHistoryExportSession]
    ) throws -> PreparedVoiceHistoryAttachment {
        guard !projections.isEmpty else {
            throw VoiceHistoryAttachmentBuilderError.emptySelection
        }

        let orderedSessions = projections.sorted(by: Self.sessionOrder)
        let sessionIDs = orderedSessions.map(\.session.id)
        let lines = orderedSessions
            .flatMap { projection in
                projection.entries.map { (projection.session.startedAt, $0) }
            }
            .sorted(by: Self.entryOrder)

        let complete = Self.envelope(
            lines: lines.map { Self.line(for: $0.1) },
            truncated: false
        )
        if complete.utf8.count <= Self.maximumBytes {
            return try .init(
                sessionIDs: sessionIDs,
                attachment: VoiceHistoryAttachment(text: complete),
                truncated: false
            )
        }

        let bounded = Self.boundedEnvelope(lines: lines.map { $0.1 })
        return try .init(
            sessionIDs: sessionIDs,
            attachment: VoiceHistoryAttachment(text: bounded),
            truncated: true
        )
    }

    func build(
        from projection: VoiceHistoryAttachmentProjection
    ) throws -> PreparedVoiceHistoryAttachment {
        guard projection.selectionIsValid else {
            throw VoiceHistoryAttachmentBuilderError.selectedHistoryUnavailable
        }
        guard !projection.sessionIDs.isEmpty else {
            throw VoiceHistoryAttachmentBuilderError.emptySelection
        }
        let orderedEntries = projection.entries.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        let complete = Self.envelope(
            lines: orderedEntries.map(Self.line),
            truncated: projection.hasMore
        )
        if !projection.hasMore, complete.utf8.count <= Self.maximumBytes {
            return try .init(
                sessionIDs: projection.sessionIDs,
                attachment: VoiceHistoryAttachment(text: complete),
                truncated: false
            )
        }
        return try .init(
            sessionIDs: projection.sessionIDs,
            attachment: VoiceHistoryAttachment(text: Self.boundedEnvelope(lines: orderedEntries)),
            truncated: true
        )
    }

    private static func sessionOrder(
        _ lhs: VoiceHistoryExportSession,
        _ rhs: VoiceHistoryExportSession
    ) -> Bool {
        if lhs.session.startedAt != rhs.session.startedAt {
            return lhs.session.startedAt < rhs.session.startedAt
        }
        return lhs.session.id.uuidString < rhs.session.id.uuidString
    }

    private static func entryOrder(
        _ lhs: (Date, VoiceHistoryEntry),
        _ rhs: (Date, VoiceHistoryEntry)
    ) -> Bool {
        if lhs.1.startedAt != rhs.1.startedAt {
            return lhs.1.startedAt < rhs.1.startedAt
        }
        if lhs.0 != rhs.0 {
            return lhs.0 < rhs.0
        }
        if lhs.1.sequence != rhs.1.sequence {
            return lhs.1.sequence < rhs.1.sequence
        }
        return lhs.1.id.uuidString < rhs.1.id.uuidString
    }

    private static func line(for entry: VoiceHistoryEntry) -> String {
        "[\(timestamp(entry.startedAt))] \(role(entry.role)): \(escape(entry.text))"
    }

    private static func envelope(lines: [String], truncated: Bool) -> String {
        let header = "<miller_voice_history selection=\"explicit\" truncated=\"\(truncated)\">"
        let body = lines.joined(separator: "\n")
        return body.isEmpty
            ? "\(header)\n</miller_voice_history>"
            : "\(header)\n\(body)\n</miller_voice_history>"
    }

    private static func boundedEnvelope(lines: [VoiceHistoryEntry]) -> String {
        let header = "<miller_voice_history selection=\"explicit\" truncated=\"true\">\n"
        let footer = "</miller_voice_history>"
        var body = ""
        var remaining = maximumBytes - header.utf8.count - footer.utf8.count

        for entry in lines {
            let prefix = "[\(timestamp(entry.startedAt))] \(role(entry.role)): "
            let fullLine = prefix + escape(entry.text) + "\n"
            if fullLine.utf8.count <= remaining {
                body += fullLine
                remaining -= fullLine.utf8.count
                continue
            }

            let contentBudget = remaining - prefix.utf8.count - 1
            if contentBudget > 0 {
                body += prefix
                body += escapedPrefix(entry.text, maximumBytes: contentBudget)
                body += "\n"
            }
            break
        }

        return header + body + footer
    }

    private static func escapedPrefix(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        var result = ""
        var used = 0
        for character in value {
            let escaped = escape(String(character))
            let bytes = escaped.utf8.count
            guard used + bytes <= maximumBytes else { break }
            result += escaped
            used += bytes
        }
        return result
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func role(_ value: VoiceTranscriptRole) -> String {
        switch value {
        case .user: "You"
        case .assistant: "Miller"
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum VoiceHistoryExportDocument {
    private struct Document: Encodable {
        let format = "miller.voice-history.v1"
        let sessions: [Session]
    }

    private struct Session: Encodable {
        let id: UUID
        let conversationID: String?
        let activationSource: String
        let startedAt: Date
        let endedAt: Date?
        let terminalOutcome: String?
        let saveChoice: String
        let entries: [Entry]
    }

    private struct Entry: Encodable {
        let id: UUID
        let sequence: Int
        let role: String
        let text: String
        let completionState: String
        let startedAt: Date
        let completedAt: Date?
    }

    static func encode(
        _ projections: [VoiceHistoryExportSession]
    ) throws -> Data {
        let ordered = projections
            .sorted {
                if $0.session.startedAt != $1.session.startedAt {
                    return $0.session.startedAt < $1.session.startedAt
                }
                return $0.session.id.uuidString < $1.session.id.uuidString
            }
            .map { projection in
                Session(
                    id: projection.session.id,
                    conversationID: projection.session.conversationID?.description,
                    activationSource: projection.session.activationSource.rawValue,
                    startedAt: projection.session.startedAt,
                    endedAt: projection.session.endedAt,
                    terminalOutcome: projection.session.terminalOutcome?.rawValue,
                    saveChoice: projection.session.saveChoice.rawValue,
                    entries: projection.entries.sorted {
                        if $0.startedAt != $1.startedAt {
                            return $0.startedAt < $1.startedAt
                        }
                        if $0.sequence != $1.sequence {
                            return $0.sequence < $1.sequence
                        }
                        return $0.id.uuidString < $1.id.uuidString
                    }.map {
                        Entry(
                            id: $0.id,
                            sequence: $0.sequence,
                            role: $0.role.rawValue,
                            text: $0.text,
                            completionState: $0.completionState.rawValue,
                            startedAt: $0.startedAt,
                            completedAt: $0.completedAt
                        )
                    }
                )
            }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(sessions: ordered))
    }

    static func write(
        _ projections: [VoiceHistoryExportSession],
        to url: URL
    ) throws {
        let data = try encode(projections)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
