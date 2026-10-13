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
            "-bs", "5",
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

    func stop() {
        pollTimer?.invalidate()
        state = .stopped
        process?.terminate()
        process = nil
    }

    func transcribe(wav: URL, language: String, prompt: String?, completion: @escaping (Swift.Result<String, Error>) -> Void) {
        guard let data = try? Data(contentsOf: wav) else {
            completion(.failure(NSError(domain: "Whispry", code: 2, userInfo: [NSLocalizedDescriptionKey: "讀不到錄音檔"])))
            return
        }
        let boundary = "----Whispry\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        field("response_format", "json")
        field("temperature", "0.0")
        field("language", language)
        field("no_timestamps", "true")
        if let p = prompt, !p.isEmpty { field("prompt", p) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 180
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            guard let data = data else {
                completion(.failure(NSError(domain: "Whispry", code: 3, userInfo: [NSLocalizedDescriptionKey: "whisper-server 沒有回應"])))
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let msg = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(NSError(domain: "Whispry", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "whisper-server 回傳 \(http.statusCode)：\(msg.prefix(200))"])))
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String {
                Log.w("whisper ok in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(text.count) chars")
                completion(.success(text))
            } else {
                let s = String(data: data, encoding: .utf8) ?? ""
                completion(.success(s))
            }
        }.resume()
    }
}
