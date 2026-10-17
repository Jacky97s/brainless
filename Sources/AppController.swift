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
        // 粵語輸出常在字與字之間夾空格，收掉中文字之間的空格
        t = t.replacingOccurrences(of: #"(?<=[\p{Han}，。！？、：；「」（）])\s+(?=[\p{Han}，。！？、：；「」（）])"#, with: "", options: .regularExpression)
        // 同一句連續重複好幾次（Whisper 幻覺）只留一次
        t = t.replacingOccurrences(of: #"(.{4,60}?)(?:[\s，,。！？?!]*\1){1,}"#, with: "$1", options: .regularExpression)
        let hallucinations = ["謝謝觀看", "謝謝收看", "請不吝點讚", "請不吝點贊", "點讚訂閱", "字幕由", "字幕提供", "中文字幕", "CaptionCube", "Amara.org", "明鏡", "訂閱我的頻道", "感謝收看", "下期再見"]
        if t.count <= 24, hallucinations.contains(where: { t.contains($0) }) { return "" }
        for h in ["中文字幕:", "中文字幕：", "字幕:", "字幕："] {
            if t.hasPrefix(h) { t = String(t.dropFirst(h.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    enum State: String { case idle, recording, transcribing, refining, inserting }
    private var state: State = .idle {
        didSet { updateStatusIcon(); rebuildMenu(); syncHub() }
    }

    private let settings = Settings.shared
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let refiner = RefineService()
    private let overlay = OverlayPanel()
    private let history = HistoryStore()
    private let dict = DictionaryStore()
    private let hub = HubModel()
    private let hubWindow = HubWindowController()
    private var statusItem: NSStatusItem!
    private var pressStartedRecording = false
    private var recordingMode: Mode = .dictate
    private var recordingStartedAt = Date.distantPast
    private var autoStopTimer: Timer?
    private var lastResult: String?
    private var accessibilityTimer: Timer?
    private var hotkeyRunning = false
    private var warmedUp = false

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.w("\(AppInfo.name) launched")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
        wireHub()

        transcriber.onStateChange = { [weak self] s in
            self?.rebuildMenu()
            self?.syncHub()
            if case .failed(let msg) = s { self?.overlay.show(.error(msg)) }
        }
        mountAndStartEngines()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshRefiner()
            if self?.state == .idle { self?.transcriber.checkHealth() }
        }
        Timer.scheduledTimer(withTimeInterval: 1200, repeats: true) { [weak self] _ in
            guard let self = self, self.settings.keepModelLoaded, self.settings.refine, self.refiner.isReady else { return }
            self.refiner.warmUp()
        }

        recorder.onLevel = { [weak self] l in self?.overlay.level(l) }
        recorder.onCaptureStateChange = { [weak self] in self?.rebuildMenu(); self?.syncHub() }
        hotkey.configure(settings.shortcuts)
        hotkey.onPress = { [weak self] mode, sc in self?.handlePress(mode, sc) }
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
        transcriber.stop()
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
                    self.transcriber.start()
                }
                self.refiner.refresh { _ in
                    self.rebuildMenu()
                    self.syncHub()
                    guard self.refiner.backend == .ollama else { return }
                    VolumeManager.ensureOllamaRunning()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refreshRefiner() }
                }
                self.rebuildMenu()
                self.syncHub()
            }
        }
    }

    // MARK: - hub window

    private func wireHub() {
        hub.onAddShortcut = { [weak self] m in self?.learnShortcut(for: m) }
        hub.onRemoveShortcut = { [weak self] m, sc in self?.removeShortcut(sc, from: m) }
        hub.onSetTarget = { [weak self] t in self?.settings.translateTarget = t; self?.afterSettingsChange() }
        hub.onSetLanguage = { [weak self] l in self?.settings.language = l; self?.afterSettingsChange() }
        hub.onSetRefine = { [weak self] v in
            guard let self = self else { return }
            self.settings.refine = v
            if v && self.refiner.isReady { self.refiner.warmUp() }
            self.afterSettingsChange()
        }
        hub.onSetHoldToTalk = { [weak self] v in self?.settings.holdToTalk = v; self?.afterSettingsChange() }
        hub.onSetSounds = { [weak self] v in self?.settings.sounds = v; self?.afterSettingsChange() }
        hub.onSetMicKeepAlive = { [weak self] k in self?.setMicKeepAlive(k) }
        hub.onSetKeepModelLoaded = { [weak self] v in self?.setKeepModelLoaded(v) }
        hub.onSetFastWhisper = { [weak self] v in self?.settings.fastWhisper = v; self?.afterSettingsChange() }
        hub.onSetSpeechEngine = { [weak self] e in self?.settings.speechEngine = e; self?.restartTranscriber() }
        hub.onSetRemoteWhisper = { [weak self] url, model in
            self?.settings.remoteWhisperURL = url
            self?.settings.remoteWhisperModel = model
            self?.restartTranscriber()
        }
        hub.onSetRemoteKey = { [weak self] key in self?.settings.setRemoteKey(key); self?.restartTranscriber() }
        hub.onToggleAllowedLanguage = { [weak self] name in
            guard let self = self else { return }
            var a = self.settings.allowedLanguages
            if let i = a.firstIndex(of: name) { a.remove(at: i) } else { a.append(name) }
            self.settings.allowedLanguages = a
            self.afterSettingsChange()
        }
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
            self.transcriber.start()
            self.syncHub()
        }
        hub.onSetBackend = { [weak self] b in self?.setBackend(b) }
        hub.onSetAgentModel = { [weak self] m in
            guard let self = self else { return }
            switch self.refiner.backend {
            case .claude: self.settings.claudeModel = m
            case .codex: self.settings.codexModel = m
            case .ollama: return
            }
            self.afterSettingsChange()
        }
        hub.onPullModel = { [weak self] in
            guard let self = self else { return }
            VolumeManager.ensureOllamaRunning()
            self.hub.puller.start(model: self.settings.ollamaModel)
        }
        hub.puller.onDone = { [weak self] in
            self?.overlay.show(.info("潤稿模型下載完成"))
            self?.refreshRefiner()
        }
        syncHub()
    }

    private func afterSettingsChange() { rebuildMenu(); syncHub() }

    private func restartTranscriber() {
        transcriber.stop()
        transcriber.start()
        afterSettingsChange()
    }

    private func syncHub() {
        hub.shortcuts = settings.shortcuts
        hub.translateTarget = settings.translateTarget
        hub.language = settings.language
        hub.refine = settings.refine
        hub.sounds = settings.sounds
        hub.holdToTalk = settings.holdToTalk
        hub.loginEnabled = SMAppService.mainApp.status == .enabled
        hub.speechEngine = settings.speechEngine
        hub.remoteWhisperURL = settings.remoteWhisperURL
        hub.remoteWhisperModel = settings.remoteWhisperModel
        hub.remoteHost = settings.remoteWhisper?.baseURL.host ?? ""
        hub.hasRemoteKey = !(settings.remoteKey ?? "").isEmpty
        hub.transcriberLabel = transcriber.label
        hub.whisperOK = transcriber.isReady
        hub.whisperStatus = transcriberStatusText()
        hub.refinerOK = refiner.isReady
        hub.refinerStatus = refiner.statusText
        hub.refinerLabel = refiner.label
        hub.refineBackend = settings.refineBackend
        hub.resolvedBackend = refiner.backend
        hub.installedBackends = Set(RefineBackend.allCases.filter { refiner.isInstalled($0) })
        hub.agentModel = refiner.backend == .ollama ? "" : refiner.model
        hub.ollamaModel = settings.ollamaModel
        hub.whisperModelName = URL(fileURLWithPath: settings.whisperModelPath).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        hub.volumeMounted = VolumeManager.isMounted
        hub.appState = statusLine()
        hub.phase = hotkeyRunning ? state.rawValue : "noPermission"
        hub.whisperModelPresent = ModelSetup.whisperModelPresent
        hub.whisperServerPresent = ModelSetup.findWhisperServer() != nil
        hub.ollamaInstalled = ModelSetup.ollamaInstalled
        hub.usesImage = VolumeManager.usesImage
        hub.micKeepAlive = settings.micKeepAlive
        hub.keepModelLoaded = settings.keepModelLoaded
        hub.fastWhisper = settings.fastWhisper
        hub.allowedLanguages = settings.allowedLanguages
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
            syncHub()
            overlay.show(.info("\(AppInfo.name) 準備好了，按 \(settings.primaryShortcutLabel) 開始說話"))
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
                self.syncHub()
                self.overlay.show(.info("\(AppInfo.name) 準備好了，按 \(self.settings.primaryShortcutLabel) 開始說話"))
            }
        }
    }

    private func refreshRefiner() {
        refiner.refresh { [weak self] changed in
            guard let self = self else { return }
            if changed { self.rebuildMenu(); self.syncHub() }
            if self.refiner.isReady && !self.warmedUp && self.settings.refine {
                self.warmedUp = true
                self.refiner.warmUp()
            }
        }
    }

    private func setBackend(_ raw: String) {
        let before = refiner.backend
        settings.refineBackend = raw
        let after = refiner.backend
        if before == .ollama && after != .ollama { refiner.unloadOllama() }
        if after == .ollama { VolumeManager.ensureOllamaRunning() }
        warmedUp = false
        overlay.show(.info("潤稿改用 \(refiner.label)"))
        afterSettingsChange()
        refreshRefiner()
    }

    // MARK: - hotkey

    private func handlePress(_ mode: Mode, _ sc: Shortcut) {
        switch state {
        case .idle:
            pressStartedRecording = true
            recordingMode = mode
            startRecording(shortcut: sc)
        case .recording:
            if Date().timeIntervalSince(recordingStartedAt) < 0.4 { return }
            pressStartedRecording = false
            stopAndProcess()
        default:
            break
        }
    }

    private func handleRelease(_ held: TimeInterval) {
        if settings.holdToTalk && state == .recording && pressStartedRecording && held > 0.6 && Date().timeIntervalSince(recordingStartedAt) > 0.6 {
            stopAndProcess()
        }
        pressStartedRecording = false
    }

    private func applyShortcuts(_ sc: [Mode: [Shortcut]]) {
        settings.shortcuts = sc
        hotkey.configure(sc)
        afterSettingsChange()
    }

    private func removeShortcut(_ sc: Shortcut, from mode: Mode) {
        var all = settings.shortcuts
        all[mode]?.removeAll { $0.sameKeys(as: sc) }
        applyShortcuts(all)
    }

    private func learnShortcut(for mode: Mode) {
        guard hotkeyRunning else {
            overlay.show(.error("還沒有輔助使用權限，先到系統設定打開 \(AppInfo.name)"))
            return
        }
        hub.learningMode = mode
        overlay.show(.info("按下要給「\(mode.shortTitle)」用的鍵或組合，Esc 取消"))
        hotkey.captureNext = { [weak self] sc in
            guard let self = self else { return }
            self.hub.learningMode = nil
            guard let sc = sc else { self.overlay.show(.info("已取消")); return }
            if sc.key == 57 {
                self.overlay.show(.error("Caps Lock 每按一次會切換大小寫，不適合當快捷鍵，請換一組再試"))
                return
            }
            if sc.key == 53 {
                self.overlay.show(.error("Esc 是用來取消錄音的，請換一組再試"))
                return
            }
            var all = self.settings.shortcuts
            if let owner = Mode.allCases.first(where: { m in all[m]?.contains { $0.sameKeys(as: sc) } ?? false }) {
                self.overlay.show(.error("「\(sc.label)」已經是「\(owner.shortTitle)」的快捷鍵"))
                return
            }
            all[mode, default: []].append(sc)
            self.applyShortcuts(all)
            self.overlay.show(.info("「\(mode.shortTitle)」加上「\(sc.label)」"))
            Log.w("shortcut learned for \(mode.rawValue): mods=\(sc.modifiers) key=\(sc.key.map(String.init) ?? "-")")
        }
    }

    // MARK: - pipeline

    private func startRecording(shortcut: Shortcut) {
        guard transcriber.isReady else {
            overlay.show(.error("語音辨識還沒準備好：\(transcriberStatusText())"))
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
        overlay.show(.listening(hotkey: shortcut.label, mode: recordingMode.shortTitle))
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
        overlay.show(.transcribing(transcriber.label))
        let recResult = recorder.endRecording()
        applyMicKeepAlive()
        guard let rec = recResult else { fail("沒有錄到聲音"); return }
        Log.w(String(format: "recorded %.1fs peak=%.3f", rec.seconds, rec.peak))
        if rec.seconds < 0.7 || rec.peak < 0.004 {
            try? FileManager.default.removeItem(at: rec.url)
            fail("沒有聽到聲音，再試一次")
            return
        }
        let lang = settings.language
        var prompt = (lang == .zh || lang == .auto) ? Prompts.whisperZhPrompt : (lang == .yue ? Prompts.whisperYuePrompt : "")
        prompt += dict.whisperHint
        let mode = recordingMode
        let seconds = rec.seconds

        let run: (String?) -> Void = { [weak self] selection in
            guard let self = self else { return }
            let ctx = self.settings.fastWhisper ? WhisperServer.audioContext(forSeconds: seconds) : nil
            let finish: (String) -> Void = { raw in
                try? FileManager.default.removeItem(at: rec.url)
                let text = TextCleaner.clean(raw)
                if text.isEmpty { self.fail("沒有辨識出文字"); return }
                self.afterTranscript(text, mode: mode, selection: selection, seconds: seconds)
            }
            self.transcriber.transcribe(wav: rec.url, language: lang.whisperCode, prompt: prompt.isEmpty ? nil : prompt, audioContext: ctx) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let e):
                        try? FileManager.default.removeItem(at: rec.url)
                        self.fail("辨識失敗：\(e.localizedDescription)")
                    case .success(let r):
                        let allowed = self.settings.allowedLanguages
                        if lang == .auto, let det = r.language, !allowed.isEmpty, !allowed.contains(det) {
                            let code = self.settings.primaryLanguageCode
                            Log.w("detected '\(det)' not in allowed list, retrying as \(code)")
                            self.overlay.show(.transcribing(self.transcriber.label))
                            var p2 = code == "zh" ? Prompts.whisperZhPrompt : (code == "yue" ? Prompts.whisperYuePrompt : "")
                            p2 += self.dict.whisperHint
                            self.transcriber.transcribe(wav: rec.url, language: code, prompt: p2.isEmpty ? nil : p2, audioContext: ctx) { r2 in
                                DispatchQueue.main.async {
                                    switch r2 {
                                    case .failure(let e):
                                        try? FileManager.default.removeItem(at: rec.url)
                                        self.fail("辨識失敗：\(e.localizedDescription)")
                                    case .success(let rr):
                                        finish(rr.text)
                                    }
                                }
                            }
                            return
                        }
                        finish(r.text)
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

    private func systemPrompt(for mode: Mode, transcript: String) -> String {
        let base: String
        switch mode {
        case .dictate: base = Prompts.dictateSystem
        case .translate: base = Prompts.translateSystem(target: settings.translateTarget)
        case .ask: base = Prompts.askSystem
        }
        return base + dict.llmHint(for: transcript) + (settings.language == .yue ? Prompts.cantoneseHint : "")
    }

    private func afterTranscript(_ text: String, mode: Mode, selection: String?, seconds: Double) {
        let needsLLM = settings.refine || mode != .dictate
        guard needsLLM else { insert(text, raw: text, mode: mode, seconds: seconds); return }
        let who = refiner.backend.title
        guard refiner.isReady else {
            if mode == .dictate {
                overlay.show(.info("\(who) 還沒準備好，先貼原文"))
                insert(text, raw: text, mode: mode, seconds: seconds)
            } else {
                fail("\(who) 還沒準備好：\(refiner.statusText)")
            }
            return
        }
        state = .refining
        overlay.show(.refining(refiner.label))
        let user: String
        switch mode {
        case .dictate, .translate: user = Prompts.transcriptUser(text)
        case .ask: user = Prompts.askUser(selected: selection, command: text)
        }
        refiner.chat(system: systemPrompt(for: mode, transcript: text), user: user) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(var out):
                    for tag in ["【逐字稿】", "逐字稿：", "輸出「", "輸出："] {
                        if out.hasPrefix(tag) { out = String(out.dropFirst(tag.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    if mode == .dictate && Prompts.looksLikeReply(raw: text, out: out) {
                        Log.w("llm reply suspected (\(text.count) -> \(out.count) chars), using raw transcript")
                        self.overlay.show(.info("\(who) 想回話，改貼原文"))
                        self.insert(text, raw: text, mode: mode, seconds: seconds)
                        return
                    }
                    self.insert(out.isEmpty ? text : out, raw: text, mode: mode, seconds: seconds)
                case .failure(let e):
                    Log.w("refine failed: \(e)")
                    if mode == .dictate {
                        self.overlay.show(.info("\(who) 沒回應，先貼原文"))
                        self.insert(text, raw: text, mode: mode, seconds: seconds)
                    } else {
                        self.fail(e.localizedDescription)
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
            if self.refiner.isReady && self.settings.refine { self.refiner.warmUp() }
        }
    }

    private func retryRefine(_ item: HistoryItem) {
        guard refiner.isReady else { return }
        let mode = Mode(rawValue: item.mode) ?? .dictate
        overlay.show(.refining(refiner.label))
        refiner.chat(system: systemPrompt(for: mode, transcript: item.raw), user: mode == .ask ? item.raw : Prompts.transcriptUser(item.raw)) { [weak self] result in
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
        if v { if refiner.isReady { refiner.warmUp() } } else if refiner.backend == .ollama { refiner.unloadOllama() }
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
        case .idle: return hotkeyRunning ? "待命中：按 \(settings.primaryShortcutLabel) 開始說話" : "等待「輔助使用」權限…"
        case .recording: return "錄音中…（再按一下結束，Esc 取消）"
        case .transcribing: return "辨識中…"
        case .refining: return "潤稿中…"
        case .inserting: return "貼上中…"
        }
    }

    private func transcriberStatusText() -> String {
        switch transcriber.state {
        case .stopped: return "未啟動"
        case .starting: return transcriber.engine == .local ? "載入模型中…" : "連線中…"
        case .ready: return "就緒"
        case .failed(let m): return "失敗（\(m.replacingOccurrences(of: "\n", with: " "))）"
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
        m.addItem(item("\(transcriber.label)：\(transcriberStatusText())", nil, enabled: false))
        m.addItem(item("潤稿 \(refiner.label)：\(refiner.statusText)", nil, enabled: false))
        if VolumeManager.usesImage {
            m.addItem(item("模型磁碟映像：\(VolumeManager.isMounted ? "已掛載" : "未掛載")", nil, enabled: false))
        }
        m.addItem(.separator())
        m.addItem(submenu("翻譯成：\(settings.translateTarget)", Settings.translateTargets.map {
            item($0, #selector(pickTarget(_:)), rep: $0, checked: $0 == settings.translateTarget)
        }))
        let sc = settings.shortcuts
        var shortcutItems = Mode.allCases.map { m in
            item("\(m.shortTitle)：\((sc[m] ?? []).map(\.label).joined(separator: "、").nilIfEmpty ?? "未設定")", nil, enabled: false)
        }
        shortcutItems.append(.separator())
        shortcutItems.append(item("在主視窗設定快捷鍵…", #selector(openShortcutSettings)))
        m.addItem(submenu("快捷鍵", shortcutItems))
        m.addItem(submenu("辨識語言：\(settings.language.title)", SpeechLanguage.allCases.map {
            item($0.title, #selector(pickLanguage(_:)), rep: $0.rawValue, checked: $0 == settings.language)
        }))
        m.addItem(item("AI 潤稿（\(refiner.label)）", #selector(toggleRefine), checked: settings.refine))
        let backendItems = [item("自動（偵測到的第一個）", #selector(pickBackend(_:)), rep: "", checked: settings.refineBackend.isEmpty)]
            + RefineBackend.allCases.map {
                item($0.title + (refiner.isInstalled($0) ? "" : "（未安裝）"), #selector(pickBackend(_:)), rep: $0.rawValue, checked: settings.refineBackend == $0.rawValue)
            }
        m.addItem(submenu("潤稿後端：\(refiner.backend.title)", backendItems))
        if refiner.backend == .ollama {
            m.addItem(item("潤稿模型常駐記憶體", #selector(toggleKeepModelLoaded), checked: settings.keepModelLoaded))
        }
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

    @objc private func openShortcutSettings() {
        hub.page = .settings
        openHub()
    }
    @objc private func pickTarget(_ s: NSMenuItem) {
        if let r = s.representedObject as? String { settings.translateTarget = r }
        afterSettingsChange()
    }
    @objc private func pickLanguage(_ s: NSMenuItem) {
        if let r = s.representedObject as? String, let l = SpeechLanguage(rawValue: r) { settings.language = l }
        afterSettingsChange()
    }
    @objc private func pickBackend(_ s: NSMenuItem) {
        if let r = s.representedObject as? String { setBackend(r) }
    }
    @objc private func toggleRefine() {
        settings.refine.toggle()
        if settings.refine && refiner.isReady { refiner.warmUp() }
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
    private func restartEngines() { transcriber.stop(); mountAndStartEngines() }
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
        語音辨識：\(transcriber.label)
        潤稿：\(refiner.label)
        \(hub.privacyLine)
        """
        a.addButton(withTitle: "好")
        a.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
