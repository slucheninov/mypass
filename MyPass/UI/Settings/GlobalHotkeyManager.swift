import Carbon
import AppKit

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]

    private init() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            manager.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(id: UInt32, shortcut: ParsedShortcut, handler: @escaping () -> Void) {
        unregister(id: id)
        handlers[id] = handler
        var hotKeyID = EventHotKeyID(signature: OSType(0x4D595053), id: id) // 'MYPS'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref {
            hotKeyRefs[id] = ref
        }
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    func reload(showMyPassStorage: String, lockMyPassStorage: String, showHandler: @escaping () -> Void, lockHandler: @escaping () -> Void) {
        unregister(id: 1)
        unregister(id: 2)
        if let show = ShortcutCodec.decode(showMyPassStorage) {
            register(id: 1, shortcut: show, handler: showHandler)
        }
        if let lock = ShortcutCodec.decode(lockMyPassStorage) {
            register(id: 2, shortcut: lock, handler: lockHandler)
        }
    }
}
