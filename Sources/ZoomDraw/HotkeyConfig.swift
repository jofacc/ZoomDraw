import AppKit
import Carbon.HIToolbox

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt   // NSEvent.ModifierFlags.rawValue（device-independent 部分）

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var displayString: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += HotkeyBinding.keyName(for: keyCode)
        return s
    }

    static func keyName(for code: UInt32) -> String {
        // 常用按键映射；其他键直接显示 Key#x
        let map: [UInt32: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T",
            31:"O", 32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 40:"K",
            45:"N", 46:"M",
            18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 25:"9", 26:"7", 28:"8", 29:"0",
            36:"↩", 48:"⇥", 49:"Space", 51:"⌫", 53:"ESC",
            123:"←", 124:"→", 125:"↓", 126:"↑",
            122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12"
        ]
        return map[code] ?? "Key#\(code)"
    }
}

enum HotkeyAction: String, CaseIterable {
    case zoom = "hotkey.zoom"
    case draw = "hotkey.draw"

    var title: String {
        switch self {
        case .zoom: return "放大模式"
        case .draw: return "画笔标注"
        }
    }

    var defaultBinding: HotkeyBinding {
        switch self {
        case .zoom: // Option+A
            return HotkeyBinding(keyCode: 0, modifiers: NSEvent.ModifierFlags.option.rawValue)
        case .draw: // Option+D
            return HotkeyBinding(keyCode: 2, modifiers: NSEvent.ModifierFlags.option.rawValue)
        }
    }
}

final class HotkeyConfig {
    static let shared = HotkeyConfig()
    private let defaults = UserDefaults.standard

    func binding(for action: HotkeyAction) -> HotkeyBinding {
        if let data = defaults.data(forKey: action.rawValue),
           let b = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            return b
        }
        return action.defaultBinding
    }

    func setBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        if let data = try? JSONEncoder().encode(binding) {
            defaults.set(data, forKey: action.rawValue)
            NotificationCenter.default.post(name: .hotkeysChanged, object: nil)
        }
    }

    func resetAll() {
        for a in HotkeyAction.allCases {
            defaults.removeObject(forKey: a.rawValue)
        }
        NotificationCenter.default.post(name: .hotkeysChanged, object: nil)
    }
}

extension Notification.Name {
    static let hotkeysChanged = Notification.Name("ZoomDraw.hotkeysChanged")
}
