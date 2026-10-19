import AppKit
import ApplicationServices

/// Reads the text field Brainless just pasted into until the user moves on, then reports their fixes.
final class EditWatcher {
    private var timer: Timer?
    private var element: AXUIElement?
    private var inserted = ""
    private var before = ""
    private var last = ""
    private var lastChange = Date()
    private var started = Date()
    private var onDone: (([Correction]) -> Void)?

    /// Call right before pasting so `before` does not yet contain the inserted text.
    func prepare() -> (AXUIElement, String)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let el = value as! AXUIElement
        if Self.string(el, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return nil }
        guard let text = Self.string(el, kAXValueAttribute) else { return nil }
        return (el, text)
    }

    func start(element: AXUIElement, before: String, inserted: String, onDone: @escaping ([Correction]) -> Void) {
        finish()
        self.element = element
        self.before = before
        self.last = before
        self.inserted = inserted
        self.onDone = onDone
        started = Date()
        lastChange = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let el = element else { return }
        var focused: CFTypeRef?
        let stillFocused = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success
            && focused.map { CFEqual($0, el) } == true
        if stillFocused, let now = Self.string(el, kAXValueAttribute) {
            if now != last { last = now; lastChange = Date() }
        }
        let idle = Date().timeIntervalSince(lastChange)
        if !stillFocused || idle > 15 || Date().timeIntervalSince(started) > 90 { finish() }
    }

    /// Flushes the current watch; also called when a new dictation starts.
    func finish() {
        timer?.invalidate(); timer = nil
        guard let done = onDone else { return }
        onDone = nil
        element = nil
        done(CorrectionLearner.corrections(inserted: inserted, before: before, after: last))
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
