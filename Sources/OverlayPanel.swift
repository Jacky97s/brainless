import AppKit

final class LevelMeterView: NSView {
    private var levels: [CGFloat] = Array(repeating: 0.06, count: 14)
    func push(_ rms: Float) {
        let v = min(1.0, CGFloat(rms) * 7.0)
        levels.removeFirst()
        levels.append(max(0.06, v))
        needsDisplay = true
    }
    func reset() { levels = Array(repeating: 0.06, count: 14); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(levels.count)
        let gap: CGFloat = 3
        let barW = (bounds.width - gap * (n - 1)) / n
        NSColor.white.withAlphaComponent(0.9).setFill()
        for (i, l) in levels.enumerated() {
            let h = max(3, bounds.height * l)
            let x = CGFloat(i) * (barW + gap)
            let r = NSRect(x: x, y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

/// 螢幕下方的小浮條：顯示聆聽／辨識／潤稿／完成／錯誤。不搶焦點。
final class OverlayPanel: NSPanel {
    enum Display {
        case listening(hotkey: String, mode: String)
        case transcribing
        case refining(String)
        case done(String)
        case error(String)
        case info(String)
    }

    private let icon = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let meter = LevelMeterView()
    private var hideTimer: Timer?

    init() {
        let rect = NSRect(x: 0, y: 0, width: 380, height: 68)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        appearance = NSAppearance(named: .darkAqua)
        let effect = NSView(frame: rect)
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        effect.autoresizingMask = [.width, .height]
        contentView = effect

        icon.font = NSFont.systemFont(ofSize: 24)
        icon.frame = NSRect(x: 16, y: 18, width: 34, height: 32)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 56, y: 36, width: 300, height: 20)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        subtitleLabel.frame = NSRect(x: 56, y: 14, width: 308, height: 18)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        meter.frame = NSRect(x: 262, y: 22, width: 100, height: 24)
        [icon, titleLabel, subtitleLabel, meter].forEach { effect.addSubview($0) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2, y: vf.minY + 28))
    }

    func show(_ d: Display) {
        hideTimer?.invalidate()
        meter.isHidden = true
        subtitleLabel.frame.size.width = 308
        var autoHide: TimeInterval? = nil
        switch d {
        case .listening(let hk, let mode):
            icon.stringValue = "🎙️"
            titleLabel.stringValue = "聆聽中（\(mode)）"
            subtitleLabel.stringValue = "再按一下 \(hk) 結束，Esc 取消"
            subtitleLabel.frame.size.width = 200
            meter.isHidden = false
            meter.reset()
        case .transcribing:
            icon.stringValue = "👂"
            titleLabel.stringValue = "辨識中…"
            subtitleLabel.stringValue = "Whisper large-v3 正在聽"
        case .refining(let who):
            icon.stringValue = "✨"
            titleLabel.stringValue = "潤稿中…"
            subtitleLabel.stringValue = "\(who) 正在整理"
        case .done(let t):
            icon.stringValue = "✅"
            titleLabel.stringValue = "已貼上"
            subtitleLabel.stringValue = t.replacingOccurrences(of: "\n", with: " ")
            autoHide = 3
        case .error(let m):
            icon.stringValue = "⚠️"
            titleLabel.stringValue = "出了點問題"
            subtitleLabel.stringValue = m.replacingOccurrences(of: "\n", with: " ")
            autoHide = 6
        case .info(let m):
            icon.stringValue = "💬"
            titleLabel.stringValue = m
            subtitleLabel.stringValue = ""
            autoHide = 3
        }
        place()
        orderFrontRegardless()
        if let t = autoHide {
            hideTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.orderOut(nil) }
        }
    }

    func level(_ rms: Float) { meter.push(rms) }
    func hide() { hideTimer?.invalidate(); orderOut(nil) }
}
