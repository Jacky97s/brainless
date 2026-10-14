import Foundation
import Combine

enum AppInfo {
    static let name = "Brainless"
    static let version = "1.0.4"
}

struct HistoryItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var seconds: Double
    var raw: String
    var refined: String?
    var mode: String
    var finalText: String { (refined?.isEmpty == false) ? refined! : raw }
}

/// 每次聽寫的紀錄，存成 JSON 檔（只在本機）
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []
    private let url = Settings.supportDir.appendingPathComponent("history.json")

    init() { load() }

    private func load() {
        guard let d = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([HistoryItem].self, from: d) else { return }
        items = arr.sorted { $0.date > $1.date }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) {
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > 5000 { items.removeLast(items.count - 5000) }
        save()
    }
    func delete(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func update(_ id: UUID, refined: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].refined = refined; save() }
    }
    func clear() { items.removeAll(); save() }

    // MARK: 統計

    static func charCount(_ s: String) -> Int {
        s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }
    var totalChars: Int { items.reduce(0) { $0 + HistoryStore.charCount($1.finalText) } }
    var totalSeconds: Double { items.reduce(0) { $0 + $1.seconds } }
    var charsPerMinute: Int { totalSeconds > 0 ? Int(Double(totalChars) / (totalSeconds / 60)) : 0 }
    /// 假設用打字要每分鐘 60 字，省下的分鐘數
    var savedMinutes: Int { max(0, Int(Double(totalChars) / 60.0 - totalSeconds / 60.0)) }

    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 1; return c }
    var countsByDay: [Date: Int] {
        var m: [Date: Int] = [:]
        for it in items { m[cal.startOfDay(for: it.date), default: 0] += 1 }
        return m
    }
    var activeDays: Int { countsByDay.count }
    var currentStreak: Int {
        let days = countsByDay
        var d = cal.startOfDay(for: Date())
        if days[d] == nil { d = cal.date(byAdding: .day, value: -1, to: d)! }
        var n = 0
        while days[d] != nil { n += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return n
    }
    var longestStreak: Int {
        let ds = countsByDay.keys.sorted()
        var best = 0, cur = 0
        var prev: Date? = nil
        for d in ds {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == d { cur += 1 } else { cur = 1 }
            best = max(best, cur); prev = d
        }
        return best
    }
}

/// 個人詞典：專有名詞、人名、公司名，會餵給 Whisper 與 Qwen
final class DictionaryStore: ObservableObject {
    @Published private(set) var words: [String] = []
    private let url = Settings.supportDir.appendingPathComponent("dictionary.json")

    init() {
        if let d = try? Data(contentsOf: url), let arr = try? JSONDecoder().decode([String].self, from: d) { words = arr }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(words) {
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    func add(_ w: String) {
        let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !words.contains(t) else { return }
        words.insert(t, at: 0); save()
    }
    func remove(_ w: String) { words.removeAll { $0 == w }; save() }

    /// 給 Whisper 的提示（有長度上限）
    var whisperHint: String {
        guard !words.isEmpty else { return "" }
        var s = ""
        for w in words { if s.count + w.count > 150 { break }; s += (s.isEmpty ? "" : "、") + w }
        return s.isEmpty ? "" : " 專有名詞：\(s)。"
    }
    /// 給 Qwen 的補充規則
    var llmHint: String {
        guard !words.isEmpty else { return "" }
        return "\n\n使用者的專有名詞清單（逐字稿若出現同音、相近或拼錯的寫法，一律改成清單裡的寫法）：\(words.prefix(200).joined(separator: "、"))"
    }
}
