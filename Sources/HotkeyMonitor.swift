import Foundation
import CoreGraphics

/// 全域快捷鍵監聽：用 CGEventTap 抓單一按鍵（修飾鍵或一般鍵）的按下與放開。
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// 設定了就進入「學習模式」：下一個按下的鍵會回傳 (keyCode, flagMask, 名稱)，不觸發錄音
    var captureNext: ((Int64, UInt64, String) -> Void)?
    /// 錄音中設成 true：按 Esc 會取消
    var escapeArmed = false
    var onEscape: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyCode: Int64 = 61
    private var isModifier = true
    private var flagMask: UInt64 = 0x80000
    private var pressedAt: Date?
    private var lastFlags: UInt64 = 0
    private var debugCount = 0

    func configure(_ choice: HotkeyChoice) {
        keyCode = choice.keyCode
        isModifier = choice.isModifier
        flagMask = choice.flagMask
        pressedAt = nil
        Log.w("HotkeyMonitor: configured keyCode=\(keyCode) modifier=\(isModifier) mask=\(String(flagMask, radix: 16))")
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.w("HotkeyMonitor: tapCreate failed (no accessibility permission?)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugCount = 0
        Log.w("HotkeyMonitor: started keyCode=\(keyCode) modifier=\(isModifier) mask=\(String(flagMask, radix: 16))")
        return true
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        source = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        // 只記修飾鍵（Ctrl／Alt／Cmd 這類）的變化，絕不記一般打字的按鍵
        if type == .flagsChanged && debugCount < 20 {
            debugCount += 1
            Log.w("modifier event kc=\(kc) flags=\(String(flags, radix: 16))")
        }

        // 學習模式：記下第一個按下的鍵
        if let cap = captureNext {
            if type == .flagsChanged {
                let newlyDown = (flags ^ lastFlags) & flags & 0xFFFF0000
                lastFlags = flags
                if newlyDown != 0 {
                    captureNext = nil
                    let name = HotkeyChoice.name(forKeyCode: kc, mask: newlyDown)
                    DispatchQueue.main.async { cap(kc, newlyDown, name) }
                }
                return Unmanaged.passUnretained(event)
            } else if type == .keyDown {
                captureNext = nil
                let name = HotkeyChoice.name(forKeyCode: kc, mask: 0)
                DispatchQueue.main.async { cap(kc, 0, name) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged { lastFlags = flags }

        if escapeArmed && kc == 53 && (type == .keyDown || type == .keyUp) {
            if type == .keyDown { DispatchQueue.main.async { self.onEscape?() } }
            return nil
        }

        guard kc == keyCode else { return Unmanaged.passUnretained(event) }

        if isModifier {
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            let down = (flags & flagMask) != 0
            if down {
                if pressedAt == nil {
                    pressedAt = Date()
                    DispatchQueue.main.async { self.onPress?() }
                }
            } else if let p = pressedAt {
                pressedAt = nil
                let held = Date().timeIntervalSince(p)
                DispatchQueue.main.async { self.onRelease?(held) }
            }
            if keyCode == 63 { return nil }
            return Unmanaged.passUnretained(event)
        } else {
            if type == .keyDown {
                if pressedAt == nil {
                    pressedAt = Date()
                    DispatchQueue.main.async { self.onPress?() }
                }
                return nil
            } else if type == .keyUp {
                if let p = pressedAt {
                    pressedAt = nil
                    let held = Date().timeIntervalSince(p)
                    DispatchQueue.main.async { self.onRelease?(held) }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
    }
}
