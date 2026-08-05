import Carbon.HIToolbox
import Foundation

enum GlobalShortcut: String, CaseIterable, Identifiable {
    case commandShiftSpace = "command-shift-space"
    case controlShiftSpace = "control-shift-space"
    case optionShiftSpace = "option-shift-space"

    static let `default`: Self = .commandShiftSpace

    var id: String {
        rawValue
    }

    var keyCode: UInt32 {
        UInt32(kVK_Space)
    }

    var modifiers: UInt32 {
        switch self {
        case .commandShiftSpace:
            UInt32(cmdKey | shiftKey)
        case .controlShiftSpace:
            UInt32(controlKey | shiftKey)
        case .optionShiftSpace:
            UInt32(optionKey | shiftKey)
        }
    }

    var displayName: String {
        switch self {
        case .commandShiftSpace:
            "Command-Shift-Space"
        case .controlShiftSpace:
            "Control-Shift-Space"
        case .optionShiftSpace:
            "Option-Shift-Space"
        }
    }
}

struct GlobalShortcutPreferences {
    static let key = "globalShortcut"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> GlobalShortcut {
        guard
            let rawValue = defaults.string(forKey: Self.key),
            let shortcut = GlobalShortcut(rawValue: rawValue)
        else {
            return .default
        }
        return shortcut
    }

    func save(_ shortcut: GlobalShortcut) {
        defaults.set(shortcut.rawValue, forKey: Self.key)
    }
}
