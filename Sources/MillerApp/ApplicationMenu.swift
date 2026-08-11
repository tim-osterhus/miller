import AppKit

enum MillerApplicationMenu {
    @MainActor
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(command(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        editMenu.addItem(command(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z",
            modifierMask: [.command, .shift]
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(command(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(command(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(command(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(command(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        return mainMenu
    }

    @MainActor
    private static func command(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifierMask
        item.target = nil
        return item
    }
}
