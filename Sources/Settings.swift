import Foundation

enum HotkeyChoice: String, CaseIterable {
    case rightOption, rightCommand, rightControl, fn, f18, f19, custom

    var title: String {
        switch self {
        case .rightOption: return "右 Option（⌥，Windows 鍵盤是右邊的 Alt 鍵）"
        case .rightCommand: return "右 Command（⌘，Windows 鍵盤是右邊的 Win 鍵）"
        case .rightControl: return "右 Control（Ctrl）"
        case .fn: return "Fn／🌐 鍵"
        case .f18: return "F18"
        case .f19: return "F19"
        case .custom: return "自訂：\(Settings.shared.customLabel)"
        }
    }
    var shortLabel: String {
        switch self {
        case .rightOption: return "右 ⌥"
        case .rightCommand: return "右 ⌘"
        case .rightControl: return "右 Ctrl"
        case .fn: return "Fn"
        case .f18: return "F18"
        case .f19: return "F19"
        case .custom: return Settings.shared.customLabel
        }
    }
    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        case .f18: return 79
        case .f19: return 80
        case .custom: return Int64(Settings.shared.customKeyCode)
        }
    }
    var isModifier: Bool {
        switch self {
        case .rightOption, .rightCommand, .rightControl, .fn: return true
        case .f18, .f19: return false
        case .custom: return Settings.shared.customMask != 0
        }
    }
    /// 修飾鍵對應的旗標；一般按鍵是 0
    var flagMask: UInt64 {
        switch self {
        case .rightOption: return 0x80000
        case .rightCommand: return 0x100000
        case .rightControl: return 0x40000
        case .fn: return 0x800000
        case .f18, .f19: return 0
        case .custom: return Settings.shared.customMask
        }
    }

    static func name(forKeyCode kc: Int64, mask: UInt64) -> String {
        let names: [Int64: String] = [
            58: "左 Option", 61: "右 Option", 55: "左 Command", 54: "右 Command",
            59: "左 Control", 62: "右 Control", 56: "左 Shift", 60: "右 Shift",
            63: "Fn", 57: "Caps Lock", 110: "應用程式鍵", 53: "Esc", 48: "Tab", 49: "空白鍵",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20", 114: "Insert／Help",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 117: "Delete",
        ]
        if let n = names[kc] { return n }
        return "鍵 \(kc)"
    }
}

enum MicKeepAlive: String, CaseIterable {
    case always, tenMinutes, off
    var title: String {
        switch self {
        case .always: return "一直開著"
        case .tenMinutes: return "用完後再撐 10 分鐘"
        case .off: return "用完就關"
        }
    }
    var shortTitle: String {
        switch self {
        case .always: return "一直開"
        case .tenMinutes: return "10 分鐘"
        case .off: return "用完就關"
        }
    }
}

enum Mode: String, CaseIterable {
    case dictate, translate, ask
    var title: String {
        switch self {
        case .dictate: return "聽寫：說話變文字"
        case .translate: return "翻譯：說母語，寫外語"
        case .ask: return "問任何事：對選取的文字下指令"
        }
    }
    var shortTitle: String {
        switch self {
        case .dictate: return "聽寫"
        case .translate: return "翻譯"
        case .ask: return "問任何事"
        }
    }
}

enum SpeechLanguage: String, CaseIterable {
    case auto, zh, en, ja
    var title: String {
        switch self {
        case .auto: return "自動偵測"
        case .zh: return "中文"
        case .en: return "英文"
        case .ja: return "日文"
        }
    }
    var whisperCode: String { rawValue }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    var hotkey: HotkeyChoice {
        get { HotkeyChoice(rawValue: d.string(forKey: "hotkey") ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    var customKeyCode: Int {
        get { d.integer(forKey: "customKeyCode") }
        set { d.set(newValue, forKey: "customKeyCode") }
    }
    var customMask: UInt64 {
        get { UInt64(d.integer(forKey: "customMask")) }
        set { d.set(Int(newValue), forKey: "customMask") }
    }
    var customLabel: String {
        get { d.string(forKey: "customLabel") ?? "尚未設定" }
        set { d.set(newValue, forKey: "customLabel") }
    }
    var micKeepAlive: MicKeepAlive {
        get { MicKeepAlive(rawValue: d.string(forKey: "micKeepAlive") ?? "") ?? .always }
        set { d.set(newValue.rawValue, forKey: "micKeepAlive") }
    }
    var mode: Mode {
        get { Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .dictate }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }
    var language: SpeechLanguage {
        get { SpeechLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "language") }
    }
    var refine: Bool {
        get { bool("refine", default: true) }
        set { d.set(newValue, forKey: "refine") }
    }
    var sounds: Bool {
        get { bool("sounds", default: true) }
        set { d.set(newValue, forKey: "sounds") }
    }
    var translateTarget: String {
        get { d.string(forKey: "translateTarget") ?? "英文" }
        set { d.set(newValue, forKey: "translateTarget") }
    }
    static let translateTargets = ["英文", "日文", "韓文", "繁體中文"]

    var ollamaURL: String {
        get { d.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434" }
        set { d.set(newValue, forKey: "ollamaURL") }
    }
    var ollamaModel: String {
        get { d.string(forKey: "ollamaModel") ?? "qwen3.5:9b" }
        set { d.set(newValue, forKey: "ollamaModel") }
    }
    var whisperServerPath: String {
        get { d.string(forKey: "whisperServerPath") ?? "" }
        set { d.set(newValue, forKey: "whisperServerPath") }
    }
    /// 模型資料夾（預設在 Application Support）
    var modelsDir: String {
        get { d.string(forKey: "modelsDir") ?? Settings.supportDir.appendingPathComponent("models", isDirectory: true).path }
        set { d.set(newValue, forKey: "modelsDir") }
    }
    /// 可選：放在外接硬碟上的 APFS 磁碟映像，會掛到 modelsDir
    var modelImagePath: String {
        get { d.string(forKey: "modelImagePath") ?? "" }
        set { d.set(newValue, forKey: "modelImagePath") }
    }
    var whisperModelPath: String {
        get { d.string(forKey: "whisperModelPath") ?? (modelsDir as NSString).appendingPathComponent(ModelSetup.whisperModelFileName) }
        set { d.set(newValue, forKey: "whisperModelPath") }
    }
    var whisperPort: Int {
        get { let p = d.integer(forKey: "whisperPort"); return p == 0 ? 8178 : p }
        set { d.set(newValue, forKey: "whisperPort") }
    }
    /// 單次錄音上限（秒）
    var maxSeconds: Double { 600 }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Whispry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
    static var logDir: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs/Whispry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum Log {
    private static let file: FileHandle? = {
        let url = Settings.logDir.appendingPathComponent("whispry.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func w(_ s: String) {
        let line = "[\(fmt.string(from: Date()))] \(s)\n"
        file?.write(line.data(using: .utf8)!)
    }
}
