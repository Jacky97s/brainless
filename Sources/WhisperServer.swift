import Foundation

/// 管理本機的 whisper-server（whisper.cpp）：啟動、等它載入模型、送音檔辨識。
final class WhisperServer {
    enum State: Equatable {
        case stopped, starting, ready
        case failed(String)
    }
    private(set) var state: State = .stopped {
        didSet { let s = state; DispatchQueue.main.async { self.onStateChange?(s) } }
    }
    var onStateChange: ((State) -> Void)?
    var isReady: Bool { state == .ready }

    private var process: Process?
    private let settings = Settings.shared
    private var pollTimer: Timer?
    private var startedAt: Date?

    var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.whisperPort)")! }

    func start() {
        guard ModelSetup.whisperModelPresent else {
            state = .failed("還沒有 Whisper 模型，到主視窗按「下載 Whisper 模型」")
            return
        }
        guard ModelSetup.findWhisperServer() != nil else {
            state = .failed("找不到 whisper-server，請先安裝 whisper.cpp：\(ModelSetup.brewCommand)")
            return
        }
        state = .starting
        checkReady { [weak self] ready in
            guard let self = self else { return }
            if ready {
                Log.w("WhisperServer: reusing already-running server on port \(self.settings.whisperPort)")
                self.state = .ready
            } else {
                DispatchQueue.main.async { self.launch() }
            }
        }
    }

    private func launch() {
        let publicDir = Settings.supportDir.appendingPathComponent("public", isDirectory: true)
        try? FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ModelSetup.findWhisperServer() ?? settings.whisperServerPath)
        p.arguments = [
            "-m", settings.whisperModelPath,
            "--host", "127.0.0.1",
            "--port", "\(settings.whisperPort)",
            "-t", "6",
            "-nt",
            "--public", publicDir.path,
        ]
        let logURL = Settings.logDir.appendingPathComponent("whisper-server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.state != .stopped {
                    self.state = .failed("whisper-server 意外結束（代碼 \(proc.terminationStatus)），看 ~/Library/Logs/Whispry/whisper-server.log")
                }
                self.process = nil
            }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
            Log.w("WhisperServer: launched pid \(p.processIdentifier)")
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if self.state == .ready { t.invalidate(); return }
                if let s = self.startedAt, Date().timeIntervalSince(s) > 180 {
                    t.invalidate()
                    self.state = .failed("whisper-server 三分鐘內沒有準備好")
                    return
                }
                self.checkReady { ready in
                    if ready { DispatchQueue.main.async { self.state = .ready; t.invalidate() } }
                }
            }
        } catch {
            state = .failed("whisper-server 無法啟動：\(error.localizedDescription)")
        }
    }

    private func checkReady(_ cb: @escaping (Bool) -> Void) {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            cb(resp != nil)
        }.resume()
    }

    /// 定期健檢：顯示就緒但埠沒回應（引擎死了）就重新拉起
    func checkHealth() {
        guard state == .ready else { return }
        checkReady { [weak self] ok in
            guard let self = self, !ok else { return }
            Log.w("WhisperServer: health check failed, restarting")
            DispatchQueue.main.async {
                self.process?.terminate()
                self.process = nil
                self.state = .stopped
                self.start()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        state = .stopped
        process?.terminate()
        process = nil
    }

    /// 依音檔長度算運算視窗：每秒 50、加 5 秒餘裕，最小 512、最大 1500（整段 30 秒）
    static func audioContext(forSeconds s: Double) -> Int {
        min(1500, max(512, Int(s * 50) + 256))
    }
}
