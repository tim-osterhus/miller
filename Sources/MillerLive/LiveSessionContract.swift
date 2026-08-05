import Foundation

public enum LiveSessionState: Equatable, Sendable {
    case idle
    case starting
    case active
    case stopping
    case closed
    case failed
}

public enum LiveTerminalOutcome: Equatable, Sendable {
    case closed
    case failed
}

public struct LiveSessionIdentity: Equatable, Sendable {
    public let requestID: String
    public let threadID: String
    public let generation: Int

    public init(requestID: String, threadID: String, generation: Int) {
        self.requestID = requestID
        self.threadID = threadID
        self.generation = generation
    }
}

public struct LiveSessionLimits: Equatable, Sendable {
    public let maximumTranscriptBytes: Int
    public let maximumAudioBytes: Int
    public let maximumCumulativeTranscriptBytes: Int
    public let maximumCumulativeAudioBytes: Int
    public let maximumCumulativeRetainedStringBytes: Int
    public let maximumEvents: Int

    public init(
        maximumTranscriptBytes: Int = 65_536,
        maximumAudioBytes: Int = 1_048_576,
        maximumCumulativeTranscriptBytes: Int = 1_048_576,
        maximumCumulativeAudioBytes: Int = 33_554_432,
        maximumCumulativeRetainedStringBytes: Int = 2_097_152,
        maximumEvents: Int = 10_000
    ) {
        self.maximumTranscriptBytes = maximumTranscriptBytes
        self.maximumAudioBytes = maximumAudioBytes
        self.maximumCumulativeTranscriptBytes = maximumCumulativeTranscriptBytes
        self.maximumCumulativeAudioBytes = maximumCumulativeAudioBytes
        self.maximumCumulativeRetainedStringBytes = maximumCumulativeRetainedStringBytes
        self.maximumEvents = maximumEvents
    }
}

public struct LiveAudioFrame: Equatable, Sendable {
    public let data: Data
    public let sampleRate: Int
    public let numChannels: Int
    public let samplesPerChannel: Int?
    public let itemID: String?

    public init(
        data: Data,
        sampleRate: Int,
        numChannels: Int,
        samplesPerChannel: Int?,
        itemID: String?,
        requirePCM16Alignment: Bool = true
    ) throws {
        guard sampleRate > 0, sampleRate <= Int(UInt32.max),
              numChannels > 0, numChannels <= Int(UInt16.max),
              samplesPerChannel.map({ $0 >= 0 && $0 <= Int(UInt32.max) }) ?? true,
              itemID.map({ !$0.isEmpty && $0.utf8.count <= 65_536 }) ?? true,
              !requirePCM16Alignment || data.count.isMultiple(of: 2 * numChannels)
        else { throw LiveProtocolError.invalidField }
        self.data = data
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.samplesPerChannel = samplesPerChannel
        self.itemID = itemID
    }

    public var duration: Duration {
        let samples = samplesPerChannel ?? data.count / max(1, 2 * numChannels)
        return .seconds(Double(samples) / Double(sampleRate))
    }
}

public enum LiveSessionEvent: Equatable, Sendable {
    case started(threadID: String)
    case sdp(threadID: String, value: String)
    case transcriptDelta(threadID: String, role: String, delta: String)
    case transcriptDone(threadID: String, role: String, text: String)
    case outputAudio(threadID: String, audio: LiveAudioFrame)
    case closed(threadID: String, reason: String?)
    case failed(threadID: String, message: String)

    var threadID: String {
        switch self {
        case let .started(threadID), let .sdp(threadID, _),
             let .transcriptDelta(threadID, _, _),
             let .transcriptDone(threadID, _, _),
             let .outputAudio(threadID, _), let .closed(threadID, _),
             let .failed(threadID, _):
            threadID
        }
    }
}

public enum LiveSessionError: Error, Equatable, Sendable {
    case invalidSequence
    case staleGeneration
    case wrongThread
    case duplicateTerminal
    case eventAfterStop
    case payloadTooLarge
    case cumulativePayloadTooLarge
    case eventLimitExceeded
}

public struct LiveSessionContract: Sendable {
    public private(set) var state: LiveSessionState = .idle
    public private(set) var terminalOutcome: LiveTerminalOutcome?
    public private(set) var identity: LiveSessionIdentity?

    private let limits: LiveSessionLimits
    private var eventCount = 0
    private var cumulativeTranscriptBytes = 0
    private var cumulativeAudioBytes = 0
    private var cumulativeRetainedStringBytes = 0

    public init(limits: LiveSessionLimits = .init()) {
        self.limits = limits
    }

    public mutating func begin(_ identity: LiveSessionIdentity) throws {
        guard state == .idle else { throw LiveSessionError.invalidSequence }
        self.identity = identity
        state = .starting
    }

    @discardableResult
    public mutating func requestStop(generation: Int) throws -> Bool {
        try validateGeneration(generation)
        if state == .stopping { return false }
        guard state == .starting || state == .active else {
            throw LiveSessionError.invalidSequence
        }
        state = .stopping
        return true
    }

    public mutating func accept(
        _ event: LiveSessionEvent,
        generation: Int
    ) throws {
        try validateGeneration(generation)
        guard event.threadID == identity?.threadID else {
            throw LiveSessionError.wrongThread
        }
        if terminalOutcome != nil { throw LiveSessionError.duplicateTerminal }
        if state == .stopping {
            switch event {
            case .closed, .failed: break
            default: throw LiveSessionError.eventAfterStop
            }
        }
        try validateSequence(event)
        let payload = try validatePayload(event)
        guard cumulativeTranscriptBytes + payload.transcript
                <= limits.maximumCumulativeTranscriptBytes,
              cumulativeAudioBytes + payload.audio
                <= limits.maximumCumulativeAudioBytes,
              cumulativeRetainedStringBytes + payload.retainedStrings
                <= limits.maximumCumulativeRetainedStringBytes
        else { throw LiveSessionError.cumulativePayloadTooLarge }
        guard eventCount < limits.maximumEvents else {
            throw LiveSessionError.eventLimitExceeded
        }
        eventCount += 1
        cumulativeTranscriptBytes += payload.transcript
        cumulativeAudioBytes += payload.audio
        cumulativeRetainedStringBytes += payload.retainedStrings

        switch event {
        case .started:
            state = .active
        case .closed:
            state = .closed
            terminalOutcome = .closed
        case .failed:
            state = .failed
            terminalOutcome = .failed
        default: break
        }
    }

    private func validateSequence(_ event: LiveSessionEvent) throws {
        switch event {
        case .started:
            guard state == .starting else { throw LiveSessionError.invalidSequence }
        case .closed, .failed:
            guard state == .starting || state == .active || state == .stopping else {
                throw LiveSessionError.invalidSequence
            }
        default:
            guard state == .active else { throw LiveSessionError.invalidSequence }
        }
    }

    private func validateGeneration(_ generation: Int) throws {
        guard generation == identity?.generation else {
            throw LiveSessionError.staleGeneration
        }
    }

    private func validatePayload(_ event: LiveSessionEvent) throws -> (
        transcript: Int,
        audio: Int,
        retainedStrings: Int
    ) {
        let threadBytes = event.threadID.utf8.count
        switch event {
        case let .transcriptDelta(_, role, text),
             let .transcriptDone(_, role, text):
            guard text.utf8.count <= limits.maximumTranscriptBytes else {
                throw LiveSessionError.payloadTooLarge
            }
            return (text.utf8.count, 0, threadBytes + role.utf8.count + text.utf8.count)
        case let .sdp(_, text),
             let .failed(_, text):
            guard text.utf8.count <= limits.maximumTranscriptBytes else {
                throw LiveSessionError.payloadTooLarge
            }
            return (text.utf8.count, 0, threadBytes + text.utf8.count)
        case let .outputAudio(_, audio):
            guard audio.data.count <= limits.maximumAudioBytes else {
                throw LiveSessionError.payloadTooLarge
            }
            return (0, audio.data.count, threadBytes + (audio.itemID?.utf8.count ?? 0))
        case let .closed(_, reason):
            let bytes = reason?.utf8.count ?? 0
            guard bytes <= limits.maximumTranscriptBytes else {
                throw LiveSessionError.payloadTooLarge
            }
            return (bytes, 0, threadBytes + bytes)
        case .started:
            return (0, 0, threadBytes)
        }
    }
}
