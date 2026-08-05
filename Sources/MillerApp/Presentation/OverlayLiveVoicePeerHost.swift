import AppKit
import MillerLiveAudio

/// Owns the private WebKit surface used by one live-voice call. The peer is
/// deliberately a child of the existing overlay rather than a second window:
/// WebKit keeps attached visible media capture alive while the SwiftUI overlay
/// remains the only interactive and accessible surface.
@MainActor
final class OverlayLiveVoicePeerHost {
    typealias PeerFactory = @MainActor @Sendable () throws -> WebKitLivePeer

    private let makePeerValue: PeerFactory
    private weak var container: NSView?
    private weak var overlayContent: NSView?
    private var activePeer: WebKitLivePeer?

    init(makePeer: @escaping PeerFactory) {
        makePeerValue = makePeer
    }

    var isPeerAttached: Bool { activePeer?.peerView?.superview != nil }

    func install(overlayContent: NSView, in container: NSView) {
        self.overlayContent = overlayContent
        self.container = container
    }

    func makePeer() throws -> WebKitLivePeer {
        guard activePeer == nil,
              let container,
              let overlayContent,
              overlayContent.superview === container
        else { throw LiveAudioPeerError.unavailable }

        let peer = try makePeerValue()
        guard let peerView = peer.peerView else {
            throw LiveAudioPeerError.unavailable
        }
        peerView.frame = container.bounds
        peerView.autoresizingMask = [.width, .height]
        peerView.alphaValue = 0.01
        peerView.isHidden = false
        peerView.setAccessibilityElement(false)
        container.addSubview(peerView, positioned: .below, relativeTo: overlayContent)
        activePeer = peer
        return peer
    }

    func removePeer() {
        activePeer?.peerView?.removeFromSuperview()
        activePeer = nil
    }
}
