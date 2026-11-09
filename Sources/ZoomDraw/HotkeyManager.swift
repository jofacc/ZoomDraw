import AppKit
import Carbon.HIToolbox

/// 使用 Carbon 注册全局快捷键（无需 Accessibility 权限），支持动态重新注册、临时暂停
final class HotkeyManager {
    private struct Registration {
        let id: UInt32
        let keyCode: UInt32
        let carbonMods: UInt32
        var ref: EventHotKeyRef?
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    /// 被暂停（已向系统注销、等待恢复）的快捷键
    private var suspended = Set<UInt32>()

    private static let signature = OSType(0x5A4D4452 /* "ZMDR" */)

    /// 返回 id，用于 unregister
    @discardableResult
    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        let carbonMods = carbonModifiers(from: modifiers)
        guard let ref = systemRegister(id: id, keyCode: keyCode, carbonMods: carbonMods) else { return nil }
        registrations[id] = Registration(id: id, keyCode: keyCode, carbonMods: carbonMods, ref: ref, handler: handler)
        nextID += 1
        return id
    }

    func unregister(id: UInt32) {
        suspended.remove(id)
        guard let reg = registrations.removeValue(forKey: id), let ref = reg.ref else { return }
        UnregisterEventHotKey(ref)
    }

    func unregisterAll() {
        for (_, reg) in registrations {
            if let ref = reg.ref { UnregisterEventHotKey(ref) }
        }
        registrations.removeAll()
        suspended.removeAll()
    }

    // MARK: 临时暂停

    /// 暂停除 `keep` 以外的全部快捷键：向系统注销，让按键能送到本应用当前的窗口（例如剪贴板面板里的 ⌘1–9）
    func suspend(except keep: Set<UInt32>) {
        for (id, reg) in registrations where !keep.contains(id) {
            guard let ref = reg.ref else { continue }
            UnregisterEventHotKey(ref)
            registrations[id]?.ref = nil
            suspended.insert(id)
        }
    }

    /// 恢复被暂停的快捷键
    func resume() {
        for id in suspended {
            guard let reg = registrations[id], reg.ref == nil else { continue }
            registrations[id]?.ref = systemRegister(id: id, keyCode: reg.keyCode, carbonMods: reg.carbonMods)
        }
        suspended.removeAll()
    }

    var isSuspended: Bool { !suspended.isEmpty }

    // MARK: 内部

    private func systemRegister(id: UInt32, keyCode: UInt32, carbonMods: UInt32) -> EventHotKeyRef? {
        var hotkeyRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, carbonMods, hkID, GetApplicationEventTarget(), 0, &hotkeyRef)
        if status != noErr {
            NSLog("[ZoomDraw] RegisterEventHotKey failed: \(status)")
            return nil
        }
        return hotkeyRef
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
                if let reg = mgr.registrations[hkID.id], reg.ref != nil {
                    DispatchQueue.main.async { reg.handler() }
                }
            }
            return noErr
        }, 1, &spec, selfPtr, nil)
    }
}
