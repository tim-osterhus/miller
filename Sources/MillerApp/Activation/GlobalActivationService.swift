import Carbon.HIToolbox
import Foundation

final class GlobalActivationService: @unchecked Sendable {
    var onActivation: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register(_ shortcut: GlobalShortcut) -> Bool {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else {
                    return OSStatus(eventNotHandledErr)
                }
                let service = Unmanaged<GlobalActivationService>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    service.onActivation?()
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            return false
        }

        let identifier = EventHotKeyID(
            signature: OSType(0x4D_4C_4C_52),
            id: 1
        )
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if registrationStatus != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}
