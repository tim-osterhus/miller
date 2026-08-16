import Foundation

public enum LiveAudioPeerError: Error, Equatable, Sendable {
    case unavailable
    case invalidState
    case invalidOffer
    case invalidAnswer
    case connectionFailed
}

/// The private WebRTC media plane. SDP remains only between this peer and the
/// App Server client; callers must not present, log, or retain it.
@MainActor
public protocol LiveAudioPeer: Sendable {
    func prepareOffer() async throws -> String
    func applyAnswerAndWaitForConnected(_ answer: String) async throws
    func requestResponse() async throws
    func setMuted(_ muted: Bool) async throws
    func close() async
}

public extension LiveAudioPeer {
    func requestResponse() async throws {
        throw LiveAudioPeerError.unavailable
    }
}

/// Narrow acknowledgement fence used by sessions that can invalidate a
/// response request while the peer is still completing its asynchronous send.
@MainActor
public protocol LiveAudioPeerResponseFencing: LiveAudioPeer {
    func requestResponse(for generation: UInt64) async throws
    func cancelResponseRequest(for generation: UInt64) async
}

/// Optional post-admission failure observation for peers that can report a
/// native connection loss without exposing a general browser message channel.
@MainActor
public protocol LiveAudioPeerConnectionMonitoring: LiveAudioPeer {
    func waitForConnectionFailure() async throws
}

/// Optional bounded observation of the already-owned remote audio element.
/// Implementations expose only playback state, a monotonic offset, and a
/// normalized envelope; they never expose PCM or browser/provider objects.
@MainActor
public protocol LiveAudioOutputMonitoring: LiveAudioPeer {
    func outputSamples() -> AsyncStream<LiveAudioOutputSample>
}
