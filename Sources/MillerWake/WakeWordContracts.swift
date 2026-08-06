// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Foundation

public protocol WakeWordDetecting: Sendable {
    var requiredSampleRate: Int { get }
    var requiredFrameLength: Int { get }

    func process(frame: ContiguousArray<Int16>) throws -> Bool
    func reset() throws
    func shutdown()
}

public enum WakeWordDetectorError: Error, Equatable, Sendable {
    case unavailable
    case invalidFrame
    case runtimeFailure
}

public enum WakeWordDetectorStatus: Equatable, Sendable {
    case ready
    case shutDown
}

public struct WakeWordModelPaths: Equatable, Sendable {
    public let encoder: URL
    public let decoder: URL
    public let joiner: URL
    public let tokens: URL
    public let keywords: URL

    public init(
        encoder: URL,
        decoder: URL,
        joiner: URL,
        tokens: URL,
        keywords: URL
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.joiner = joiner
        self.tokens = tokens
        self.keywords = keywords
    }
}

public enum WakeWordUnavailableReason: String, Equatable, Sendable {
    case microphonePermission
    case detectorRuntime
    case model
    case inputDevice
    case assistantMode
    case capture
}

public enum WakeWordSuspensionReason: String, Equatable, Sendable {
    case processing
    case speaking
    case foregroundSession
    case sleep
    case inactiveSession
    case deviceTransition
}

public enum WakeWordState: Equatable, Sendable {
    case disabled
    case unavailable(WakeWordUnavailableReason)
    case starting
    case monitoring
    case handoff
    case capturingCommand
    case suspended(WakeWordSuspensionReason)
    case stopping
}

public enum WakeCommandEndpointEvent: Equatable, Sendable {
    case continueListening
    case emptyWakeTimeout
    case silence
    case hardLimit
}

public enum WakeWordCoordinatorEvent: Equatable, Sendable {
    case wakeDetected(generation: UInt64)
    case commandEndpoint(generation: UInt64, reason: WakeCommandEndpointEvent)
    case detectorUnavailable(generation: UInt64)
}

public struct WakeWordPreparedCommandAudio: Equatable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public let samples: ContiguousArray<Int16>
    public let sampleRate: Int
}

/// One-shot bridge from detector-owned post-keyword audio to Miller's audio
/// owner. The coordinator remains the only authority for consuming it.
public final class WakeWordCaptureHandoff: @unchecked Sendable {
    public let monitoringSessionID: UUID
    public let generation: UInt64
    private let coordinator: WakeWordCoordinator

    public init(
        monitoringSessionID: UUID,
        generation: UInt64,
        coordinator: WakeWordCoordinator
    ) {
        self.monitoringSessionID = monitoringSessionID
        self.generation = generation
        self.coordinator = coordinator
    }

    public func consume() -> WakeWordPreparedCommandAudio? {
        coordinator.beginCommandCapture(generation: generation)
    }
}

public enum WakeWordPhraseError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case unsupportedToken(String)
    case tooManyTokens
}

/// Deterministic bounded compiler for the token vocabulary consumed by the
/// Sherpa keyword file. Task 17 supplies the bundled vocabulary and persists
/// the resulting token sequence only after local calibration succeeds.
public struct WakeWordPhraseCompiler: Sendable {
    public let maximumUTF8Bytes: Int
    public let maximumTokens: Int
    private let tokenIDs: [String: Int]

    public init(
        tokens: [String],
        maximumUTF8Bytes: Int = 128,
        maximumTokens: Int = 64
    ) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.maximumTokens = maximumTokens
        tokenIDs = tokens.enumerated().reduce(into: [:]) { result, entry in
            if result[entry.element] == nil {
                result[entry.element] = entry.offset
            }
        }
    }

    public func compile(_ phrase: String) throws -> [Int] {
        let normalized = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { throw WakeWordPhraseError.empty }
        guard normalized.utf8.count <= maximumUTF8Bytes else {
            throw WakeWordPhraseError.tooLong
        }

        var result = [Int]()
        for word in normalized.split(whereSeparator: { $0.isWhitespace }) {
            let wholeToken = "▁\(word)"
            if let id = tokenIDs[wholeToken] {
                result.append(id)
            } else {
                for (index, character) in word.enumerated() {
                    let token = index == 0 ? "▁\(character)" : String(character)
                    guard let id = tokenIDs[token] ?? tokenIDs[String(character)] else {
                        throw WakeWordPhraseError.unsupportedToken(String(character))
                    }
                    result.append(id)
                }
            }
            guard result.count <= maximumTokens else {
                throw WakeWordPhraseError.tooManyTokens
            }
        }
        return result
    }
}
