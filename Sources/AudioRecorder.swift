import Foundation
import AVFoundation
import CoreAudio

/// 用 AVAudioEngine 收麥克風，轉成 16 kHz 單聲道。
/// 「擷取中」代表通道開著（麥克風不會被系統休眠）；「錄音中」才會把聲音存下來。
final class AudioRecorder {
    struct Result {
        let url: URL
        /// 去掉靜音後的長度（送進辨識的那一段）
        let seconds: Double
        /// 實際錄了多久，太短的判斷看這個
        let rawSeconds: Double
        let peak: Float
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var peak: Float = 0
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private(set) var isCapturing = false
    private(set) var isRecording = false
    private var configObserver: NSObjectProtocol?

    var onLevel: ((Float) -> Void)?
    /// 擷取狀態改變（開始／停止／裝置換了）時通知
    var onCaptureStateChange: (() -> Void)?

    private func err(_ msg: String) -> NSError {
        NSError(domain: "Brainless", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// 打開麥克風通道（已開著就直接回傳）
    func ensureCapturing() throws {
        if isCapturing, let e = engine, e.isRunning { return }
        stopCapturing()
        var engine = AVAudioEngine()
        var hw = engine.inputNode.inputFormat(forBus: 0)
        var attempt = 1
        while (hw.sampleRate == 0 || hw.channelCount == 0) && attempt < 3 {
            Thread.sleep(forTimeInterval: 0.5)
            engine = AVAudioEngine()
            hw = engine.inputNode.inputFormat(forBus: 0)
            attempt += 1
        }
        Log.w(String(format: "mic hw format: %.0f Hz, %d ch (attempt %d), default input: %@", hw.sampleRate, hw.channelCount, attempt, AudioRecorder.defaultInputName()))
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw err("找不到可用的麥克風（系統預設輸入：\(AudioRecorder.defaultInputName())）")
        }
        guard let conv = AVAudioConverter(from: hw, to: target) else {
            throw err("這個麥克風的格式不支援（\(Int(hw.sampleRate)) Hz，\(hw.channelCount) 聲道）")
        }
        converter = conv
        let input = engine.inputNode
        let problem = BLCatchException {
            input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buffer, _ in
                self?.process(buffer)
            }
        }
        if let p = problem {
            Log.w("installTap exception: \(p)")
            throw err("麥克風啟動失敗，換一個輸入裝置再試（\(p.prefix(80))）")
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw err("音訊引擎無法啟動：\(error.localizedDescription)")
        }
        self.engine = engine
        isCapturing = true
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigChange()
        }
        onCaptureStateChange?()
    }

    /// 裝置換了（拔插麥克風）：重新接
    private func handleConfigChange() {
        Log.w("audio configuration changed, restarting capture")
        let wasRecording = isRecording
        stopCapturing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureCapturing()
                self.isRecording = wasRecording
            } catch {
                Log.w("restart capture failed: \(error.localizedDescription)")
                self.onCaptureStateChange?()
            }
        }
    }

    func stopCapturing() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let was = isCapturing
        isCapturing = false
        isRecording = false
        if was { onCaptureStateChange?() }
    }

    func beginRecording() throws {
        try ensureCapturing()
        lock.lock(); samples.removeAll(keepingCapacity: true); peak = 0; lock.unlock()
        isRecording = true
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let converter = converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var consumed = false
        var convErr: NSError?
        let status = converter.convert(to: out, error: &convErr) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error { return }
        let n = Int(out.frameLength)
        guard n > 0, let ch = out.floatChannelData else { return }
        let p = ch[0]
        var sum: Float = 0
        var localPeak: Float = 0
        for i in 0..<n {
            let v = p[i]
            sum += v * v
            if abs(v) > localPeak { localPeak = abs(v) }
        }
        let rms = (sum / Float(n)).squareRoot()
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        if localPeak > peak { peak = localPeak }
        lock.unlock()
        DispatchQueue.main.async { self.onLevel?(rms) }
    }

    /// 結束錄音並寫出 WAV（通道是否關掉由呼叫者決定）；回傳 nil 代表沒有資料
    func endRecording() -> Result? {
        guard isRecording else { return nil }
        isRecording = false
        lock.lock()
        let data = samples
        let pk = peak
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !data.isEmpty else { return nil }
        let trimmed = AudioRecorder.trimSilence(data, sampleRate: 16000)
        if trimmed.count != data.count {
            Log.w(String(format: "trimmed %.1fs -> %.1fs", Double(data.count) / 16000, Double(trimmed.count) / 16000))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brainless-\(Int(Date().timeIntervalSince1970)).wav")
        do {
            try AudioRecorder.writeWav(samples: trimmed, sampleRate: 16000, to: url)
        } catch {
            Log.w("writeWav failed: \(error)")
            return nil
        }
        return Result(url: url, seconds: Double(trimmed.count) / 16000.0, rawSeconds: Double(data.count) / 16000.0, peak: pk)
    }

    /// 去掉頭尾靜音（各留 200 ms），中間超過 600 ms 的靜音壓成 300 ms。
    /// Whisper 的時間跟音檔長度成正比，而且長靜音容易讓它幻聽。整段都沒有聲音就原樣回傳，交給呼叫端的音量門檻判斷
    static func trimSilence(_ samples: [Float], sampleRate: Int) -> [Float] {
        let frame = sampleRate / 50
        let frames = (samples.count + frame - 1) / frame
        guard frame > 0, frames > 0 else { return samples }
        var rms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let range = (f * frame)..<min(samples.count, (f + 1) * frame)
            var sum: Float = 0
            for i in range { sum += samples[i] * samples[i] }
            rms[f] = (sum / Float(range.count)).squareRoot()
        }
        let threshold = max(0.004, 0.08 * (rms.max() ?? 0))
        guard let first = rms.firstIndex(where: { $0 >= threshold }), let last = rms.lastIndex(where: { $0 >= threshold }) else { return samples }
        let pad = sampleRate / 5 / frame
        let longGap = sampleRate * 6 / 10 / frame
        let keptGap = sampleRate * 3 / 10 / frame
        var ranges: [Range<Int>] = []
        var start = max(0, first - pad)
        var i = first
        while i <= last {
            guard rms[i] < threshold else { i += 1; continue }
            var j = i
            while rms[j] < threshold { j += 1 }
            if j - i > longGap {
                ranges.append(start..<(i + keptGap / 2))
                start = j - (keptGap - keptGap / 2)
            }
            i = j
        }
        ranges.append(start..<min(frames, last + 1 + pad))
        var out = [Float]()
        out.reserveCapacity(samples.count)
        for r in ranges { out.append(contentsOf: samples[(r.lowerBound * frame)..<min(samples.count, r.upperBound * frame)]) }
        return out
    }

    /// 系統目前的預設輸入裝置名稱
    static func defaultInputName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "沒有" }
        var name: Unmanaged<CFString>? = nil
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var naddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(deviceID, &naddr, 0, nil, &nsize, &name) == noErr, let n = name {
            return n.takeRetainedValue() as String
        }
        return "裝置 \(deviceID)"
    }

    static func writeWav(samples: [Float], sampleRate: Int, to url: URL) throws {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let c = max(-1, min(1, s))
            var v = Int16(c * 32767)
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        d.append(pcm)
        try d.write(to: url)
    }
}
