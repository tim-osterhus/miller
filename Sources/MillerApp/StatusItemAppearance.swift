import AppKit

@MainActor
enum StatusItemAppearance {
    static func configure(_ button: NSButton, bundle: Bundle? = nil) -> Bool {
        let resourceBundle = bundle ?? applicationResourceBundle() ?? .module
        guard
            let imageURL = resourceBundle.url(
                forResource: "MillerStatusIcon",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: imageURL)
        else {
            button.title = "Miller"
            button.imagePosition = .noImage
            button.image = nil
            setShortcutAvailable(true, on: button)
            return false
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        setShortcutAvailable(true, on: button)
        return true
    }

    private static func applicationResourceBundle() -> Bundle? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let resourceURL = Bundle.main.resourceURL
        else {
            return nil
        }
        return Bundle(
            url: resourceURL.appendingPathComponent("Miller_MillerApp.bundle")
        )
    }

    static func setShortcutAvailable(_ available: Bool, on button: NSButton) {
        button.toolTip = available ? "Miller" : "Miller — shortcut unavailable"
        button.setAccessibilityLabel(
            available
                ? AccessibilityLabel.status
                : "\(AccessibilityLabel.status), shortcut unavailable"
        )
    }
}
