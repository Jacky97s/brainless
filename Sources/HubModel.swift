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
    @Published var holdToTalk = false
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
    @Published var speechEngine: SpeechEngine = .local
    @Published var remoteWhisperURL = ""
    @Published var remoteWhisperModel = "whisper-large-v3"
    /// 解析過的端點主機名，端點還沒設好時是空字串
    @Published var remoteHost = ""
    /// 金鑰本身不進 UI，只告訴畫面有沒有存
    @Published var hasRemoteKey = false
    /// 端點是 http 且不是本機迴路
    @Published var remoteSendsKeyInClear = false
    @Published var transcriberLabel = ""
    var privacyLine: String {
        let host = remoteHost.isEmpty ? "遠端端點" : remoteHost
        switch (speechEngine, resolvedBackend == .ollama) {
        case (.local, true): return "辨識與潤稿都在這台電腦上，不上傳任何資料。"
        case (.local, false): return "辨識在這台電腦上；潤稿時逐字稿會經由 \(resolvedBackend.title) 送到雲端模型。"
        case (.remote, true): return "錄音會送到 \(host) 辨識；潤稿在這台電腦上。"
        case (.remote, false): return "錄音會送到 \(host) 辨識；潤稿時逐字稿會經由 \(resolvedBackend.title) 送到雲端模型。"
        }
    }
    var setupNeeded: Bool {
        switch speechEngine {
        case .local: return !(whisperModelPresent && whisperServerPresent && refinerOK)
        case .remote: return !(whisperOK && refinerOK)
        }
    }

    // 由 AppController 設定的動作
    var onAddShortcut: ((Mode) -> Void)?
    var onRemoveShortcut: ((Mode, Shortcut) -> Void)?
    var onSetTarget: ((String) -> Void)?
    var onSetLanguage: ((SpeechLanguage) -> Void)?
    var onSetRefine: ((Bool) -> Void)?
    var onSetSounds: ((Bool) -> Void)?
    var onSetHoldToTalk: ((Bool) -> Void)?
    var onSetMicKeepAlive: ((MicKeepAlive) -> Void)?
    var onSetKeepModelLoaded: ((Bool) -> Void)?
    var onSetFastWhisper: ((Bool) -> Void)?
    var onSetSpeechEngine: ((SpeechEngine) -> Void)?
    var onSetRemoteWhisper: ((_ url: String, _ model: String) -> Void)?
    var onSetRemoteKey: ((String) -> Void)?
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
