@testable import MillerLive
import Foundation
import Testing

struct LiveSessionContractTests {
    private let identity = LiveSessionIdentity(
        requestID: "request-1",
        threadID: "thread-1",
        generation: 7
    )

    @Test
    func followsTruthfulLifecycleAndProducesOneTerminalOutcome() throws {
        var session = LiveSessionContract()
        #expect(session.state == .idle)

        try session.begin(identity)
        #expect(session.state == .starting)
        try session.accept(.started(threadID: "thread-1"), generation: 7)
        #expect(session.state == .active)
        #expect(try session.requestStop(generation: 7))
        #expect(session.state == .stopping)
        #expect(try !session.requestStop(generation: 7))
        try session.accept(.closed(threadID: "thread-1", reason: nil), generation: 7)
        #expect(session.state == .closed)
        #expect(session.terminalOutcome == .closed)

        #expect(throws: LiveSessionError.duplicateTerminal) {
            try session.accept(.closed(threadID: "thread-1", reason: nil), generation: 7)
        }
    }

    @Test
    func rejectsWrongGenerationThreadAndLateEvents() throws {
        var session = LiveSessionContract()
        try session.begin(identity)

        #expect(throws: LiveSessionError.staleGeneration) {
            try session.accept(.started(threadID: "thread-1"), generation: 6)
        }
        #expect(throws: LiveSessionError.wrongThread) {
            try session.accept(.started(threadID: "thread-other"), generation: 7)
        }

        try session.accept(.started(threadID: "thread-1"), generation: 7)
        _ = try session.requestStop(generation: 7)
        #expect(throws: LiveSessionError.eventAfterStop) {
            try session.accept(
                .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "late"),
                generation: 7
            )
        }
    }

    @Test
    func boundsTranscriptAudioAndEventCounts() throws {
        var session = LiveSessionContract(limits: .init(
            maximumTranscriptBytes: 4,
            maximumAudioBytes: 4,
            maximumCumulativeTranscriptBytes: 6,
            maximumCumulativeAudioBytes: 6,
            maximumEvents: 2
        ))
        try session.begin(identity)
        try session.accept(.started(threadID: "thread-1"), generation: 7)

        #expect(throws: LiveSessionError.payloadTooLarge) {
            try session.accept(
                .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "12345"),
                generation: 7
            )
        }
        #expect(throws: LiveSessionError.payloadTooLarge) {
            try session.accept(
                .outputAudio(threadID: "thread-1", audio: try frame(Data(repeating: 1, count: 5))),
                generation: 7
            )
        }
        try session.accept(
            .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "ok"),
            generation: 7
        )
        #expect(throws: LiveSessionError.eventLimitExceeded) {
            try session.accept(
                .transcriptDone(threadID: "thread-1", role: "assistant", text: "ok"),
                generation: 7
            )
        }
    }

    @Test
    func cumulativeBudgetsRejectWithoutConsumingBytesOrEvents() throws {
        var session = LiveSessionContract(limits: .init(
            maximumTranscriptBytes: 4,
            maximumAudioBytes: 4,
            maximumCumulativeTranscriptBytes: 4,
            maximumCumulativeAudioBytes: 4,
            maximumEvents: 5
        ))
        try session.begin(identity)
        try session.accept(.started(threadID: "thread-1"), generation: 7)
        try session.accept(
            .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "123"),
            generation: 7
        )
        #expect(throws: LiveSessionError.cumulativePayloadTooLarge) {
            try session.accept(
                .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "12"),
                generation: 7
            )
        }
        try session.accept(
            .transcriptDelta(threadID: "thread-1", role: "assistant", delta: "4"),
            generation: 7
        )
        try session.accept(
            .outputAudio(threadID: "thread-1", audio: try frame(Data([1, 2, 3]))),
            generation: 7
        )
        #expect(throws: LiveSessionError.cumulativePayloadTooLarge) {
            try session.accept(
                .outputAudio(threadID: "thread-1", audio: try frame(Data([4, 5]))),
                generation: 7
            )
        }
        try session.accept(
            .outputAudio(threadID: "thread-1", audio: try frame(Data([4]))),
            generation: 7
        )
    }

    private func frame(_ data: Data) throws -> LiveAudioFrame {
        try LiveAudioFrame(
            data: data,
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: nil,
            itemID: nil,
            requirePCM16Alignment: false
        )
    }

    @Test
    func rejectedSequenceDoesNotConsumeEventOrCumulativeQuota() throws {
        let identity = LiveSessionIdentity(requestID: "request", threadID: "thread", generation: 1)
        var contract = LiveSessionContract(limits: .init(
            maximumTranscriptBytes: 4,
            maximumAudioBytes: 4,
            maximumCumulativeTranscriptBytes: 4,
            maximumCumulativeAudioBytes: 4,
            maximumEvents: 2
        ))
        try contract.begin(identity)
        #expect(throws: LiveSessionError.invalidSequence) {
            try contract.accept(.transcriptDelta(threadID: "thread", role: "assistant", delta: "xxxx"), generation: 1)
        }
        try contract.accept(.started(threadID: "thread"), generation: 1)
        #expect(throws: LiveSessionError.invalidSequence) {
            try contract.accept(.started(threadID: "thread"), generation: 1)
        }
        try contract.accept(.transcriptDone(threadID: "thread", role: "assistant", text: "xxxx"), generation: 1)
    }

    @Test
    func terminalReasonParticipatesInRetainedStringBudgets() throws {
        var contract = LiveSessionContract(limits: .init(
            maximumTranscriptBytes: 4,
            maximumAudioBytes: 4,
            maximumCumulativeTranscriptBytes: 3,
            maximumCumulativeAudioBytes: 4,
            maximumEvents: 3
        ))
        try contract.begin(identity)
        try contract.accept(.started(threadID: "thread-1"), generation: 7)
        #expect(throws: LiveSessionError.payloadTooLarge) {
            try contract.accept(.closed(threadID: "thread-1", reason: "12345"), generation: 7)
        }
        #expect(throws: LiveSessionError.cumulativePayloadTooLarge) {
            try contract.accept(.closed(threadID: "thread-1", reason: "1234"), generation: 7)
        }
        try contract.accept(.closed(threadID: "thread-1", reason: "123"), generation: 7)
    }

    @Test
    func threadAndRoleStringsParticipateInCumulativeRetainedBudget() throws {
        let shortIdentity = LiveSessionIdentity(requestID: "r", threadID: "t", generation: 1)
        var contract = LiveSessionContract(limits: .init(
            maximumTranscriptBytes: 4,
            maximumAudioBytes: 4,
            maximumCumulativeTranscriptBytes: 4,
            maximumCumulativeAudioBytes: 4,
            maximumCumulativeRetainedStringBytes: 12,
            maximumEvents: 4
        ))
        try contract.begin(shortIdentity)
        try contract.accept(.started(threadID: "t"), generation: 1)
        try contract.accept(
            .transcriptDelta(threadID: "t", role: "user", delta: "x"), generation: 1
        )
        #expect(throws: LiveSessionError.cumulativePayloadTooLarge) {
            try contract.accept(
                .transcriptDelta(threadID: "t", role: "user", delta: "x"), generation: 1
            )
        }
    }
}
