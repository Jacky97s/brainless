import Foundation

/// One dictation from key press to paste. Esc or a finished paste ends it; any callback whose job is no longer current is dropped.
final class DictationJob {
    let mode: Mode
    let target: PasteTarget?
    private var cancels: [() -> Void] = []

    init(mode: Mode, target: PasteTarget?) {
        self.mode = mode
        self.target = target
    }

    func onCancel(_ c: @escaping () -> Void) { cancels.append(c) }

    func cancel() {
        let all = cancels
        cancels = []
        all.forEach { $0() }
    }
}
