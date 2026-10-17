import Foundation
import CoreGraphics

/// 全域快捷鍵監聽：用 CGEventTap 抓每個模式各自的快捷鍵（修飾鍵組合，或修飾鍵＋一般鍵）的按下與放開。
final class HotkeyMonitor {
    var onPress: ((Mode, Shortcut) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// 設定了就進入「學習模式」，學到一組鍵就回傳，按 Esc 回傳 nil；學習中不觸發錄音
    var captureNext: ((Shortcut?) -> Void)? {
        didSet { learnOrder = []; learnPeak = [] }
    }
    /// 錄音中設成 true：按 Esc 會取消
    var escapeArmed = false
    var onEscape: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var bindings: [(shortcut: Shortcut, mode: Mode)] = []
    private var active: (shortcut: Shortcut, since: Date)?
    private var pending: DispatchWorkItem?
    private var pendingBinding: (shortcut: Shortcut, mode: Mode)?
    private var chordUsed = false
    private var learnOrder: [Int64] = []
    private var learnPeak: Set<Int64> = []
    private var debugCount = 0

    /// 修飾鍵剛按齊、但還有別組是它再多按幾顆（或再加一般鍵）的組合時，先等這麼久再決定是哪一組
    static let chordGrace: TimeInterval = 0.2

    /// 修飾鍵 keyCode → 只屬於那一顆鍵的旗標（分左右的 device bit；Fn 不分左右）
    static let modifierBits: [Int64: UInt64] = [
        56: 0x2, 60: 0x4, 59: 0x1, 62: 0x2000, 58: 0x20, 61: 0x40, 55: 0x8, 54: 0x10, 63: 0x800000,
    ]

    static func modifiersDown(_ flags: UInt64) -> Set<Int64> {
        Set(modifierBits.filter { flags & $0.value != 0 }.keys)
    }

    func configure(_ shortcuts: [Mode: [Shortcut]]) {
        bindings = Mode.allCases.flatMap { m in (shortcuts[m] ?? []).map { (shortcut: $0, mode: m) } }
        active = nil
        pending?.cancel(); pending = nil; pendingBinding = nil
        Log.w("HotkeyMonitor: configured \(bindings.map { "\($0.mode.rawValue)=\($0.shortcut.modifiers)+\($0.shortcut.key.map(String.init) ?? "-")" })")
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
        Log.w("HotkeyMonitor: started with \(bindings.count) shortcuts")
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
        let pass = Unmanaged.passUnretained(event)
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let down = Self.modifiersDown(flags)
        // 只記修飾鍵（Ctrl／Alt／Cmd 這類）的變化，絕不記一般打字的按鍵
        if type == .flagsChanged && debugCount < 20 {
            debugCount += 1
            Log.w("modifier event kc=\(kc) flags=\(String(flags, radix: 16))")
        }

        if let cap = captureNext { return learn(type: type, kc: kc, down: down, cap: cap) ? nil : pass }

        if escapeArmed && kc == 53 && (type == .keyDown || type == .keyUp) {
            if type == .keyDown { DispatchQueue.main.async { self.onEscape?() } }
            return nil
        }

        switch type {
        case .flagsChanged:
            if let a = active, a.shortcut.key == nil, !a.shortcut.modifierSet.isSubset(of: down) { release() }
            if active == nil { matchModifiers(down) }
            let fnOnly = bindings.contains { $0.shortcut.modifiers == [63] && $0.shortcut.key == nil }
            return kc == 63 && fnOnly ? nil : pass
        case .keyDown:
            // 修飾鍵剛按齊時又按了一般鍵：使用者是在打組合字（例如 ⌥＋字母），不是要錄音
            pending?.cancel(); pending = nil; pendingBinding = nil
            if let a = active { return a.shortcut.key == kc ? nil : pass }
            guard let b = bindings.first(where: { $0.shortcut.key == kc && $0.shortcut.modifierSet == down }) else { return pass }
            press(b.shortcut, b.mode)
            return nil
        case .keyUp:
            guard let a = active, a.shortcut.key == kc else { return pass }
            release()
            return nil
        default:
            return pass
        }
    }

    /// 只看修飾鍵的那幾組：按下的修飾鍵要剛好等於那一組，多按一顆都不算
    private func matchModifiers(_ down: Set<Int64>) {
        let waiting = pendingBinding
        pending?.cancel(); pending = nil; pendingBinding = nil
        // 等待期間鍵就放掉了、也沒打字：這是一次快按，要照樣觸發，不然使用者只能按住不放
        if let w = waiting, !chordUsed, !w.shortcut.modifierSet.isSubset(of: down) {
            press(w.shortcut, w.mode)
            release()
            chordUsed = !down.isEmpty
            return
        }
        if down.isEmpty { chordUsed = false }
        guard !down.isEmpty, let b = bindings.first(where: { $0.shortcut.key == nil && $0.shortcut.modifierSet == down }) else { return }
        let longerExists = bindings.contains {
            $0.shortcut.key == nil ? down.isStrictSubset(of: $0.shortcut.modifierSet) : down.isSubset(of: $0.shortcut.modifierSet)
        }
        guard longerExists else { press(b.shortcut, b.mode); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.active == nil else { return }
            self.pending = nil; self.pendingBinding = nil
            self.press(b.shortcut, b.mode)
        }
        pending = work
        pendingBinding = b
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chordGrace, execute: work)
    }

    private func press(_ s: Shortcut, _ m: Mode) {
        active = (s, Date())
        chordUsed = true
        DispatchQueue.main.async { self.onPress?(m, s) }
    }

    private func release() {
        guard let a = active else { return }
        active = nil
        let held = Date().timeIntervalSince(a.since)
        DispatchQueue.main.async { self.onRelease?(held) }
    }

    /// 學習模式。修飾鍵記下同時按住最多的那一刻，全部放開才算學到；按到一般鍵就連同當下的修飾鍵一起學。回傳 true 代表吞掉事件
    private func learn(type: CGEventType, kc: Int64, down: Set<Int64>, cap: @escaping (Shortcut?) -> Void) -> Bool {
        func finish(_ s: Shortcut?) {
            captureNext = nil
            DispatchQueue.main.async { cap(s) }
        }
        switch type {
        case .flagsChanged:
            guard Self.modifierBits[kc] != nil else {
                // Caps Lock 這類沒有 device bit 的鍵，交給上層決定要不要收
                finish(Shortcut(modifiers: [], key: kc))
                return false
            }
            if down.contains(kc) && !learnOrder.contains(kc) { learnOrder.append(kc) }
            if down.count >= learnPeak.count && !down.isEmpty { learnPeak = down }
            if down.isEmpty && !learnPeak.isEmpty { finish(Shortcut(modifiers: learnOrder.filter(learnPeak.contains), key: nil)) }
            return false
        case .keyDown:
            if kc == 53 && down.isEmpty { finish(nil); return true }
            finish(Shortcut(modifiers: learnOrder.filter(down.contains) + down.subtracting(learnOrder).sorted(), key: kc))
            return true
        default:
            return false
        }
    }
}
