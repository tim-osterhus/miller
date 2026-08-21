import AppKit
import SwiftUI

private final class MillerOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class AvatarPanelRegion: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityIsIgnored() -> Bool { true }

    override func accessibilityChildren() -> [Any]? { [] }

}

@MainActor
private final class OverlayDismissHandler {
    weak var controller: OverlayPanelController?

    func dismiss() {
        controller?.dismissAfterLiveVoiceCleanup()
    }
}

@MainActor
final class OverlayPanelController: NSWindowController, NSWindowDelegate {
    private static let millerContentWidth: CGFloat = 520
    private let model: AppPresentationModel
    private let peerHost: OverlayLiveVoicePeerHost?
    private let avatarIntegration: AvatarIntegrationController?
    private let avatarRegionView: AvatarPanelRegion
    private let millerContentRegionView: NSView
    private let avatarWidthConstraint: NSLayoutConstraint
    private let dismissHandler: OverlayDismissHandler
    private var dismissalInProgress = false
    private(set) var avatarPaneWidth: CGFloat

    var avatarRegion: NSView? { avatarRegionView }
    var millerContentRegion: NSView? { millerContentRegionView }

    init(
        model: AppPresentationModel,
        peerHost: OverlayLiveVoicePeerHost? = nil,
        avatarIntegration: AvatarIntegrationController? = nil,
        avatarPaneWidth: CGFloat = AvatarPaneWidth.defaultValue
    ) {
        self.model = model
        self.peerHost = peerHost
        self.avatarIntegration = avatarIntegration
        let normalizedAvatarPaneWidth = Self.normalizedAvatarPaneWidth(avatarPaneWidth)
        self.avatarPaneWidth = normalizedAvatarPaneWidth
        let dismissHandler = OverlayDismissHandler()
        self.dismissHandler = dismissHandler
        let panel = MillerOverlayPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.millerContentWidth,
                height: 360
            ),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Miller"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        let avatarRegion = AvatarPanelRegion(frame: .zero)
        avatarRegion.translatesAutoresizingMaskIntoConstraints = false
        avatarRegion.isHidden = true
        self.avatarRegionView = avatarRegion
        let contentRegion = NSView(frame: .zero)
        contentRegion.translatesAutoresizingMaskIntoConstraints = false
        self.millerContentRegionView = contentRegion
        root.addSubview(avatarRegion)
        root.addSubview(contentRegion)
        NSLayoutConstraint.activate([
            avatarRegion.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            avatarRegion.topAnchor.constraint(equalTo: root.topAnchor),
            avatarRegion.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentRegion.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentRegion.topAnchor.constraint(equalTo: root.topAnchor),
            contentRegion.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentRegion.widthAnchor.constraint(equalToConstant: Self.millerContentWidth),
        ])
        let avatarWidthConstraint = avatarRegion.widthAnchor.constraint(
            equalToConstant: normalizedAvatarPaneWidth
        )
        avatarWidthConstraint.isActive = true
        self.avatarWidthConstraint = avatarWidthConstraint
        let overlayContent = NSHostingView(
            rootView: OverlayView(
                model: model,
                dismiss: { dismissHandler.dismiss() }
            )
        )
        overlayContent.frame = contentRegion.bounds
        overlayContent.autoresizingMask = [.width, .height]
        contentRegion.addSubview(overlayContent)
        panel.contentView = root
        peerHost?.install(overlayContent: overlayContent, in: contentRegion)
        super.init(window: panel)
        dismissHandler.controller = self
        panel.delegate = self
        avatarIntegration?.onSurfaceAttachmentChange = { [weak self] attached in
            self?.applyAvatarLayout(attached: attached)
        }
        avatarIntegration?.attach(to: avatarRegion)
        applyAvatarLayout(
            attached: avatarIntegration?.isSurfaceAttached == true
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        Task { [weak self] in
            guard let self else { return }
            await self.model.refreshLiveVoiceAvailability()
            guard let window = self.window else { return }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.avatarIntegration?.show()
            self.model.requestInputFocus()
        }
    }

    func toggle() {
        if window?.isVisible == true {
            dismissAfterLiveVoiceCleanup()
        } else {
            show()
        }
    }

    func setAvatarPaneWidth(_ width: CGFloat) {
        let normalized = Self.normalizedAvatarPaneWidth(width)
        guard normalized != avatarPaneWidth else { return }
        avatarPaneWidth = normalized
        avatarWidthConstraint.constant = normalized
        guard avatarIntegration?.isSurfaceAttached == true else { return }
        window?.setContentSize(
            NSSize(width: Self.millerContentWidth + normalized, height: 360)
        )
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func dismissAfterLiveVoiceCleanup() {
        guard !dismissalInProgress else { return }
        model.declineCapabilityApprovalForDismissal()
        guard model.requiresLiveVoiceCleanupBeforeDismissal else {
            avatarIntegration?.hide()
            window?.orderOut(nil)
            return
        }
        dismissalInProgress = true
        Task { [weak self] in
            guard let self else { return }
            await model.endLiveVoice()
            guard self.dismissalInProgress else { return }
            self.avatarIntegration?.hide()
            self.window?.orderOut(nil)
            self.dismissalInProgress = false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        avatarIntegration?.close()
        dismissAfterLiveVoiceCleanup()
        return false
    }

    func windowDidChangeScreen(_ notification: Notification) {
        avatarIntegration?.screenChanged()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        avatarIntegration?.hide()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        avatarIntegration?.show()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        if !window.isVisible {
            avatarIntegration?.hide()
        } else if window.occlusionState.contains(.visible) {
            avatarIntegration?.show()
        } else {
            avatarIntegration?.occlude()
        }
    }

    private func applyAvatarLayout(attached: Bool) {
        avatarRegionView.isHidden = !attached
        window?.setContentSize(
            NSSize(
                width: attached
                    ? Self.millerContentWidth + avatarPaneWidth
                    : Self.millerContentWidth,
                height: 360
            )
        )
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private static func normalizedAvatarPaneWidth(_ width: CGFloat) -> CGFloat {
        CGFloat(AvatarPaneWidth.normalized(Double(width)))
    }
}
