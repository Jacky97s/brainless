import Foundation

enum RefineBackend: String, CaseIterable {
    case claude, codex, ollama

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .ollama: return "Ollama"
        }
    }
}

/// 潤稿後端：本機 agent CLI（claude -p、codex exec）或 Ollama
final class RefineService {
    enum Status: Equatable { case checking, notInstalled, notRunning, modelMissing, ready }

    private let settings = Settings.shared
    private let ollama = OllamaClient()
    private var agentPaths: [RefineBackend: String] = [:]
    private var ollamaInstalled = false
    private(set) var status: Status = .checking

    /// 設定沒指定就用偵測到的第一個 agent，都沒有才用 Ollama
    var backend: RefineBackend {
        if let b = RefineBackend(rawValue: settings.refineBackend) { return b }
        return AgentCLI.all.map(\.backend).first { agentPaths[$0] != nil } ?? .ollama
    }

    var model: String {
        switch backend {
        case .claude: return settings.claudeModel
        case .codex: return settings.codexModel
        case .ollama: return settings.ollamaModel
        }
    }

    var label: String { model.isEmpty ? backend.title : "\(backend.title)（\(model)）" }
    var isReady: Bool { status == .ready }

    func isInstalled(_ b: RefineBackend) -> Bool { b == .ollama ? ollamaInstalled : agentPaths[b] != nil }

    var statusText: String {
        switch status {
        case .checking: return "偵測中…"
        case .notInstalled: return "找不到 \(backend.title)"
        case .notRunning: return "Ollama 沒有在跑"
        case .modelMissing: return "模型還沒下載完"
        case .ready: return "就緒"
        }
    }

    /// 重新偵測；completion 在 main thread，參數是狀態有沒有變
    func refresh(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var paths: [RefineBackend: String] = [:]
            for spec in AgentCLI.all { if let p = AgentCLI.find(spec) { paths[spec.backend] = p } }
            let ollamaInstalled = ModelSetup.ollamaInstalled
            DispatchQueue.main.async {
                let changed = paths != self.agentPaths || ollamaInstalled != self.ollamaInstalled
                if paths != self.agentPaths { Log.w("agents found: \(paths.map { "\($0.key.rawValue)=\($0.value)" }.sorted())") }
                self.agentPaths = paths
                self.ollamaInstalled = ollamaInstalled
                guard self.backend == .ollama else {
                    completion(self.setStatus(paths[self.backend] != nil ? .ready : .notInstalled) || changed)
                    return
                }
                self.ollama.checkStatus { s in
                    let mapped: Status
                    switch s {
                    case .ready: mapped = .ready
                    case .modelMissing: mapped = .modelMissing
                    case .notRunning: mapped = self.ollamaInstalled ? .notRunning : .notInstalled
                    }
                    completion(self.setStatus(mapped) || changed)
                }
            }
        }
    }

    private func setStatus(_ s: Status) -> Bool {
        defer { status = s }
        return s != status
    }

    /// 只有 Ollama 需要先把模型載進記憶體
    func warmUp() { if backend == .ollama { ollama.warmUp() } }
    func unloadOllama() { ollama.unload() }

    /// completion 不保證在 main thread；回傳的 closure 取消這次呼叫
    @discardableResult
    func chat(system: String, user: String, completion: @escaping (Swift.Result<String, Error>) -> Void) -> () -> Void {
        let done: (Swift.Result<String, Error>) -> Void = { completion($0.map(Self.tidy)) }
        let b = backend
        guard b != .ollama else { return ollama.chat(system: system, user: user, completion: done) }
        guard let spec = AgentCLI.spec(for: b), let path = agentPaths[b] else {
            completion(.failure(NSError(domain: "Whispry", code: 21, userInfo: [NSLocalizedDescriptionKey: "找不到 \(b.title)"])))
            return {}
        }
        return AgentCLI.run(spec, path: path, system: system, user: user, model: model, completion: done)
    }

    /// 去掉模型偶爾多吐的思考段落、外層引號、「整理後：」這類前綴
    static func tidy(_ s: String) -> String {
        var content = s
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
        return content
    }
}
