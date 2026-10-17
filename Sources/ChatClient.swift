import Foundation

/// 解析過、可以用的 OpenAI 相容潤稿端點。只有 Settings 會從字串建出來；nil 代表還沒設定。
struct RemoteChatConfig: Equatable {
    let baseURL: URL   // 例如 https://api.groq.com/openai/v1，結尾沒有斜線
    let model: String  // 例如 llama-3.3-70b-versatile
}

/// OpenAI 相容的 /chat/completions。請求走跟遠端辨識同一個 ephemeral、不跟隨轉址的 session
enum OpenAIChat {
    static func request(_ cfg: RemoteChatConfig, key: String?, system: String, user: String) -> URLRequest {
        var req = URLRequest(url: cfg.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Transcriber.authorize(&req, key: key)
        let payload: [String: Any] = [
            "model": cfg.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0,
            "max_tokens": 1024,
            "stream": false,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// 非 200 或沒有 choices[0].message.content 都算失敗。回應內容不進錯誤訊息（會進記錄檔），只放 detail 給畫面，且已遮掉 API key
    static func parse(data: Data?, response: URLResponse?, error: Error?, key: String?) -> Swift.Result<String, Error> {
        if let error = error { return .failure(error) }
        guard let data = data else { return .failure(RemoteFailure(message: "遠端潤稿 沒有回應")) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = WhisperHTTP.redact(String(data: data, encoding: .utf8) ?? "", key: key)
            return .failure(RemoteFailure(message: "遠端潤稿 回傳 \(http.statusCode)", detail: body.isEmpty ? nil : String(body.prefix(200))))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let content = (choice["message"] as? [String: Any])?["content"] as? String else {
            return .failure(RemoteFailure(message: "遠端回應不是潤稿結果"))
        }
        return .success(content)
    }

    /// 回傳的 closure 取消這次請求
    @discardableResult
    static func run(_ cfg: RemoteChatConfig, key: String?, system: String, user: String,
                    completion: @escaping (Swift.Result<String, Error>) -> Void) -> () -> Void {
        let req = request(cfg, key: key, system: system, user: user)
        let t0 = Date()
        let task = Transcriber.remoteSession.dataTask(with: req) { data, resp, err in
            let result = parse(data: data, response: resp, error: err, key: key)
            if case .success(let content) = result {
                Log.w("remote chat ok in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(content.count) chars")
            }
            completion(result)
        }
        task.resume()
        return { task.cancel() }
    }
}
