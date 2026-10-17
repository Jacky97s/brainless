import AppKit
import ApplicationServices

/// The window a dictation started in. Text is pasted only while that window is still in front.
struct PasteTarget {
    let pid: pid_t
    let window: AXUIElement?

    /// nil when the frontmost app is Brainless itself, since there is nothing to paste back into.
    static func captureFrontmost() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return PasteTarget(pid: app.processIdentifier, window: focusedWindow(of: app.processIdentifier))
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let appElement = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Same app, and the same window whenever the start window is known.
    static func shouldPaste(
        target: PasteTarget?,
        frontPid: pid_t?,
        frontWindow: () -> AXUIElement?,
        sameWindow: (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) }
    ) -> Bool {
        guard let target = target, frontPid == target.pid else { return false }
        guard let start = target.window else { return true }
        guard let now = frontWindow() else { return false }
        return sameWindow(start, now)
    }

    static func stillFrontmost(_ target: PasteTarget?) -> Bool {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return shouldPaste(target: target, frontPid: pid, frontWindow: { pid.flatMap(focusedWindow(of:)) })
    }
}
