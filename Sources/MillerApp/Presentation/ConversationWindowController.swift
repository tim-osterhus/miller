import AppKit
import SwiftUI

@MainActor
final class ConversationWindowController: NSWindowController, NSWindowDelegate {
    private var observer: NSObjectProtocol?
    private let model: AppPresentationModel

    init(model: AppPresentationModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Miller Conversations"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConversationView(model: model))
        super.init(window: window)
        window.delegate = self
        observer = NotificationCenter.default.addObserver(
            forName: .millerOpenConversationWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.show()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.declineCapabilityApprovalForDismissal()
        sender.orderOut(nil)
        return false
    }
}
