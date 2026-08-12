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
    func requestResponse() async throws {}
}

/// Optional post-admission failure observation for peers that can report a
/// native connection loss without exposing a general browser message channel.
@MainActor
public protocol LiveAudioPeerConnectionMonitoring: LiveAudioPeer {
    func waitForConnectionFailure() async throws
}
