public struct SpeechOperation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case capture
        case transcription
        case synthesis
        case playback
    }

    public let id: OperationID
    public let generation: Int
    public let kind: Kind

    public init(id: OperationID, generation: Int, kind: Kind) {
        self.id = id
        self.generation = generation
        self.kind = kind
    }
}

public enum TranscriptState: String, Codable, CaseIterable, Sendable {
    case empty
    case partial
    case final
    case editable
    case submitted
    case cancelled
}

public enum TranscriptionEvent: Equatable, Sendable {
    case readiness(CapabilityReadiness)
    case partial(String)
    case final(String)
    case cancelled
    case failed(code: String)
}

public enum SynthesisEvent: Equatable, Sendable {
    case readiness(CapabilityReadiness)
    case playbackStarted(SpeechOperation)
    case completed
    case stopped(audibleTail: Bool)
    case failed(code: String)
}

public protocol SpeechTranscriber: Sendable {
    func transcribe(
        operation: SpeechOperation
    ) -> AsyncStream<TranscriptionEvent>

    func cancel(operation: SpeechOperation) async
}

public protocol SpeechSynthesizer: Sendable {
    func synthesize(
        _ text: String,
        operation: SpeechOperation
    ) -> AsyncStream<SynthesisEvent>

    func stop(operation: SpeechOperation) async
}
