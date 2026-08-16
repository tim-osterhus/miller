import AppKit
import Foundation

@MainActor
final class SystemReducedMotionSource {
    private let read: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private let notificationName: Notification.Name
    private var observer: NSObjectProtocol?

    private(set) var value: Bool
    var onChange: ((Bool) -> Void)?

    convenience init() {
        self.init(
            read: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            notificationCenter: NSWorkspace.shared.notificationCenter,
            notificationName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
    }

    init(
        read: @escaping @MainActor () -> Bool,
        notificationCenter: NotificationCenter,
        notificationName: Notification.Name
    ) {
        self.read = read
        self.notificationCenter = notificationCenter
        self.notificationName = notificationName
        value = read()
    }

    func start() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        let next = read()
        guard next != value else { return }
        value = next
        onChange?(next)
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }
}
