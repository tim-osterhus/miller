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

public enum WakeWordCaptureStartError: Error, Equatable, Sendable {
    case permissionDenied
    case inputDeviceUnavailable
    case captureFailed
    case microphoneBusy
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
    case deviceTransition
}

public enum WakeWordState: Equatable, Sendable {
    case disabled
    case unavailable(WakeWordUnavailableReason)
    case starting
    case monitoring
    case suspended(WakeWordSuspensionReason)
    case stopping
}

public enum WakeWordCoordinatorEvent: Equatable, Sendable {
    case wakeDetected(generation: UInt64)
    case detectorUnavailable(generation: UInt64)
}

public enum WakeWordPhraseError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case unsupportedToken(String)
    case tooManyTokens
}

/// Deterministic bounded compiler for the token vocabulary consumed by the
/// Sherpa keyword file. Runtime persistence and audio ownership stay outside
/// this value type.
public struct WakeWordPhraseCompiler: Sendable {
    public let maximumUTF8Bytes: Int
    public let maximumTokens: Int
    private let tokenIDs: [String: Int]
    private let scoredTokens: [(token: String, characters: [Character], score: Float)]

    public init(
        tokens: [String],
        tokenScores: [String: Float] = [:],
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
        scoredTokens = tokens.compactMap { token in
            guard let score = tokenScores[token], score.isFinite else {
                return nil
            }
            return (token, Array(token), score)
        }
    }

    public func compile(_ phrase: String) throws -> [Int] {
        try tokenize(phrase).compactMap { tokenIDs[$0] }
    }

    public func normalize(_ phrase: String) throws -> String {
        let normalized = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { throw WakeWordPhraseError.empty }
        guard normalized.utf8.count <= maximumUTF8Bytes else {
            throw WakeWordPhraseError.tooLong
        }
        for scalar in normalized.unicodeScalars {
            guard scalar == " " || (scalar.value >= 0x61 && scalar.value <= 0x7A) else {
                throw WakeWordPhraseError.unsupportedToken(String(scalar))
            }
        }
        return normalized
    }

    public func tokenize(_ phrase: String) throws -> [String] {
        let normalized = try normalize(phrase)
        if !scoredTokens.isEmpty {
            return try tokenizeSentencePiece(normalized)
        }
        var result = [String]()
        for word in normalized.split(separator: " ") {
            let wholeToken = "▁\(word)"
            if tokenIDs[wholeToken] != nil {
                result.append(wholeToken)
            } else {
                for (index, character) in word.enumerated() {
                    let token = index == 0 ? "▁\(character)" : String(character)
                    guard tokenIDs[token] != nil || tokenIDs[String(character)] != nil else {
                        throw WakeWordPhraseError.unsupportedToken(String(character))
                    }
                    result.append(tokenIDs[token] != nil ? token : String(character))
                }
            }
            guard result.count <= maximumTokens else {
                throw WakeWordPhraseError.tooManyTokens
            }
        }
        return result
    }

    private func tokenizeSentencePiece(_ normalized: String) throws -> [String] {
        let input = Array("▁" + normalized.uppercased().replacingOccurrences(
            of: " ", with: "▁"
        ))
        var bestScores = Array<Float?>(repeating: nil, count: input.count + 1)
        var bestPaths = Array<[String]?>(repeating: nil, count: input.count + 1)
        bestScores[0] = 0
        bestPaths[0] = []

        for start in input.indices {
            guard let currentScore = bestScores[start],
                  let currentPath = bestPaths[start]
            else { continue }
            for candidate in scoredTokens {
                let end = start + candidate.characters.count
                guard end <= input.count,
                      input[start..<end].elementsEqual(candidate.characters)
                else { continue }
                let score = currentScore + candidate.score
                if bestScores[end] == nil || score > bestScores[end]! {
                    bestScores[end] = score
                    bestPaths[end] = currentPath + [candidate.token]
                }
            }
        }

        guard let result = bestPaths[input.count] else {
            let reachable = bestScores.indices.last(where: { bestScores[$0] != nil }) ?? 0
            let failed = reachable < input.count && input[reachable] != "▁"
                ? String(input[reachable]).lowercased()
                : normalized
            throw WakeWordPhraseError.unsupportedToken(failed)
        }
        guard result.count <= maximumTokens else {
            throw WakeWordPhraseError.tooManyTokens
        }
        return result
    }
}
