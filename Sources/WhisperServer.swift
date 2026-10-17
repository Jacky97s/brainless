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
    private var startGeneration = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.whisperPort)")! }

    func start() {
        guard ModelSetup.whisperModelPresent else {
            state = .failed("還沒有 Whisper \(settings.localWhisperModel.shortName) 模型，到設定頁按「下載」")
            return
        }
        guard ModelSetup.findWhisperServer() != nil else {
            state = .failed("找不到 whisper-server，請先安裝 whisper.cpp：\(ModelSetup.brewCommand)")
            return
        }
        state = .starting
        startGeneration += 1
        let gen = startGeneration
        let port = settings.whisperPort
        let wanted = settings.whisperModelPath
        let modelsDir = settings.modelsDir
        checkReady { [weak self] answering in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let self = self else { return }
                let stale = Self.runningServers().filter {
                    guard let m = Self.ourServerModel(command: $0.command, modelsDir: modelsDir, port: port) else { return false }
                    return m != wanted
                }
                var stopped = true
                for s in stale {
                    let name = Self.ourServerModel(command: s.command, modelsDir: modelsDir, port: port) ?? ""
                    Log.w("WhisperServer: stopping stale whisper-server pid \(s.pid) (model \((name as NSString).lastPathComponent))")
                    if !Self.terminateAndWait(pid: s.pid, port: port) { stopped = false }
                }
                DispatchQueue.main.async {
                    guard gen == self.startGeneration else { return }
                    if !stopped {
                        self.state = .failed("舊的 whisper-server 沒有結束，無法換模型")
                    } else if answering && stale.isEmpty {
                        Log.w("WhisperServer: reusing already-running server on port \(port)")
                        self.state = .ready
                    } else {
                        self.launch()
                    }
                }
            }
        }
    }

    struct RunningServer { let pid: Int32; let command: String }

    /// ps 的 command 欄不加引號，路徑裡的空白（Application Support）分不開，所以不切字，用前綴與旗標比對
    static func ourServerModel(command: String, modelsDir: String, port: Int) -> String? {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard let exe = cmd.split(separator: " ", maxSplits: 1).first,
              (String(exe) as NSString).lastPathComponent == "whisper-server" else { return nil }
        guard let mRange = cmd.range(of: " -m ") else { return nil }
        let rest = cmd[mRange.upperBound...]
        let model = rest.range(of: " -").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        guard model.hasPrefix(modelsDir.hasSuffix("/") ? modelsDir : modelsDir + "/") else { return nil }
        let portArgs = cmd.components(separatedBy: " --port ").dropFirst().compactMap { $0.split(separator: " ").first }
        guard portArgs.count == 1, Int(portArgs[0]) == port else { return nil }
        return model
    }

    static func runningServers() -> [RunningServer] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ww", "-U", "\(getuid())", "-o", "pid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = getpid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let t = line.drop(while: { $0 == " " })
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]), pid != me else { return nil }
            return RunningServer(pid: pid, command: String(t[t.index(after: sp)...]))
        }
    }

    private static func portInUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    /// SIGTERM only; no escalation. Returns once the process is gone and the port is free
    private static func terminateAndWait(pid: Int32, port: Int, timeout: TimeInterval = 15) -> Bool {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 && !portInUse(port) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
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
                guard let self = self, self.process === proc else { return }
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
        startGeneration += 1
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
