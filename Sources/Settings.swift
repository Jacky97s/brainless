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
    /// 要一起按住的修飾鍵；空的代表是一般按鍵（看 keyCode）
    var modifierKeys: [Int64] {
        switch self {
        case .rightOption: return [61]
        case .rightCommand: return [54]
        case .rightControl: return [62]
        case .fn: return [63]
        case .f18, .f19: return []
        case .custom: return Settings.shared.customModifierKeys.map(Int64.init)
        }
    }
    var isModifier: Bool { !modifierKeys.isEmpty }

    static func name(forKeys keys: [Int64]) -> String {
        keys.map { name(forKeyCode: $0) }.joined(separator: "＋")
    }

    static func name(forKeyCode kc: Int64) -> String {
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
    case auto, zh, yue, en, ja
    var title: String {
        switch self {
        case .auto: return "自動偵測"
        case .zh: return "中文"
        case .yue: return "粵語（口語字）"
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
    /// 自訂的修飾鍵組合（keyCode，例如左 Shift＋左 Option 是 [56, 58]）
    var customModifierKeys: [Int] {
        get {
            if let keys = d.array(forKey: "customModifierKeys") as? [Int] { return keys }
            // 舊版只存單一修飾鍵：customMask 不為 0 時 customKeyCode 就是那顆修飾鍵
            return d.integer(forKey: "customMask") != 0 ? [customKeyCode] : []
        }
        set { d.set(newValue, forKey: "customModifierKeys") }
    }
    var customLabel: String {
        get { d.string(forKey: "customLabel") ?? "尚未設定" }
        set { d.set(newValue, forKey: "customLabel") }
    }
    /// 潤稿模型常駐記憶體（不常駐的話閒置 30 分鐘會被卸載，下次要等十幾秒重新載入）
    var keepModelLoaded: Bool {
        get { bool("keepModelLoaded", default: true) }
        set { d.set(newValue, forKey: "keepModelLoaded") }
    }
    /// 自動偵測時允許的語言（Whisper 回傳的英文名稱）；偵測到名單外的語言就用主要語言重辨一次
    var allowedLanguages: [String] {
        get { d.stringArray(forKey: "allowedLanguages") ?? ["chinese", "english"] }
        set { d.set(newValue, forKey: "allowedLanguages") }
    }
    static let languageChoices: [(name: String, code: String, title: String)] = [
        ("chinese", "zh", "中文"), ("cantonese", "yue", "粵語"), ("english", "en", "英文"),
        ("malay", "ms", "馬來語"), ("japanese", "ja", "日文"), ("korean", "ko", "韓文"),
    ]
    var primaryLanguageCode: String {
        if allowedLanguages.contains("chinese") { return "zh" }
        return Settings.languageChoices.first { allowedLanguages.contains($0.name) }?.code ?? "zh"
    }
    /// 快速辨識：依句子長度縮小 Whisper 的運算視窗（最小 512，約 10 秒），短句快一倍
    var fastWhisper: Bool {
        get { bool("fastWhisper", default: false) }
        set { d.set(newValue, forKey: "fastWhisper") }
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
    /// 潤稿後端（RefineBackend.rawValue）；空字串代表自動，用偵測到的第一個
    var refineBackend: String {
        get { d.string(forKey: "refineBackend") ?? "" }
        set { d.set(newValue, forKey: "refineBackend") }
    }
    var claudeModel: String {
        get { d.string(forKey: "claudeModel") ?? "haiku" }
        set { d.set(newValue, forKey: "claudeModel") }
    }
    /// 空字串代表用 codex 自己設定檔裡的模型
    var codexModel: String {
        get { d.string(forKey: "codexModel") ?? "" }
        set { d.set(newValue, forKey: "codexModel") }
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
