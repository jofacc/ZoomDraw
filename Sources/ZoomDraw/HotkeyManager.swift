import AppKit
import Carbon.HIToolbox

/// 使用 Carbon 注册全局快捷键（无需 Accessibility 权限），支持动态重新注册
final class HotkeyManager {
    private struct Registration {
        let id: UInt32
        let ref: EventHotKeyRef?
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    /// 返回 id，用于 unregister
    @discardableResult
    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        var hotkeyRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5A4D4452 /* "ZMDR" */), id: nextID)
        let carbonMods = carbonModifiers(from: modifiers)

        let status = RegisterEventHotKey(keyCode, carbonMods, hkID, GetApplicationEventTarget(), 0, &hotkeyRef)
        if status != noErr {
            NSLog("[ZoomDraw] RegisterEventHotKey failed: \(status)")
            return nil
        }
        let id = nextID
        registrations[id] = Registration(id: id, ref: hotkeyRef, handler: handler)
        nextID += 1
        return id
    }

    func unregister(id: UInt32) {
        guard let reg = registrations.removeValue(forKey: id), let ref = reg.ref else { return }
        UnregisterEventHotKey(ref)
    }

    func unregisterAll() {
        for (_, reg) in registrations {
            if let ref = reg.ref { UnregisterEventHotKey(ref) }
        }
        registrations.removeAll()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, userData) -> OSStatus in
            guard let userData = userData, let eventRef = eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(eventRef,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            if err == noErr {
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let reg = mgr.registrations[hkID.id] {
                    DispatchQueue.main.async { reg.handler() }
                }
            }
            return noErr
        }, 1, &spec, selfPtr, nil)
    }
}
