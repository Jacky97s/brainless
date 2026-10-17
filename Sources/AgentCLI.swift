import Foundation

/// 一個可以拿來潤稿的本機 AI agent CLI
struct AgentSpec {
    let backend: RefineBackend
    let binary: String
    /// 相對家目錄的備援路徑（各家安裝程式的預設位置，不一定在 PATH 裡）
    let fallbacks: [String]
    let installURL: URL
    var environment: [String: String] = [:]
    let arguments: (_ system: String, _ model: String) -> [String]
    let stdin: (_ system: String, _ user: String) -> String
}

/// 偵測與呼叫本機 agent CLI。偵測方式比照 `ollama launch`：先找 PATH，再找各家預設安裝位置。
enum AgentCLI {
    static let claude = AgentSpec(
        backend: .claude,
        binary: "claude",
        fallbacks: [".local/bin/claude", ".claude/local/claude"],
        installURL: URL(string: "https://code.claude.com/docs/en/quickstart")!,
        // 跳過自動更新與遙測，每次呼叫快約兩秒
        environment: ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"],
        arguments: { system, model in
            // 不給工具、不讀使用者設定與 MCP、不留 session：只當純文字模型用
            var a = ["-p", "--output-format", "text", "--system-prompt", system, "--tools", "",
                     "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence"]
            if !model.isEmpty { a += ["--model", model] }
            return a
        },
        stdin: { _, user in user }
    )

    static let codex = AgentSpec(
        backend: .codex,
        binary: "codex",
        fallbacks: [".local/bin/codex"],
        installURL: URL(string: "https://github.com/openai/codex")!,
        arguments: { _, model in
            var a = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-rules", "-s", "read-only",
                     "--color", "never", "-c", "model_reasoning_effort=low"]
            if !model.isEmpty { a += ["-m", model] }
            return a + ["-"]
        },
        // codex exec 沒有 system prompt 參數，只能跟內容併成一段
        stdin: { system, user in "<instructions>\n\(system)\n</instructions>\n\n\(user)" }
    )

    static let all = [claude, codex]

    static func spec(for backend: RefineBackend) -> AgentSpec? { all.first { $0.backend == backend } }

    /// 從 Finder 開的 App 拿不到 shell 的 PATH（~/.local/bin、nvm 都不在裡面），跟使用者的 shell 要一次
    static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = shellPath().split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    private static func shellPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__BRAINLESS_PATH__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // -i 才會讀 .zshrc（nvm 多半裝在那裡）；前後加記號，避開 rc 檔印出來的雜訊
        p.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { Log.w("agent: shell PATH lookup failed: \(error.localizedDescription)"); return "" }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            Log.w("agent: shell PATH lookup timed out")
            return ""
        }
        let s = String(data: data, encoding: .utf8) ?? ""
        let parts = s.components(separatedBy: marker)
        return parts.count >= 3 ? parts[1] : ""
    }

    static func find(_ spec: AgentSpec) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = searchPath.split(separator: ":").map { "\($0)/\(spec.binary)" } + spec.fallbacks.map { "\(home)/\($0)" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// 空資料夾當工作目錄，agent 才不會讀到任何專案檔或 CLAUDE.md
    private static var workDir: URL {
        let dir = Settings.supportDir.appendingPathComponent("agent-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 回傳的 closure 會結束 agent 行程；結束後 completion 仍會以失敗呼叫一次
    @discardableResult
    static func run(_ spec: AgentSpec, path: String, system: String, user: String, model: String, timeout: TimeInterval = 90,
                    completion: @escaping (Swift.Result<String, Error>) -> Void) -> () -> Void {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = spec.arguments(system, model)
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["NO_COLOR"] = "1"
        env.merge(spec.environment) { _, new in new }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let name = spec.backend.title
        let lock = NSLock()
        var cancelled = false
        let cancelledError = NSError(domain: "Whispry", code: 22, userInfo: [NSLocalizedDescriptionKey: "\(name) 已取消"])
        let kill = {
            if p.isRunning {
                // agent 常再開子行程，只殺它自己的話子行程會抓著 pipe 不放
                let pkill = Process()
                pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pkill.arguments = ["-TERM", "-P", "\(p.processIdentifier)"]
                try? pkill.run()
                pkill.waitUntilExit()
                p.terminate()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            lock.lock()
            if cancelled { lock.unlock(); completion(.failure(cancelledError)); return }
            do { try p.run() } catch { lock.unlock(); completion(.failure(error)); return }
            lock.unlock()
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: Data(spec.stdin(system, user).utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            var timedOut = false
            let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            var errData = Data()
            let errRead = DispatchGroup()
            errRead.enter()
            DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); errRead.leave() }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            errRead.wait()
            p.waitUntilExit()
            killer.cancel()

            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled {
                Log.w("agent \(spec.binary) cancelled")
                completion(.failure(cancelledError))
                return
            }
            let out = String(data: outData, encoding: .utf8) ?? ""
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
            if timedOut {
                Log.w("agent \(spec.binary) timed out after \(elapsed)s")
                completion(.failure(NSError(domain: "Whispry", code: 20, userInfo: [NSLocalizedDescriptionKey: "\(name) 超過 \(Int(timeout)) 秒沒有回應"])))
                return
            }
            guard p.terminationStatus == 0 else {
                let err = String(data: errData, encoding: .utf8) ?? ""
                let detail = (err.isEmpty ? out : err).split(separator: "\n").last.map(String.init) ?? ""
                Log.w("agent \(spec.binary) exit \(p.terminationStatus) in \(elapsed)s: \(detail.prefix(200))")
                completion(.failure(NSError(domain: "Whispry", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(name) 失敗（代碼 \(p.terminationStatus)）：\(detail.prefix(200))"])))
                return
            }
            Log.w("agent \(spec.binary) ok in \(elapsed)s, \(out.count) chars")
            completion(.success(out))
        }
        return {
            lock.lock()
            cancelled = true
            kill()
            lock.unlock()
        }
    }
}
