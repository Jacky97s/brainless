import AppKit
import CoreGraphics

/// 把文字放進剪貼簿，必要時模擬 ⌘V 貼進目前游標所在的 App。
enum TextInserter {
    private static func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        let pb = NSPasteboard.general
        return (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types {
                if let d = item.data(forType: t) { dict[t] = d }
            }
            return dict
        }
    }

    private static func restorePasteboard(_ snap: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = snap.map { dict in
            let it = NSPasteboardItem()
            for (t, d) in dict { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// 結果一律留在剪貼簿，不還原舊內容，貼失敗時使用者還能自己貼。
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func pasteFromClipboard(completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postKey(9, flags: .maskCommand) // ⌘V
            completion?()
        }
    }

    /// 模擬 ⌘C 讀取目前選取的文字（讀完還原剪貼簿）
    static func readSelection(completion: @escaping (String?) -> Void) {
        let snap = snapshotPasteboard()
        let pb = NSPasteboard.general
        let before = pb.changeCount
        pb.clearContents()
        postKey(8, flags: .maskCommand) // ⌘C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let text = pb.changeCount != before ? pb.string(forType: .string) : nil
            restorePasteboard(snap)
            completion(text?.isEmpty == false ? text : nil)
        }
    }
}
