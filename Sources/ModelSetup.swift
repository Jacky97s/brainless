import Foundation
import Combine

/// 找引擎、下載模型：讓別人第一次打開就能把東西備齊
/// Local Whisper weights the app knows how to fetch and run.
enum LocalWhisperModel: String, CaseIterable {
    case largeV3, largeV3Turbo

    var fileName: String {
        switch self {
        case .largeV3: return "ggml-large-v3.bin"
        case .largeV3Turbo: return "ggml-large-v3-turbo.bin"
        }
    }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
    var title: String {
        switch self {
        case .largeV3: return "large-v3（最準，3.1 GB）"
        case .largeV3Turbo: return "large-v3-turbo（快很多，1.6 GB）"
        }
    }
    var shortName: String {
        switch self {
        case .largeV3: return "large-v3"
        case .largeV3Turbo: return "large-v3-turbo"
        }
    }
    func path(inModelsDir dir: String) -> String { (dir as NSString).appendingPathComponent(fileName) }
}

enum ModelSetup {
    static let brewCommand = "brew install whisper-cpp"
    static let ollamaDownloadURL = URL(string: "https://ollama.com/download")!

    static func findWhisperServer() -> String? {
        let fm = FileManager.default
        var candidates = [Settings.shared.whisperServerPath]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/whisper-server").path { candidates.append(bundled) }
        candidates += ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        return candidates.first { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }
    }

    static func findOllamaBinary() -> String? {
        let fm = FileManager.default
        return ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    static var ollamaInstalled: Bool {
        findOllamaBinary() != nil || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
    }

    static var whisperModelPresent: Bool {
        let p = Settings.shared.whisperModelPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p), let size = attrs[.size] as? NSNumber else { return false }
        return size.int64Value > 1_000_000_000
    }
}

/// 下載 Whisper 模型（1.6～3.1 GB），有進度
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0
    @Published var running = false
    @Published var error: String?
    var onDone: (() -> Void)?
    private var session: URLSession?
    private var destination: URL?

    func start(url: URL, to dest: URL) {
        guard !running else { return }
        destination = dest
        running = true; progress = 0; error = nil
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: url).resume()
        Log.w("model download started: \(url)")
    }

    func cancel() { session?.invalidateAndCancel(); running = false }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async { self.progress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            Log.w("model download finished: \(dest.path)")
            DispatchQueue.main.async { self.running = false; self.progress = 1; self.onDone?() }
        } catch {
            DispatchQueue.main.async { self.running = false; self.error = error.localizedDescription }
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error {
            Log.w("model download failed: \(e.localizedDescription)")
            DispatchQueue.main.async { self.running = false; self.error = e.localizedDescription }
        }
    }
}

/// 用 ollama pull 抓潤稿模型，有進度
final class OllamaPuller: ObservableObject {
    @Published var progress: Double = 0
    @Published var running = false
    @Published var status = ""
    @Published var error: String?
    var onDone: (() -> Void)?
    private var process: Process?

    func start(model: String) {
        guard !running else { return }
        guard let bin = ModelSetup.findOllamaBinary() else { error = "找不到 Ollama，請先安裝"; return }
        running = true; progress = 0; error = nil; status = "連線中…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["pull", model]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            var last: Double? = nil
            if let re = try? NSRegularExpression(pattern: #"(\d{1,3})%"#) {
                for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    if let r = Range(m.range(at: 1), in: s), let n = Double(s[r]) { last = n }
                }
            }
            if let n = last {
                DispatchQueue.main.async { self?.progress = n / 100; self?.status = "下載中 \(Int(n))%" }
            }
            if s.lowercased().contains("error") {
                let line = s.split(separator: "\n").last.map(String.init) ?? s
                DispatchQueue.main.async { self?.status = line.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = false
                if proc.terminationStatus == 0 {
                    self.progress = 1; self.status = "完成"
                    Log.w("ollama pull finished: \(model)")
                    self.onDone?()
                } else {
                    self.error = "ollama pull 失敗（代碼 \(proc.terminationStatus)）"
                }
            }
        }
        do { try p.run(); process = p; Log.w("ollama pull started: \(model)") } catch {
            running = false; self.error = error.localizedDescription
        }
    }

    func cancel() { process?.terminate() }
}
