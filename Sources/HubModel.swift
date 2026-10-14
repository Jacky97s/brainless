import Foundation
import Combine

/// 主視窗用的狀態，由 AppController 餵資料
final class HubModel: ObservableObject {
    enum Page: String, CaseIterable { case home, history, dictionary, settings
        var title: String { switch self { case .home: return "首頁"; case .history: return "歷史紀錄"; case .dictionary: return "詞典"; case .settings: return "設定" } }
        var icon: String { switch self { case .home: return "house"; case .history: return "clock"; case .dictionary: return "book"; case .settings: return "gearshape" } }
    }
    @Published var page: Page = .home
    @Published var hotkey: HotkeyChoice = .rightOption
    @Published var mode: Mode = .dictate
    @Published var translateTarget: String = "英文"
    @Published var language: SpeechLanguage = .auto
    @Published var refine: Bool = true
    @Published var sounds: Bool = true
    @Published var loginEnabled: Bool = false
    @Published var whisperOK = false
    @Published var whisperStatus = "未啟動"
    @Published var ollamaOK = false
    @Published var ollamaStatus = "未連線"
    @Published var ollamaModel = "qwen3.5:9b"
    @Published var whisperModelName = "large-v3"
    @Published var volumeMounted = false
    @Published var appState = "待命中"
    @Published var learningHotkey = false
    @Published var micKeepAlive: MicKeepAlive = .always
    @Published var keepModelLoaded = true
    @Published var micStandby = false
    @Published var micName = ""
    @Published var whisperModelPresent = true
    @Published var whisperServerPresent = true
    @Published var ollamaInstalled = true
    @Published var usesImage = false
    let downloader = ModelDownloader()
    let puller = OllamaPuller()
    var setupNeeded: Bool { !(whisperModelPresent && whisperServerPresent && ollamaInstalled && ollamaOK) }

    // 由 AppController 設定的動作
    var onSetHotkey: ((HotkeyChoice) -> Void)?
    var onLearnHotkey: (() -> Void)?
    var onSetMode: ((Mode) -> Void)?
    var onSetTarget: ((String) -> Void)?
    var onSetLanguage: ((SpeechLanguage) -> Void)?
    var onSetRefine: ((Bool) -> Void)?
    var onSetSounds: ((Bool) -> Void)?
    var onSetMicKeepAlive: ((MicKeepAlive) -> Void)?
    var onSetKeepModelLoaded: ((Bool) -> Void)?
    var onToggleLogin: (() -> Void)?
    var onRestartEngines: (() -> Void)?
    var onOpenLogs: (() -> Void)?
    var onRetry: ((HistoryItem) -> Void)?
    var onDownloadWhisper: (() -> Void)?
    var onPullModel: (() -> Void)?
}
