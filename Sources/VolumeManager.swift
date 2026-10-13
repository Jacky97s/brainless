import AppKit
import Foundation

/// 模型資料夾：預設在 Application Support；也可以指定一個 APFS 磁碟映像（放外接硬碟），啟動時自動掛載。
enum VolumeManager {
    static var mountPoint: URL { URL(fileURLWithPath: Settings.shared.modelsDir, isDirectory: true) }
    static var imagePath: String { Settings.shared.modelImagePath }
    static var usesImage: Bool { !imagePath.isEmpty }

    static var isMounted: Bool {
        if usesImage {
            return FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(".whispry-volume").path)
        }
        return FileManager.default.fileExists(atPath: mountPoint.path)
    }

    /// 回傳 nil 代表模型資料夾可用，否則是給人看的錯誤訊息
    static func ensureMounted() -> String? {
        if !usesImage {
            try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            return FileManager.default.fileExists(atPath: mountPoint.path) ? nil : "建立模型資料夾失敗：\(mountPoint.path)"
        }
        if isMounted { return nil }
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return "找不到模型磁碟映像，外接硬碟有插嗎？（\(imagePath)）"
        }
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, imagePath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "掛載模型磁碟映像失敗：\(error.localizedDescription)" }
        p.waitUntilExit()
        if isMounted { Log.w("VolumeManager: image mounted at \(mountPoint.path)"); return nil }
        return "掛載模型磁碟映像失敗（hdiutil 代碼 \(p.terminationStatus)）"
    }

    /// Ollama 沒回應就把 Ollama.app 叫起來
    static func ensureOllamaRunning() {
        guard let url = URL(string: Settings.shared.ollamaURL + "/api/version") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            guard resp == nil else { return }
            Log.w("VolumeManager: Ollama not responding, launching Ollama.app")
            let app = URL(fileURLWithPath: "/Applications/Ollama.app")
            guard FileManager.default.fileExists(atPath: app.path) else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }.resume()
    }
}
