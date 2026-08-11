import AppKit

public enum MillerApp {
    public static let version = 1
}

@main
struct MillerApplication {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.mainMenu = MillerApplicationMenu.makeMainMenu()
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
