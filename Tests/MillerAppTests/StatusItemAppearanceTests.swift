import AppKit
import Testing
@testable import MillerApp

@MainActor
struct StatusItemAppearanceTests {
    @Test
    func configuresCompactTemplateImageWithoutVisibleTitle() {
        let button = NSButton()

        let configured = StatusItemAppearance.configure(button)

        #expect(configured)
        #expect(button.title.isEmpty)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.image?.isTemplate == true)
        #expect(button.image?.size == NSSize(width: 18, height: 18))
        #expect(button.toolTip == "Miller")
        #expect(button.accessibilityLabel() == "Miller status")
    }

    @Test
    func shortcutFailureChangesTooltipWithoutReplacingIcon() throws {
        let button = NSButton()
        #expect(StatusItemAppearance.configure(button))
        let originalImage = try #require(button.image)

        StatusItemAppearance.setShortcutAvailable(false, on: button)

        #expect(button.image === originalImage)
        #expect(button.title.isEmpty)
        #expect(button.toolTip == "Miller — shortcut unavailable")
        #expect(button.accessibilityLabel() == "Miller status, shortcut unavailable")
    }

    @Test
    func fallsBackToVisibleTitleWhenIconIsUnavailable() {
        let button = NSButton()
        button.image = NSImage(size: NSSize(width: 18, height: 18))
        button.title = ""
        button.imagePosition = .imageOnly
        let resourceFreeBundle = Bundle(for: NSButton.self)

        #expect(
            resourceFreeBundle.url(
                forResource: "MillerStatusIcon",
                withExtension: "png"
            ) == nil
        )
        #expect(!StatusItemAppearance.configure(button, bundle: resourceFreeBundle))
        #expect(button.image == nil)
        #expect(button.imagePosition == .noImage)
        #expect(button.title == "Miller")
        #expect(button.toolTip == "Miller")
        #expect(button.accessibilityLabel() == "Miller status")
    }
}
