import Foundation

/// 跟本機 Ollama 講話（潤稿模型由設定決定）。
final class OllamaClient {
    enum Status: Equatable {
        case notRunning
        case modelMissing(found: [String])
        case ready
    }
    private let settings = Settings.shared

    private var base: URL { URL(string: settings.ollamaURL)! }
    /// 數字 -1 代表永遠不卸載（要送數字，送字串會被 Ollama 退回 400）
    private var keepAlive: Any { settings.keepModelLoaded ? -1 : "30m" }

    /// 關掉常駐時把模型卸載
    func unload() {
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": settings.ollamaModel, "keep_alive": 0])
        URLSession.shared.dataTask(with: req).resume()
    }

    func checkStatus(_ cb: @escaping (Status) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else {
                DispatchQueue.main.async { cb(.notRunning) }
                return
            }
            let names = models.compactMap { $0["name"] as? String }
            let want = self.settings.ollamaModel
            let has = names.contains { $0 == want || $0 == want + ":latest" || $0.hasPrefix(want) }
            DispatchQueue.main.async { cb(has ? .ready : .modelMissing(found: names)) }
        }.resume()
    }

    /// 先讓模型載進記憶體（第一次從外接硬碟讀 23 GB 會花一陣子）
    func warmUp() {
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["model": settings.ollamaModel, "keep_alive": keepAlive, "options": ["num_ctx": 4096]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 300
        URLSession.shared.dataTask(with: req) { _, _, err in
            Log.w("ollama warmUp done err=\(err?.localizedDescription ?? "none")")
        }.resume()
    }

    func chat(system: String, user: String, completion: @escaping (Swift.Result<String, Error>) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": settings.ollamaModel,
            "stream": false,
            "think": false,
            "keep_alive": keepAlive,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            // 聽寫用不到長上下文；num_ctx 壓在 4096 讓 KV 快取只佔幾百 MB，不然 Ollama 會用 32k 吃掉十幾 GB
            "options": ["temperature": 0.2, "num_predict": 2048, "num_ctx": 4096],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 90
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            guard let data = data else {
                completion(.failure(NSError(domain: "Whispry", code: 10, userInfo: [NSLocalizedDescriptionKey: "Ollama 沒有回應"])))
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let msg = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(NSError(domain: "Whispry", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ollama 回傳 \(http.statusCode)：\(msg.prefix(200))"])))
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  var content = msg["content"] as? String else {
                completion(.failure(NSError(domain: "Whispry", code: 11, userInfo: [NSLocalizedDescriptionKey: "Ollama 回傳格式看不懂"])))
                return
            }
            // 萬一模型還是吐出思考段落，去掉
            if let r = content.range(of: "</think>") { content = String(content[r.upperBound...]) }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            for (l, r) in [("「", "」"), ("\"", "\""), ("“", "”"), ("『", "』")] {
                if content.hasPrefix(l) && content.hasSuffix(r) && content.count > 2 {
                    content = String(content.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            for prefix in ["整理後：", "潤稿：", "譯文：", "結果："] {
                if content.hasPrefix(prefix) { content = String(content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            Log.w("ollama ok in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(content.count) chars")
            completion(.success(content))
        }.resume()
    }
}
