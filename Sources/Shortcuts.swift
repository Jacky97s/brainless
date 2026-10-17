import Foundation
import Carbon.HIToolbox

/// 一組快捷鍵：一起按住的修飾鍵（照按下順序），加上可有可無的一顆一般鍵
struct Shortcut: Codable, Hashable {
    var modifiers: [Int64]
    var key: Int64?

    var modifierSet: Set<Int64> { Set(modifiers) }
    var parts: [String] { modifiers.map(KeyNames.name) + (key.map { [KeyNames.name($0)] } ?? []) }
    var label: String { parts.joined(separator: "＋") }

    /// 同一組鍵、不管按下順序
    func sameKeys(as o: Shortcut) -> Bool { modifierSet == o.modifierSet && key == o.key }
}

enum KeyNames {
    private static let fixed: [Int64: String] = [
        58: "左 Option", 61: "右 Option", 55: "左 Command", 54: "右 Command",
        59: "左 Control", 62: "右 Control", 56: "左 Shift", 60: "右 Shift",
        63: "Fn", 57: "Caps Lock", 110: "應用程式鍵", 53: "Esc", 48: "Tab", 49: "Space", 36: "Return", 51: "Delete",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20", 114: "Help",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(_ kc: Int64) -> String {
        if let n = fixed[kc] { return n }
        if let c = character(for: kc) { return c.uppercased() }
        return "鍵 \(kc)"
    }

    /// 依目前鍵盤配置把 keyCode 轉成字（不帶修飾鍵，所以 ⌥＋A 顯示 A 而不是 å）
    private static func character(for kc: Int64) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(kc), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
        }
        guard status == noErr, len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

extension Settings {
    /// 每個模式各自的快捷鍵；還沒存過就從舊版的單一快捷鍵＋模式換算
    var shortcuts: [Mode: [Shortcut]] {
        get {
            if let data = UserDefaults.standard.data(forKey: "shortcuts"),
               let raw = try? JSONDecoder().decode([String: [Shortcut]].self, from: data) {
                return Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, raw[$0.rawValue] ?? []) })
            }
            var m = Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, [Shortcut]()) })
            m[legacyMode] = [legacyShortcut]
            return m
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: "shortcuts")
        }
    }

    /// 給提示文字用：聽寫的第一組，沒有就任何一組
    var primaryShortcutLabel: String {
        let s = shortcuts
        return (s[.dictate]?.first ?? Mode.allCases.compactMap { s[$0]?.first }.first)?.label ?? "（尚未設定快捷鍵）"
    }

    private var legacyShortcut: Shortcut {
        let h = HotkeyChoice(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .rightOption
        let mods = h.modifierKeys
        return mods.isEmpty ? Shortcut(modifiers: [], key: h.keyCode) : Shortcut(modifiers: mods, key: nil)
    }

    private var legacyMode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .dictate }
}
