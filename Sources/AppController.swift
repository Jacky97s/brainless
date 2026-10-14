import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

enum TextCleaner {
    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\r", with: "")
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|（[^）]*）"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if let h = t.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) { t = h }
        let hallucinations = ["謝謝觀看", "謝謝收看", "請不吝點讚", "請不吝點贊", "點讚訂閱", "字幕由", "字幕提供", "Amara.org", "明鏡", "訂閱我的頻道"]
        if t.count <= 16, hallucinations.contains(where: { t.contains($0) }) { return "" }
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    enum State { case idle, recording, transcribing, refining, inserting }
    private var state: State = .idle {
        didSet { updateStatusIcon(); rebuildMenu(); syncHub() }
    }

    private let settings = Settings.shared
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let whisper = WhisperServer()
    private let ollama = OllamaClient()
    private let overlay = OverlayPanel()
    private let history = HistoryStore()
    private let dict = DictionaryStore()
    private let hub = HubModel()
    private let hubWindow = HubWindowController()
    private var statusItem: NSStatusItem!
    private var ollamaStatus: OllamaClient.Status = .notRunning
    private var pressStartedRecording = false
    private var recordingStartedAt = Date.distantPast
    private var autoStopTimer: Timer?
    private var lastResult: String?
    private var accessibilityTimer: Timer?
    private var hotkeyRunning = false
    private var warmedUp = false

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.w("\(AppInfo.name) launched, hotkey=\(settings.hotkey.rawValue) mode=\(settings.mode.rawValue)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
        wireHub()

        whisper.onStateChange = { [weak self] s in
            self?.rebuildMenu()
            self?.syncHub()
            if case .failed(let msg) = s { self?.overlay.show(.error(msg)) }
        }
        mountAndStartEngines()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshOllama() }
        Timer.scheduledTimer(withTimeInterval: 1200, repeats: true) { [weak self] _ in
            guard let self = self, self.settings.keepModelLoaded, self.settings.refine, self.ollamaStatus == .ready else { return }
            self.ollama.warmUp()
        }

        recorder.onLevel = { [weak self] l in self?.overlay.level(l) }
        recorder.onCaptureStateChange = { [weak self] in self?.rebuildMenu(); self?.syncHub() }
        hotkey.configure(settings.hotkey)
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] held in self?.handleRelease(held) }
        hotkey.onEscape = { [weak self] in self?.cancelRecording() }

        requestMicrophone()
        ensureAccessibilityAndStartHotkey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.applyMicKeepAlive() }
        if history.items.isEmpty || CommandLine.arguments.contains("--hub") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openHub() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.stopCapturing()
        whisper.stop()
        hotkey.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub()
        return true
    }

    private func mountAndStartEngines() {
        if VolumeManager.usesImage { overlay.show(.info("正在掛載模型磁碟…")) }
        DispatchQueue.global(qos: .userInitiated).async {
            let err = VolumeManager.ensureMounted()
            DispatchQueue.main.async {
                if let err = err {
                    self.overlay.show(.error(err))
                } else {
                    self.whisper.start()
                }
                VolumeManager.ensureOllamaRunning()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refreshOllama() }
                self.rebuildMenu()
                self.syncHub()
            }
        }
    }

    // MARK: - hub window

    private func wireHub() {
        hub.onSetHotkey = { [weak self] h in self?.setHotkey(h) }
        hub.onLearnHotkey = { [weak self] in self?.learnHotkey() }
        hub.onSetMode = { [weak self] m in self?.settings.mode = m; self?.afterSettingsChange() }
        hub.onSetTarget = { [weak self] t in self?.settings.translateTarget = t; self?.afterSettingsChange() }
        hub.onSetLanguage = { [weak self] l in self?.settings.language = l; self?.afterSettingsChange() }
        hub.onSetRefine = { [weak self] v in
            guard let self = self else { return }
            self.settings.refine = v
            if v && self.ollamaStatus == .ready { self.ollama.warmUp() }
            self.afterSettingsChange()
        }
        hub.onSetSounds = { [weak self] v in self?.settings.sounds = v; self?.afterSettingsChange() }
        hub.onSetMicKeepAlive = { [weak self] k in self?.setMicKeepAlive(k) }
        hub.onSetKeepModelLoaded = { [weak self] v in self?.setKeepModelLoaded(v) }
        hub.onToggleLogin = { [weak self] in self?.toggleLogin() }
        hub.onRestartEngines = { [weak self] in self?.restartEngines() }
        hub.onOpenLogs = { [weak self] in self?.openLogs() }
        hub.onRetry = { [weak self] item in self?.retryRefine(item) }
        hub.onDownloadWhisper = { [weak self] in
            guard let self = self else { return }
            self.hub.downloader.start(url: ModelSetup.whisperModelURL, to: URL(fileURLWithPath: self.settings.whisperModelPath))
        }
        hub.downloader.onDone = { [weak self] in
            guard let self = self else { return }
            self.overlay.show(.info("Whisper 模型下載完成，正在啟動引擎"))
            self.whisper.start()
            self.syncHub()
        }
        hub.onPullModel = { [weak self] in
            guard let self = self else { return }
            VolumeManager.ensureOllamaRunning()
            self.hub.puller.start(model: self.settings.ollamaModel)
        }
        hub.puller.onDone = { [weak self] in
            self?.overlay.show(.info("潤稿模型下載完成"))
            self?.refreshOllama()
        }
        syncHub()
    }

    private func afterSettingsChange() { rebuildMenu(); syncHub() }

    private func syncHub() {
        hub.hotkey = settings.hotkey
        hub.mode = settings.mode
        hub.translateTarget = settings.translateTarget
        hub.language = settings.language
        hub.refine = settings.refine
        hub.sounds = settings.sounds
        hub.loginEnabled = SMAppService.mainApp.status == .enabled
        hub.whisperOK = whisper.isReady
        hub.whisperStatus = whisperStatusText()
        hub.ollamaOK = ollamaStatus == .ready
        hub.ollamaStatus = ollamaStatusText()
        hub.ollamaModel = settings.ollamaModel
        hub.whisperModelName = URL(fileURLWithPath: settings.whisperModelPath).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        hub.volumeMounted = VolumeManager.isMounted
        hub.appState = statusLine()
        hub.whisperModelPresent = ModelSetup.whisperModelPresent
        hub.whisperServerPresent = ModelSetup.findWhisperServer() != nil
        hub.ollamaInstalled = ModelSetup.ollamaInstalled
        hub.usesImage = VolumeManager.usesImage
        hub.micKeepAlive = settings.micKeepAlive
        hub.keepModelLoaded = settings.keepModelLoaded
        hub.micStandby = recorder.isCapturing
        hub.micName = AudioRecorder.defaultInputName()
    }

    @objc private func openHub() {
        syncHub()
        hubWindow.show(model: hub, history: history, dict: dict)
    }

    // MARK: - permissions

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in Log.w("mic permission granted=\(ok)") }
        default:
            overlay.show(.error("沒有麥克風權限：系統設定 › 隱私權與安全性 › 麥克風，打開 \(AppInfo.name)"))
        }
    }

    private func ensureAccessibilityAndStartHotkey() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) && hotkey.start() {
            hotkeyRunning = true
            rebuildMenu()
            overlay.show(.info("\(AppInfo.name) 準備好了，按 \(settings.hotkey.shortLabel) 開始說話"))
            return
        }
        hotkeyRunning = false
        overlay.show(.error("請到 系統設定 › 隱私權與安全性 › 輔助使用 打開 \(AppInfo.name)，打開後會自動啟用"))
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if AXIsProcessTrusted() && self.hotkey.start() {
                self.hotkeyRunning = true
                t.invalidate()
                self.rebuildMenu()
                self.overlay.show(.info("\(AppInfo.name) 準備好了，按 \(self.settings.hotkey.shortLabel) 開始說話"))
            }
        }
    }

    private func refreshOllama() {
        ollama.checkStatus { [weak self] s in
            guard let self = self else { return }
            let changed = s != self.ollamaStatus
            self.ollamaStatus = s
            if changed { self.rebuildMenu(); self.syncHub() }
            if s == .ready && !self.warmedUp && self.settings.refine {
                self.warmedUp = true
                self.ollama.warmUp()
            }
        }
    }

    // MARK: - hotkey

    private func handlePress() {
        switch state {
        case .idle:
            pressStartedRecording = true
            startRecording()
        case .recording:
            if Date().timeIntervalSince(recordingStartedAt) < 0.4 { return }
            pressStartedRecording = false
            stopAndProcess()
        default:
            break
        }
    }

    private func handleRelease(_ held: TimeInterval) {
        if state == .recording && pressStartedRecording && held > 0.6 && Date().timeIntervalSince(recordingStartedAt) > 0.6 {
            stopAndProcess()
        }
        pressStartedRecording = false
    }

    private func setHotkey(_ h: HotkeyChoice) {
        settings.hotkey = h
        hotkey.configure(h)
        if hotkeyRunning { hotkey.start() }
        overlay.show(.info("快捷鍵改成 \(h.shortLabel)"))
        afterSettingsChange()
    }

    private func learnHotkey() {
        guard hotkeyRunning else {
            overlay.show(.error("還沒有輔助使用權限，先到系統設定打開 \(AppInfo.name)"))
            return
        }
        hub.learningHotkey = true
        overlay.show(.info("現在按一下你想當快捷鍵的那顆鍵…"))
        hotkey.captureNext = { [weak self] kc, mask, name in
            guard let self = self else { return }
            if kc == 57 {
                self.hub.learningHotkey = false
                self.overlay.show(.error("Caps Lock 每按一次會切換大小寫，不適合當快捷鍵，請換一顆再試"))
                return
            }
            self.settings.customKeyCode = Int(kc)
            self.settings.customMask = mask
            self.settings.customLabel = name
            self.settings.hotkey = .custom
            self.hotkey.configure(.custom)
            self.hotkey.start()
            self.hub.learningHotkey = false
            self.overlay.show(.info("快捷鍵改成「\(name)」，按一下它開始說話"))
            self.afterSettingsChange()
            Log.w("custom hotkey learned kc=\(kc) mask=\(String(mask, radix: 16)) name=\(name)")
        }
    }

    // MARK: - pipeline

    private func startRecording() {
        guard whisper.isReady else {
            overlay.show(.error("Whisper 還沒準備好：\(whisperStatusText())"))
            return
        }
        do {
            try recorder.beginRecording()
        } catch {
            Log.w("recorder.start failed: \(error.localizedDescription)")
            overlay.show(.error(error.localizedDescription))
            return
        }
        state = .recording
        recordingStartedAt = Date()
        hotkey.escapeArmed = true
        playSound("Tink")
        overlay.show(.listening(hotkey: settings.hotkey.shortLabel, mode: settings.mode.shortTitle))
        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: settings.maxSeconds, repeats: false) { [weak self] _ in
            self?.stopAndProcess()
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        autoStopTimer?.invalidate()
        hotkey.escapeArmed = false
        if let rec = recorder.endRecording() { try? FileManager.default.removeItem(at: rec.url) }
        state = .idle
        applyMicKeepAlive()
        playSound("Pop")
        overlay.show(.info("已取消"))
    }

    private func stopAndProcess() {
        guard state == .recording else { return }
        autoStopTimer?.invalidate()
        hotkey.escapeArmed = false
        state = .transcribing
        playSound("Pop")
        overlay.show(.transcribing)
        let recResult = recorder.endRecording()
        applyMicKeepAlive()
        guard let rec = recResult else { fail("沒有錄到聲音"); return }
        Log.w(String(format: "recorded %.1fs peak=%.3f", rec.seconds, rec.peak))
        if rec.seconds < 0.4 || rec.peak < 0.004 {
            try? FileManager.default.removeItem(at: rec.url)
            fail("沒有聽到聲音，再試一次")
            return
        }
        let lang = settings.language
        var prompt = (lang == .zh || lang == .auto) ? Prompts.whisperZhPrompt : ""
        prompt += dict.whisperHint
        let mode = settings.mode
        let seconds = rec.seconds

        let run: (String?) -> Void = { [weak self] selection in
            guard let self = self else { return }
            self.whisper.transcribe(wav: rec.url, language: lang.whisperCode, prompt: prompt.isEmpty ? nil : prompt) { result in
                DispatchQueue.main.async {
                    try? FileManager.default.removeItem(at: rec.url)
                    switch result {
                    case .failure(let e):
                        self.fail("辨識失敗：\(e.localizedDescription)")
                    case .success(let raw):
                        let text = TextCleaner.clean(raw)
                        if text.isEmpty { self.fail("沒有辨識出文字"); return }
                        self.afterTranscript(text, mode: mode, selection: selection, seconds: seconds)
                    }
                }
            }
        }
        if mode == .ask {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                TextInserter.readSelection { sel in run(sel) }
            }
        } else {
            run(nil)
        }
    }

    private func systemPrompt(for mode: Mode) -> String {
        let base: String
        switch mode {
        case .dictate: base = Prompts.dictateSystem
        case .translate: base = Prompts.translateSystem(target: settings.translateTarget)
        case .ask: base = Prompts.askSystem
        }
        return base + dict.llmHint
    }

    private func afterTranscript(_ text: String, mode: Mode, selection: String?, seconds: Double) {
        let needsLLM = settings.refine || mode != .dictate
        guard needsLLM else { insert(text, raw: text, mode: mode, seconds: seconds); return }
        guard ollamaStatus == .ready else {
            if mode == .dictate {
                overlay.show(.info("Qwen 還沒準備好，先貼原文"))
                insert(text, raw: text, mode: mode, seconds: seconds)
            } else {
                fail("Qwen 還沒準備好：\(ollamaStatusText())")
            }
            return
        }
        state = .refining
        overlay.show(.refining)
        let user: String
        switch mode {
        case .dictate, .translate: user = text
        case .ask: user = Prompts.askUser(selected: selection, command: text)
        }
        ollama.chat(system: systemPrompt(for: mode), user: user) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let out):
                    self.insert(out.isEmpty ? text : out, raw: text, mode: mode, seconds: seconds)
                case .failure(let e):
                    Log.w("ollama failed: \(e)")
                    if mode == .dictate {
                        self.overlay.show(.info("Qwen 沒回應，先貼原文"))
                        self.insert(text, raw: text, mode: mode, seconds: seconds)
                    } else {
                        self.fail("Qwen 失敗：\(e.localizedDescription)")
                    }
                }
            }
        }
    }

    private func insert(_ text: String, raw: String, mode: Mode, seconds: Double) {
        state = .inserting
        lastResult = text
        history.add(HistoryItem(date: Date(), seconds: seconds, raw: raw, refined: text == raw ? nil : text, mode: mode.rawValue))
        playSound("Glass")
        overlay.show(.done(text))
        TextInserter.paste(text) { [weak self] in
            guard let self = self else { return }
            self.state = .idle
            if self.ollamaStatus == .ready && self.settings.refine { self.ollama.warmUp() }
        }
    }

    private func retryRefine(_ item: HistoryItem) {
        guard ollamaStatus == .ready else { return }
        let mode = Mode(rawValue: item.mode) ?? .dictate
        overlay.show(.refining)
        ollama.chat(system: systemPrompt(for: mode), user: item.raw) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let out):
                    self.history.update(item.id, refined: out)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(out, forType: .string)
                    self.overlay.show(.info("重新潤稿完成，已複製到剪貼簿"))
                case .failure(let e):
                    self.overlay.show(.error("重新潤稿失敗：\(e.localizedDescription)"))
                }
            }
        }
    }

    private var micSleepTimer: Timer?
    private var micRetryTimer: Timer?

    /// 常駐模式下麥克風暫時不見（USB 休眠、拔插）時，每 10 秒再試一次
    private func scheduleStandbyRetry() {
        micRetryTimer?.invalidate()
        micRetryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            guard self.settings.micKeepAlive != .off, !self.recorder.isCapturing, self.state == .idle else { return }
            do {
                try self.recorder.ensureCapturing()
                Log.w("standby capture recovered")
                t.invalidate()
                self.syncHub()
            } catch {}
        }
    }

    /// 依設定決定聽寫結束後麥克風通道要不要繼續開著
    private func applyMicKeepAlive() {
        micSleepTimer?.invalidate()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        switch settings.micKeepAlive {
        case .always:
            if !recorder.isCapturing {
                do { try recorder.ensureCapturing() } catch {
                    Log.w("standby capture failed: \(error.localizedDescription)")
                    scheduleStandbyRetry()
                }
            }
        case .tenMinutes:
            if !recorder.isCapturing {
                do { try recorder.ensureCapturing() } catch {
                    Log.w("standby capture failed: \(error.localizedDescription)")
                    scheduleStandbyRetry()
                }
            }
            micSleepTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
                guard let self = self, self.state == .idle else { return }
                self.recorder.stopCapturing()
            }
        case .off:
            if state == .idle { recorder.stopCapturing() }
        }
        syncHub()
    }

    private func setKeepModelLoaded(_ v: Bool) {
        settings.keepModelLoaded = v
        if v { if ollamaStatus == .ready { ollama.warmUp() } } else { ollama.unload() }
        overlay.show(.info(v ? "潤稿模型會常駐記憶體" : "潤稿模型閒置 30 分鐘後會卸載"))
        afterSettingsChange()
    }
    @objc private func toggleKeepModelLoaded() { setKeepModelLoaded(!settings.keepModelLoaded) }

    private func setMicKeepAlive(_ k: MicKeepAlive) {
        settings.micKeepAlive = k
        applyMicKeepAlive()
        overlay.show(.info("麥克風保持喚醒：\(k.title)"))
        afterSettingsChange()
    }

    @objc private func pickMicKeepAlive(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let k = MicKeepAlive(rawValue: r) { setMicKeepAlive(k) }
    }

    private func fail(_ msg: String) {
        Log.w("fail: \(msg)")
        state = .idle
        applyMicKeepAlive()
        playSound("Basso")
        overlay.show(.error(msg))
    }

    private func playSound(_ name: String) {
        guard settings.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: - status bar

    private func updateStatusIcon() {
        guard let b = statusItem?.button else { return }
        let name: String
        switch state {
        case .idle: name = "mic"
        case .recording: name = "mic.fill"
        case .transcribing: name = "waveform"
        case .refining: name = "sparkles"
        case .inserting: name = "text.cursor"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.name)
        img?.isTemplate = true
        b.image = img
        b.contentTintColor = state == .recording ? .systemRed : nil
    }

    private func statusLine() -> String {
        switch state {
        case .idle: return hotkeyRunning ? "待命中：按 \(settings.hotkey.shortLabel) 開始說話" : "等待「輔助使用」權限…"
        case .recording: return "錄音中…（再按一下結束，Esc 取消）"
        case .transcribing: return "辨識中…"
        case .refining: return "潤稿中…"
        case .inserting: return "貼上中…"
        }
    }

    private func whisperStatusText() -> String {
        switch whisper.state {
        case .stopped: return "未啟動"
        case .starting: return "載入模型中…"
        case .ready: return "就緒"
        case .failed(let m): return "失敗（\(m.replacingOccurrences(of: "\n", with: " "))）"
        }
    }

    private func ollamaStatusText() -> String {
        switch ollamaStatus {
        case .notRunning: return "Ollama 沒有在跑"
        case .modelMissing: return "模型還沒下載完"
        case .ready: return "就緒"
        }
    }

    private func item(_ title: String, _ sel: Selector?, rep: String? = nil, checked: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.representedObject = rep
        it.state = checked ? .on : .off
        it.isEnabled = enabled
        return it
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        items.forEach { m.addItem($0) }
        parent.submenu = m
        return parent
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(item(statusLine(), nil, enabled: false))
        let open = NSMenuItem(title: "打開 \(AppInfo.name) 主視窗", action: #selector(openHub), keyEquivalent: "o")
        open.target = self
        m.addItem(open)
        m.addItem(.separator())
        m.addItem(item("Whisper large-v3：\(whisperStatusText())", nil, enabled: false))
        m.addItem(item("Qwen（\(settings.ollamaModel)）：\(ollamaStatusText())", nil, enabled: false))
        if VolumeManager.usesImage {
            m.addItem(item("模型磁碟映像：\(VolumeManager.isMounted ? "已掛載" : "未掛載")", nil, enabled: false))
        }
        m.addItem(.separator())
        m.addItem(submenu("模式：\(settings.mode.shortTitle)", Mode.allCases.map {
            item($0.title, #selector(pickMode(_:)), rep: $0.rawValue, checked: $0 == settings.mode)
        }))
        m.addItem(submenu("翻譯成：\(settings.translateTarget)", Settings.translateTargets.map {
            item($0, #selector(pickTarget(_:)), rep: $0, checked: $0 == settings.translateTarget)
        }))
        var hotkeyItems = HotkeyChoice.allCases.filter { $0 != .custom || settings.customKeyCode != 0 || settings.customMask != 0 }.map {
            item($0.title, #selector(pickHotkey(_:)), rep: $0.rawValue, checked: $0 == settings.hotkey)
        }
        hotkeyItems.append(.separator())
        hotkeyItems.append(item("自訂快捷鍵：按下你想用的那顆鍵…", #selector(learnHotkeyMenu)))
        m.addItem(submenu("快捷鍵：\(settings.hotkey.shortLabel)", hotkeyItems))
        m.addItem(submenu("辨識語言：\(settings.language.title)", SpeechLanguage.allCases.map {
            item($0.title, #selector(pickLanguage(_:)), rep: $0.rawValue, checked: $0 == settings.language)
        }))
        m.addItem(item("AI 潤稿（\(settings.ollamaModel)）", #selector(toggleRefine), checked: settings.refine))
        m.addItem(item("潤稿模型常駐記憶體", #selector(toggleKeepModelLoaded), checked: settings.keepModelLoaded))
        m.addItem(item("提示音", #selector(toggleSounds), checked: settings.sounds))
        m.addItem(submenu("麥克風保持喚醒：\(settings.micKeepAlive.shortTitle)（\(recorder.isCapturing ? "常駐中" : "休眠中")）", MicKeepAlive.allCases.map {
            item($0.title, #selector(pickMicKeepAlive(_:)), rep: $0.rawValue, checked: $0 == settings.micKeepAlive)
        }))
        m.addItem(item("登入時自動啟動", #selector(toggleLoginMenu), checked: SMAppService.mainApp.status == .enabled))
        m.addItem(.separator())
        m.addItem(item("複製上一次的結果", #selector(copyLast), enabled: lastResult != nil))
        m.addItem(item("重啟引擎", #selector(restartEnginesMenu)))
        m.addItem(item("打開「輔助使用」設定…", #selector(openAccessibility)))
        m.addItem(item("打開「麥克風」設定…", #selector(openMicSettings)))
        m.addItem(item("打開記錄檔資料夾", #selector(openLogsMenu)))
        m.addItem(.separator())
        m.addItem(item("關於 \(AppInfo.name)", #selector(about)))
        let q = NSMenuItem(title: "結束 \(AppInfo.name)", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        m.addItem(q)
        statusItem.menu = m
    }

    // MARK: - menu actions

    @objc private func pickMode(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let m = Mode(rawValue: r) { settings.mode = m }
        afterSettingsChange()
    }
    @objc private func pickTarget(_ s: NSMenuItem) {
        if let r = s.representedObject as? String { settings.translateTarget = r }
        afterSettingsChange()
    }
    @objc private func pickHotkey(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let h = HotkeyChoice(rawValue: r) { setHotkey(h) }
    }
    @objc private func learnHotkeyMenu() { learnHotkey() }
    @objc private func pickLanguage(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let l = SpeechLanguage(rawValue: r) { settings.language = l }
        afterSettingsChange()
    }
    @objc private func toggleRefine() {
        settings.refine.toggle()
        if settings.refine && ollamaStatus == .ready { ollama.warmUp() }
        afterSettingsChange()
    }
    @objc private func toggleSounds() { settings.sounds.toggle(); afterSettingsChange() }
    @objc private func toggleLoginMenu() { toggleLogin() }
    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            overlay.show(.error("設定開機啟動失敗：\(error.localizedDescription)"))
        }
        afterSettingsChange()
    }
    @objc private func copyLast() {
        guard let t = lastResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        overlay.show(.info("已複製上一次的結果"))
    }
    @objc private func restartEnginesMenu() { restartEngines() }
    private func restartEngines() { whisper.stop(); mountAndStartEngines() }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
    @objc private func openLogsMenu() { openLogs() }
    private func openLogs() { NSWorkspace.shared.open(Settings.logDir) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(AppInfo.name) \(AppInfo.version)"
        a.informativeText = """
        本機語音聽寫。按一下快捷鍵說話，再按一下，整理好的文字就出現在游標那裡。
        語音辨識：Whisper large-v3（whisper.cpp，Metal）
        潤稿：\(settings.ollamaModel)（Ollama）
        錄音與文字都不離開這台電腦。
        """
        a.addButton(withTitle: "好")
        a.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
