import Foundation
import CoreGraphics

/// 全域快捷鍵監聽：用 CGEventTap 抓單一按鍵（修飾鍵或一般鍵）的按下與放開。
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// 設定了就進入「學習模式」：回傳學到的鍵（修飾鍵組合會等全部放開才回傳）、是不是修飾鍵、名稱，不觸發錄音
    var captureNext: ((_ keys: [Int64], _ isModifier: Bool, _ name: String) -> Void)? {
        didSet { learnedModifiers = [] }
    }
    /// 錄音中設成 true：按 Esc 會取消
    var escapeArmed = false
    var onEscape: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyCode: Int64 = 0
    private var modifierKeys: Set<Int64> = [61]
    private var learnedModifiers: [Int64] = []
    private var pressedAt: Date?
    private var debugCount = 0

    /// 修飾鍵 keyCode → 只屬於那一顆鍵的旗標（分左右的 device bit；Fn 不分左右）
    static let modifierBits: [Int64: UInt64] = [
        56: 0x2, 60: 0x4, 59: 0x1, 62: 0x2000, 58: 0x20, 61: 0x40, 55: 0x8, 54: 0x10, 63: 0x800000,
    ]

    static func modifiersDown(_ flags: UInt64) -> Set<Int64> {
        Set(modifierBits.filter { flags & $0.value != 0 }.keys)
    }

    func configure(_ choice: HotkeyChoice) {
        keyCode = choice.keyCode
        modifierKeys = Set(choice.modifierKeys)
        pressedAt = nil
        Log.w("HotkeyMonitor: configured keyCode=\(keyCode) modifiers=\(modifierKeys.sorted())")
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
        Log.w("HotkeyMonitor: started keyCode=\(keyCode) modifiers=\(modifierKeys.sorted())")
        return true
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        source = nil
        tap = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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

        // 學習模式：修飾鍵累積到全部放開才算數（才學得到組合鍵）；一般按鍵按下就算數
        if let cap = captureNext {
            if type == .flagsChanged {
                guard Self.modifierBits[kc] != nil else {
                    // Caps Lock 這類不是 device bit 的鍵，交給上層決定要不要收
                    captureNext = nil
                    DispatchQueue.main.async { cap([kc], false, HotkeyChoice.name(forKeyCode: kc)) }
                    return Unmanaged.passUnretained(event)
                }
                let down = Self.modifiersDown(flags)
                if down.contains(kc) && !learnedModifiers.contains(kc) { learnedModifiers.append(kc) }
                if down.isEmpty && !learnedModifiers.isEmpty {
                    let keys = learnedModifiers
                    captureNext = nil
                    DispatchQueue.main.async { cap(keys, true, HotkeyChoice.name(forKeys: keys)) }
                }
                return Unmanaged.passUnretained(event)
            } else if type == .keyDown {
                captureNext = nil
                DispatchQueue.main.async { cap([kc], false, HotkeyChoice.name(forKeyCode: kc)) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if escapeArmed && kc == 53 && (type == .keyDown || type == .keyUp) {
            if type == .keyDown { DispatchQueue.main.async { self.onEscape?() } }
            return nil
        }

        if !modifierKeys.isEmpty {
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            // 組合裡每一顆都按住才算按下，任何一顆放開就算放開
            let active = modifierKeys.isSubset(of: Self.modifiersDown(flags))
            if active {
                if pressedAt == nil {
                    pressedAt = Date()
                    DispatchQueue.main.async { self.onPress?() }
                }
            } else if let p = pressedAt {
                pressedAt = nil
                let held = Date().timeIntervalSince(p)
                DispatchQueue.main.async { self.onRelease?(held) }
            }
            if modifierKeys == [63] { return nil }
            return Unmanaged.passUnretained(event)
        } else {
            guard kc == keyCode else { return Unmanaged.passUnretained(event) }
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
