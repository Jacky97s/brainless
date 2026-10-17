import Foundation

/// 語音辨識跑在哪裡
enum SpeechEngine: String, CaseIterable { case local, remote }

/// 解析過、可以用的 OpenAI 相容端點。只有 Settings 會從字串建出來；nil 代表還沒設定。
struct RemoteWhisperConfig: Equatable {
    let baseURL: URL   // 例如 https://api.groq.com/openai/v1，結尾沒有斜線
    let model: String  // 例如 whisper-large-v3
}

struct Transcript {
    let text: String
    let language: String?
}

/// 本機與遠端共用的 multipart 組裝與回應解析
enum WhisperHTTP {
    static func multipart(wav: Data, fields: [(String, String)], boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// source 是錯誤訊息裡的主詞（「whisper-server」「遠端辨識」）
    static func parse(data: Data?, response: URLResponse?, error: Error?, source: String) -> Swift.Result<Transcript, Error> {
        if let error = error { return .failure(error) }
        guard let data = data else {
            return .failure(NSError(domain: "Whispry", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(source) 沒有回應"]))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            return .failure(NSError(domain: "Whispry", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "\(source) 回傳 \(http.statusCode)：\(msg.prefix(200))"]))
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String {
            return .success(Transcript(text: text, language: (obj["language"] as? String)?.lowercased()))
        }
        return .success(Transcript(text: String(data: data, encoding: .utf8) ?? "", language: nil))
    }
}

/// AppController 面對的辨識引擎：本機 whisper-server，或遠端 OpenAI 相容端點
final class Transcriber {
    enum State: Equatable {
        case stopped, starting, ready
        case failed(String)
    }

    private let settings = Settings.shared
    private let local = WhisperServer()
    private var remoteState: State = .stopped {
        didSet { let s = remoteState; DispatchQueue.main.async { self.onStateChange?(s) } }
    }
    private var probeGeneration = 0
    var onStateChange: ((State) -> Void)?

    init() {
        local.onStateChange = { [weak self] s in
            guard let self = self, self.engine == .local else { return }
            self.onStateChange?(Self.map(s))
        }
    }

    var engine: SpeechEngine { settings.speechEngine }
    var state: State { engine == .local ? Self.map(local.state) : remoteState }
    var isReady: Bool { state == .ready }

    var label: String {
        switch engine {
        case .local: return "本機 whisper.cpp large-v3"
        case .remote:
            guard let c = settings.remoteWhisper else { return "遠端（未設定）" }
            return "遠端 \(c.model)（\(c.baseURL.host ?? "?")）"
        }
    }

    private static func map(_ s: WhisperServer.State) -> State {
        switch s {
        case .stopped: return .stopped
        case .starting: return .starting
        case .ready: return .ready
        case .failed(let m): return .failed(m)
        }
    }

    func start() {
        switch engine {
        case .local:
            local.start()
        case .remote:
            local.stop()
            probe(silent: false)
        }
    }

    func stop() {
        probeGeneration += 1
        local.stop()
        setRemote(.stopped)
    }

    func checkHealth() {
        switch engine {
        case .local: local.checkHealth()
        case .remote: if state != .starting { probe(silent: true) }
        }
    }

    private func setRemote(_ s: State) { if remoteState != s { remoteState = s } }

    /// 沒有 /models 的 whisper.cpp 也會回應（404），所以只要有 HTTP 回應、且不是 401／403 就算連得上
    private func probe(silent: Bool) {
        guard let cfg = settings.remoteWhisper else { setRemote(.failed("還沒設定遠端端點")); return }
        if !silent { setRemote(.starting) }
        probeGeneration += 1
        let gen = probeGeneration
        var req = URLRequest(url: cfg.baseURL.appendingPathComponent("models"))
        req.timeoutInterval = 5
        applyKey(&req)
        let host = cfg.baseURL.host ?? "?"
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                guard let self = self, gen == self.probeGeneration else { return }
                if let http = resp as? HTTPURLResponse {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        self.setRemote(.failed("API key 被拒絕（\(http.statusCode)）"))
                    } else {
                        self.setRemote(.ready)
                    }
                } else {
                    self.setRemote(.failed("連不上 \(host)：\(err?.localizedDescription ?? "沒有回應")"))
                }
            }
        }.resume()
    }

    private func applyKey(_ req: inout URLRequest) {
        if let key = settings.remoteKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    /// 回傳的 closure 取消這次請求
    @discardableResult
    func transcribe(wav: URL, language: String, prompt: String?, audioContext: Int? = nil, completion: @escaping (Swift.Result<Transcript, Error>) -> Void) -> () -> Void {
        guard let data = try? Data(contentsOf: wav) else {
            completion(.failure(NSError(domain: "Whispry", code: 2, userInfo: [NSLocalizedDescriptionKey: "讀不到錄音檔"])))
            return {}
        }
        let boundary = "----Whispry\(UUID().uuidString)"
        var fields: [(String, String)]
        var req: URLRequest
        let source: String
        let tag: String
        switch engine {
        case .local:
            fields = [
                ("response_format", "verbose_json"),
                ("temperature", "0.0"),
                ("temperature_inc", "0.0"),   // 關掉溫度回退：失敗時不要一再重解碼，極短或模糊的音檔曾因此跑 30 秒
                ("no_speech_thold", "0.6"),
                ("language", language),
                ("no_timestamps", "true"),
            ]
            if let ctx = audioContext, ctx < 1500 { fields.append(("audio_ctx", "\(ctx)")) }
            req = URLRequest(url: local.baseURL.appendingPathComponent("inference"))
            req.timeoutInterval = 180
            source = "whisper-server"
            tag = "whisper"
        case .remote:
            guard let cfg = settings.remoteWhisper else {
                completion(.failure(NSError(domain: "Whispry", code: 4, userInfo: [NSLocalizedDescriptionKey: "還沒設定遠端端點"])))
                return {}
            }
            fields = [("model", cfg.model), ("response_format", "verbose_json"), ("temperature", "0")]
            if language != "auto" { fields.append(("language", language)) }
            req = URLRequest(url: cfg.baseURL.appendingPathComponent("audio/transcriptions"))
            req.timeoutInterval = 60
            applyKey(&req)
            source = "遠端辨識"
            tag = "remote whisper"
        }
        if let p = prompt, !p.isEmpty { fields.append(("prompt", p)) }
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = WhisperHTTP.multipart(wav: data, fields: fields, boundary: boundary)
        let t0 = Date()
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            let result = WhisperHTTP.parse(data: data, response: resp, error: err, source: source)
            if case .success(let t) = result, let lang = t.language {
                Log.w("\(tag) ok in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(t.text.count) chars, lang=\(lang)")
            }
            completion(result)
        }
        task.resume()
        return { task.cancel() }
    }
}
