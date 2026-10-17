import Foundation

/// 語音辨識跑在哪裡
enum SpeechEngine: String, CaseIterable { case local, remote }

/// 解析過、可以用的 OpenAI 相容端點。只有 Settings 會從字串建出來；nil 代表還沒設定。
struct RemoteWhisperConfig: Equatable {
    let baseURL: URL   // 例如 https://api.groq.com/openai/v1，結尾沒有斜線
    let model: String  // 例如 whisper-large-v3

    var sendsKeyInClear: Bool { baseURL.carriesKeyInClear }
}

extension URL {
    /// http 且不是本機迴路：API key 會以明文經過網路
    var carriesKeyInClear: Bool {
        guard scheme?.lowercased() == "http" else { return false }
        return !["127.0.0.1", "::1", "localhost"].contains(host?.lowercased() ?? "")
    }
}

/// 遠端失敗。message 會經由錯誤訊息進記錄檔，所以不放上游回應；回應開頭（已遮掉 API key）放 detail，只給畫面顯示
struct RemoteFailure: LocalizedError {
    let message: String
    var detail: String? = nil
    var errorDescription: String? { message }
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

    private static func transcript(from data: Data) -> Transcript? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String else { return nil }
        return Transcript(text: text, language: (obj["language"] as? String)?.lowercased())
    }

    /// 本機 whisper-server；source 是錯誤訊息裡的主詞
    static func parse(data: Data?, response: URLResponse?, error: Error?, source: String) -> Swift.Result<Transcript, Error> {
        if let error = error { return .failure(error) }
        guard let data = data else {
            return .failure(NSError(domain: "Whispry", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(source) 沒有回應"]))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            return .failure(NSError(domain: "Whispry", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "\(source) 回傳 \(http.statusCode)：\(msg.prefix(200))"]))
        }
        if let t = transcript(from: data) { return .success(t) }
        return .success(Transcript(text: String(data: data, encoding: .utf8) ?? "", language: nil))
    }

    /// 遠端：200 但不是帶 text 的 JSON 也算失敗，不能把錯誤頁當成逐字稿貼出去
    static func parseRemote(data: Data?, response: URLResponse?, error: Error?, key: String?) -> Swift.Result<Transcript, Error> {
        if let error = error { return .failure(error) }
        guard let data = data else { return .failure(RemoteFailure(message: "遠端辨識 沒有回應")) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 先遮再截，key 跨在截斷處也不會露出一段
            let body = redact(String(data: data, encoding: .utf8) ?? "", key: key)
            return .failure(RemoteFailure(message: "遠端辨識 回傳 \(http.statusCode)", detail: body.isEmpty ? nil : String(body.prefix(200))))
        }
        guard let t = transcript(from: data) else { return .failure(RemoteFailure(message: "遠端回應不是辨識結果")) }
        return .success(t)
    }

    static func redact(_ s: String, key: String?) -> String {
        guard let key = key, !key.isEmpty else { return s }
        return s.replacingOccurrences(of: key, with: "***")
    }
}

/// 遠端端點回重新導向時不跟過去，Authorization 才不會被帶到別的主機
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
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
    /// 遠端請求一律走這裡：ephemeral 不把帶 Authorization 的請求寫進磁碟快取，也不跟隨重新導向
    static let remoteSession = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)

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
        case .local: return "本機 whisper.cpp \(settings.localWhisperModel.shortName)"
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

    /// 沒有 /models 的 whisper.cpp 也會回應（404），所以只要有 HTTP 回應、且不是 401／403 或重新導向就算連得上。
    /// 鑰匙圈在這裡第一次讀（背景執行緒，可能跳出存取提示）；明確重啟時，上次讀失敗的會再讀一次
    private func probe(silent: Bool) {
        guard let cfg = settings.remoteWhisper else { setRemote(.failed("還沒設定遠端端點")); return }
        if !silent { setRemote(.starting) }
        probeGeneration += 1
        let gen = probeGeneration
        let host = cfg.baseURL.host ?? "?"
        let settings = self.settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = settings.whisperKey.load(retryFailure: !silent)
            if case .unreadable(let status) = key {
                DispatchQueue.main.async {
                    guard let self = self, gen == self.probeGeneration else { return }
                    self.setRemote(.failed(Self.unreadableKeyMessage(status)))
                }
                return
            }
            var req = URLRequest(url: cfg.baseURL.appendingPathComponent("models"))
            req.timeoutInterval = 5
            Self.authorize(&req, key: key.value)
            Self.remoteSession.dataTask(with: req) { [weak self] _, resp, err in
                DispatchQueue.main.async {
                    guard let self = self, gen == self.probeGeneration else { return }
                    if let http = resp as? HTTPURLResponse {
                        if http.statusCode == 401 || http.statusCode == 403 {
                            let noKey = (key.value ?? "").isEmpty
                            self.setRemote(.failed(noKey ? "\(cfg.baseURL.host ?? "這個端點")需要 API key" : "API key 被拒絕（\(http.statusCode)）"))
                        } else if (300..<400).contains(http.statusCode) {
                            self.setRemote(.failed("端點要求轉址（\(http.statusCode)），為了不把 API key 帶到別處而不跟隨；請填最終的網址"))
                        } else {
                            self.setRemote(.ready)
                        }
                    } else {
                        self.setRemote(.failed("連不上 \(host)：\(err?.localizedDescription ?? "沒有回應")"))
                    }
                }
            }.resume()
        }
    }

    private static func unreadableKeyMessage(_ status: OSStatus) -> String { "讀不到鑰匙圈裡的 API key（\(status)）" }

    static func authorize(_ req: inout URLRequest, key: String?) {
        if let key = key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
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
        let tag: String
        let session: URLSession
        let parse: (Data?, URLResponse?, Error?) -> Swift.Result<Transcript, Error>
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
            tag = "whisper"
            session = URLSession.shared
            parse = { WhisperHTTP.parse(data: $0, response: $1, error: $2, source: "whisper-server") }
        case .remote:
            guard let cfg = settings.remoteWhisper else {
                completion(.failure(NSError(domain: "Whispry", code: 4, userInfo: [NSLocalizedDescriptionKey: "還沒設定遠端端點"])))
                return {}
            }
            let key: String?
            switch settings.whisperKey.cached {
            case .unreadable(let status)?:
                completion(.failure(RemoteFailure(message: Self.unreadableKeyMessage(status))))
                return {}
            case nil:
                completion(.failure(RemoteFailure(message: "遠端辨識還沒準備好")))
                return {}
            case let k?:
                key = k.value
            }
            fields = [("model", cfg.model), ("response_format", "verbose_json"), ("temperature", "0")]
            if language != "auto" { fields.append(("language", language)) }
            req = URLRequest(url: cfg.baseURL.appendingPathComponent("audio/transcriptions"))
            req.timeoutInterval = 60
            Self.authorize(&req, key: key)
            tag = "remote whisper"
            session = Self.remoteSession
            parse = { WhisperHTTP.parseRemote(data: $0, response: $1, error: $2, key: key) }
        }
        if let p = prompt, !p.isEmpty { fields.append(("prompt", p)) }
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = WhisperHTTP.multipart(wav: data, fields: fields, boundary: boundary)
        let t0 = Date()
        let task = session.dataTask(with: req) { data, resp, err in
            let result = parse(data, resp, err)
            if case .success(let t) = result, let lang = t.language {
                Log.w("\(tag) ok in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(t.text.count) chars, lang=\(lang)")
            }
            completion(result)
        }
        task.resume()
        return { task.cancel() }
    }
}
