import Carbon.HIToolbox

/// Global hotkey via Carbon. Still the lowest-latency option and needs no permissions.
final class HotKey {
    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.installHandlerIfNeeded()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B53_4854), id: id) // 'KSHT'
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else { return nil }
        HotKey.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            HotKey.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
