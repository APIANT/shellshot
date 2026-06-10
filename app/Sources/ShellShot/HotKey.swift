import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey — no Accessibility permission needed.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1

    @discardableResult
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if !Self.handlerInstalled {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hkId = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkId
                )
                HotKey.callbacks[hkId.id]?()
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = true
        }
        let id = Self.nextId
        Self.nextId += 1
        let hkId = EventHotKeyID(signature: OSType(0x53534854), id: id) // 'SSHT'
        guard RegisterEventHotKey(keyCode, modifiers, hkId, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
        Self.callbacks[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
