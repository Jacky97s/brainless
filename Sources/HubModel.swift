import Foundation
import Combine

/// 主視窗用的狀態，由 AppController 餵資料
final class HubModel: ObservableObject {
    enum Page: String, CaseIterable { case home, history, dictionary, settings
        var title: String { switch self { case .home: return "首頁"; case .history: return "歷史紀錄"; case .dictionary: return "詞典"; case .settings: return "設定" } }
        var icon: String { switch self { case .home: return "house"; case .history: return "clock"; case .dictionary: return "book"; case .settings: return "gearshape" } }
    }
    @Published var page: Page = .home
    @Published var shortcuts: [Mode: [Shortcut]] = [:]
    @Published var translateTarget: String = "英文"
    @Published var language: SpeechLanguage = .auto
    @Published var refine: Bool = true
    @Published var sounds: Bool = true
    @Published var loginEnabled: Bool = false
    @Published var whisperOK = false
    @Published var whisperStatus = "未啟動"
    @Published var refinerOK = false
    @Published var refinerStatus = "偵測中…"
    @Published var refinerLabel = ""
    /// 設定值，空字串是自動
    @Published var refineBackend = ""
    @Published var resolvedBackend: RefineBackend = .ollama
    @Published var installedBackends: Set<RefineBackend> = []
    @Published var agentModel = ""
    @Published var ollamaModel = "qwen3.5:9b"
    @Published var whisperModelName = "large-v3"
    @Published var volumeMounted = false
    @Published var appState = "待命中"
    /// AppController.State 的 rawValue，或 "noPermission"
    @Published var phase = "idle"
    /// 正在幫哪個模式學新的快捷鍵
    @Published var learningMode: Mode?
    @Published var micKeepAlive: MicKeepAlive = .always
    @Published var keepModelLoaded = true
    @Published var fastWhisper = false
    @Published var allowedLanguages: [String] = ["chinese", "english"]
    @Published var micStandby = false
    @Published var micName = ""
    @Published var whisperModelPresent = true
    @Published var whisperServerPresent = true
    @Published var ollamaInstalled = true
    @Published var usesImage = false
    let downloader = ModelDownloader()
    let puller = OllamaPuller()
    var privacyLine: String {
        resolvedBackend == .ollama
            ? "辨識與潤稿都在這台電腦上，不上傳任何資料。"
            : "辨識在這台電腦上；潤稿時逐字稿會經由 \(resolvedBackend.title) 送到雲端模型。"
    }
    var setupNeeded: Bool { !(whisperModelPresent && whisperServerPresent && refinerOK) }

    // 由 AppController 設定的動作
    var onAddShortcut: ((Mode) -> Void)?
    var onRemoveShortcut: ((Mode, Shortcut) -> Void)?
    var onSetTarget: ((String) -> Void)?
    var onSetLanguage: ((SpeechLanguage) -> Void)?
    var onSetRefine: ((Bool) -> Void)?
    var onSetSounds: ((Bool) -> Void)?
    var onSetMicKeepAlive: ((MicKeepAlive) -> Void)?
    var onSetKeepModelLoaded: ((Bool) -> Void)?
    var onSetFastWhisper: ((Bool) -> Void)?
    var onToggleAllowedLanguage: ((String) -> Void)?
    var onToggleLogin: (() -> Void)?
    var onRestartEngines: (() -> Void)?
    var onOpenLogs: (() -> Void)?
    var onRetry: ((HistoryItem) -> Void)?
    var onDownloadWhisper: (() -> Void)?
    var onPullModel: (() -> Void)?
    var onSetBackend: ((String) -> Void)?
    var onSetAgentModel: ((String) -> Void)?
}
