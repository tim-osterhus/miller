import AppKit
import SwiftUI

private final class MillerOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    private let model: AppPresentationModel
    private let peerHost: OverlayLiveVoicePeerHost?
    private let dismissHandler: OverlayDismissHandler
    private var dismissalInProgress = false

    init(
        model: AppPresentationModel,
        peerHost: OverlayLiveVoicePeerHost? = nil
    ) {
        self.model = model
        self.peerHost = peerHost
        let dismissHandler = OverlayDismissHandler()
        self.dismissHandler = dismissHandler
        let panel = MillerOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
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
        let overlayContent = NSHostingView(
            rootView: OverlayView(
                model: model,
                dismiss: { dismissHandler.dismiss() }
            )
        )
        overlayContent.frame = root.bounds
        overlayContent.autoresizingMask = [.width, .height]
        root.addSubview(overlayContent)
        panel.contentView = root
        peerHost?.install(overlayContent: overlayContent, in: root)
        super.init(window: panel)
        dismissHandler.controller = self
        panel.delegate = self
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

    func dismissAfterLiveVoiceCleanup() {
        guard !dismissalInProgress else { return }
        model.declineCapabilityApprovalForDismissal()
        guard model.requiresLiveVoiceCleanupBeforeDismissal else {
            window?.orderOut(nil)
            return
        }
        dismissalInProgress = true
        Task { [weak self] in
            guard let self else { return }
            await model.endLiveVoice()
            guard self.dismissalInProgress else { return }
            self.window?.orderOut(nil)
            self.dismissalInProgress = false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissAfterLiveVoiceCleanup()
        return false
    }
}
