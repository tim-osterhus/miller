import AppKit
import Foundation
import Testing
@testable import MillerApp

@Suite
struct ApplicationMenuTests {
    @Test
    @MainActor
    func editMenuRoutesStandardCommandsThroughTheFirstResponder() throws {
        let mainMenu = MillerApplicationMenu.makeMainMenu()
        let editMenu = try #require(mainMenu.item(withTitle: "Edit")?.submenu)
        let expectedCommands: [(
            title: String,
            action: Selector,
            key: String,
            modifiers: NSEvent.ModifierFlags
        )] = [
            ("Undo", Selector(("undo:")), "z", [.command]),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]

        for expected in expectedCommands {
            let item = try #require(editMenu.item(withTitle: expected.title))
            #expect(item.action == expected.action)
            #expect(item.keyEquivalent == expected.key)
            #expect(item.keyEquivalentModifierMask == expected.modifiers)
            #expect(item.target == nil)
        }
    }

    @Test
    func startupInstallsTheMainMenuBeforeRunningTheApplication() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/MillerApp/MillerApp.swift"),
            encoding: .utf8
        )
        let installation = try #require(source.range(
            of: "application.mainMenu = MillerApplicationMenu.makeMainMenu()"
        ))
        let run = try #require(source.range(of: "application.run()"))

        #expect(installation.lowerBound < run.lowerBound)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
