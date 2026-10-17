import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 紙與兩種墨：白底黑字、一階淺灰當表面、一種灰當次要文字；藍色只給主要動作。表面之間只靠明度差，不用框線與陰影。
enum Theme {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    static let page = dyn(hex(0xffffff), hex(0x161616))
    static let surface = dyn(hex(0xf4f4f4), hex(0x222222))
    static let surfaceHi = dyn(hex(0xe9e9e9), hex(0x2e2e2e))
    static let ink = dyn(hex(0x111111), hex(0xf2f2f2))
    static let muted = dyn(hex(0x6b6b6b), hex(0x9b9b9b))
    static let accent = dyn(hex(0x1a4be0), hex(0x6b8dff))
    static let onInk = dyn(hex(0xffffff), hex(0x111111))
    /// 側邊欄固定是一塊墨色，兩種外觀都一樣
    static let sidebar = dyn(hex(0x111111), hex(0x0a0a0a))
    static let sidebarSel = dyn(hex(0x2a2a2a), hex(0x1f1f1f))
    static let sidebarMuted = Color(nsColor: hex(0x8c8c8c))
    /// 首頁舞台的色面：待命是藍，錄音中是紅
    static let stage = dyn(hex(0x1a4be0), hex(0x2a56e8))
    static let stageLive = dyn(hex(0xd8342c), hex(0xc62f28))
    static let green = Color(red: 0.16, green: 0.62, blue: 0.33)
    static let orange = Color(red: 0.90, green: 0.50, blue: 0.10)

    static let title = Font.system(size: 34, weight: .bold)
    static let heading = Font.system(size: 19, weight: .semibold)
    static let body = Font.system(size: 14)
    static let small = Font.system(size: 12)
}

/// 一塊表面：淺一階的底，沒有框線、沒有陰影
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    let content: Content
    init(padding: CGFloat = 16, @ViewBuilder _ c: () -> Content) { self.padding = padding; content = c() }
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 頁面的窄欄：標題＋內容，左對齊，最寬 620
struct Page<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    let content: Content
    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder _ c: () -> Content) { self.title = title; self.trailing = trailing; content = c() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(Theme.title)
                    Spacer()
                    trailing
                }
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 48).padding(.top, 52).padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 一節：小標＋內容
struct Block<Content: View>: View {
    let title: String
    var note: String? = nil
    let content: Content
    init(_ title: String, note: String? = nil, @ViewBuilder _ c: () -> Content) { self.title = title; self.note = note; content = c() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.heading)
            content
            if let n = note { Text(n).font(Theme.small).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// 兩端對齊的一列：左邊名稱（可帶說明），右邊值或控制項
struct Row<Trailing: View>: View {
    let label: String
    var detail: String? = nil
    let trailing: Trailing
    init(_ label: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) { self.label = label; self.detail = detail; self.trailing = trailing() }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.body)
                if let d = detail { Text(d).font(Theme.small).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// 一組列放在同一塊表面上
struct RowGroup<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct KeyChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.surfaceHi)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// 選項：選中的是實心墨色。用 Text＋點擊而不是 Button，一頁幾十個時快很多（實測每個 Button 約 0.5 ms）
struct ChoiceChip: View {
    let text: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundColor(selected ? Theme.onInk : Theme.ink)
            .background(selected ? Theme.ink : Theme.surface)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

/// 文字按鈕：次要動作，不搶主要動作的藍
struct TextAction: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) { self.title = title; self.role = role; self.action = action }
    var body: some View {
        Button(title, role: role, action: action).buttonStyle(.plain).font(Theme.small)
            .foregroundColor(role == .destructive ? Theme.orange : Theme.muted)
    }
}

/// 開關：自己畫，不用原生 Toggle（一頁五個原生開關加 Picker 實測要 20 ms）
struct Switch: View {
    let on: Bool
    let set: (Bool) -> Void
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Theme.ink : Theme.surfaceHi).frame(width: 34, height: 20)
            Circle().fill(on ? Theme.onInk : Theme.page).frame(width: 16, height: 16).padding(2)
        }
        .contentShape(Capsule())
        .onTapGesture { set(!on) }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "開" : "關")
        .accessibilityAction { set(!on) }
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View { Circle().fill(ok ? Theme.green : Theme.orange).frame(width: 7, height: 7) }
}

// MARK: - 主視窗

struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore
    @ObservedObject var dict: DictionaryStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            SwiftUI.Group {
                switch model.page {
                case .home: HomePage(model: model, history: history)
                case .history: HistoryPage(model: model, history: history)
                case .dictionary: DictionaryPage(dict: dict)
                case .settings: SettingsPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.page)
        }
        .foregroundColor(Theme.ink)
        .frame(minWidth: 860, minHeight: 600)
    }
}

struct Sidebar: View {
    @ObservedObject var model: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundColor(Theme.stage)
                Text(AppInfo.name).font(.system(size: 20, weight: .bold))
            }
            .padding(.leading, 10).padding(.top, 48).padding(.bottom, 24)
            ForEach(HubModel.Page.allCases, id: \.self) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.icon).frame(width: 18)
                    Text(p.title).font(.system(size: 14, weight: model.page == p ? .semibold : .regular))
                    Spacer()
                }
                .foregroundColor(model.page == p ? .white : Theme.sidebarMuted)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(model.page == p ? Theme.sidebarSel : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { model.page = p }
                .accessibilityAddTraits(model.page == p ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
            Text(model.privacyLine).font(Theme.small).foregroundColor(Theme.sidebarMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.bottom, 16)
        }
        .foregroundColor(.white)
        .padding(10)
        .frame(width: 210)
        .background(Theme.sidebar)
    }
}

// MARK: - 首頁

struct Heatmap: View {
    let counts: [Date: Int]
    private let weeks = 24
    private static let cal: Calendar = { var c = Calendar.current; c.firstWeekday = 1; return c }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hant"); f.dateFormat = "M月"; return f
    }()

    var body: some View {
        let cal = Self.cal
        let today = cal.startOfDay(for: Date())
        let wd = cal.component(.weekday, from: today) - 1
        let start = cal.date(byAdding: .day, value: -((weeks - 1) * 7 + wd), to: today)!
        let days: [[(date: Date, n: Int)]] = (0..<weeks).map { c in
            (0..<7).map { r in
                let d = cal.date(byAdding: .day, value: c * 7 + r, to: start)!
                return (d, counts[d] ?? 0)
            }
        }
        let months: [String] = (0..<weeks).map { c in
            guard c > 0 else { return "" }
            let m = cal.component(.month, from: days[c][0].date), pm = cal.component(.month, from: days[c - 1][0].date)
            return m != pm ? Self.monthFmt.string(from: days[c][0].date) : ""
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(0..<weeks, id: \.self) { c in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { r in
                            let day = days[c][r]
                            RoundedRectangle(cornerRadius: 3).fill(color(day.n, future: day.date > today)).frame(width: 16, height: 16)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<weeks, id: \.self) { c in
                    Text(months[c]).font(.system(size: 10)).foregroundColor(Theme.muted)
                        .lineLimit(1).fixedSize().frame(width: 16, alignment: .leading)
                }
            }
        }
    }

    private func color(_ n: Int, future: Bool) -> Color {
        if future { return .clear }
        switch n {
        case 0: return Theme.surfaceHi
        case 1...2: return Theme.stage.opacity(0.35)
        case 3...5: return Theme.stage.opacity(0.65)
        default: return Theme.stage
        }
    }
}

struct HomePage: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore
    var body: some View {
        Page("說話，不要打字") {
            if model.setupNeeded {
                SetupCard(model: model, downloader: model.downloader, puller: model.puller)
            }
            Stage(model: model)
            let days = history.countsByDay
            Block("你的數字") {
                HStack(alignment: .top, spacing: 40) {
                    figure("\(history.totalChars)", "字", "口述字數")
                    figure("\(history.savedMinutes)", "分鐘", "省下的時間")
                    figure("\(history.currentStreak)", "天", "連續天數・最長 \(history.longestStreak)")
                }
                Heatmap(counts: days).padding(.top, 12)
                Text("過去 24 週，共 \(days.count) 天有口述。平均每分鐘 \(history.charsPerMinute) 字；省下的時間以每分鐘打 60 字估算。")
                    .font(Theme.small).foregroundColor(Theme.muted)
            }
            Block("所有快捷鍵") {
                RowGroup {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Row(m.shortTitle, detail: note(for: m)) { ShortcutKeys(shortcuts: model.shortcuts[m] ?? []) }
                    }
                }
            }
            Block("引擎") {
                RowGroup {
                    Row("語音辨識", detail: model.transcriberLabel) { status(model.whisperOK, model.whisperStatus) }
                    Row("潤稿、翻譯、問任何事", detail: model.refinerLabel) { status(model.refinerOK, model.refinerStatus) }
                    if model.usesImage {
                        Row("模型磁碟映像") { status(model.volumeMounted, model.volumeMounted ? "已掛載" : "未掛載") }
                    }
                    Row("麥克風", detail: model.micName) { status(model.micStandby, model.micStandby ? "常駐中" : "休眠中") }
                }
            }
            Text("\(AppInfo.name) \(AppInfo.version)").font(Theme.small).foregroundColor(Theme.muted)
        }
    }

    private func note(for m: Mode) -> String {
        switch m {
        case .dictate: return "說話變文字"
        case .translate: return "說母語，貼出\(model.translateTarget)"
        case .ask: return "先選取文字再說指令"
        }
    }

    private func figure(_ v: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(v).font(.system(size: 44, weight: .bold)).monospacedDigit()
                Text(unit).font(.system(size: 14, weight: .medium)).foregroundColor(Theme.muted)
            }
            Text(label).font(Theme.small).foregroundColor(Theme.muted)
        }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            StatusDot(ok: ok)
            Text(text).font(Theme.small).foregroundColor(Theme.muted).lineLimit(1)
        }
    }
}

/// 首頁的舞台：一整塊色面，用大鍵帽寫出聽寫的快捷鍵，並即時反映現在在做什麼
struct Stage: View {
    @ObservedObject var model: HubModel
    var body: some View {
        let live = model.phase == "recording"
        HStack(alignment: .top, spacing: 24) {
            main(live: live)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 14) {
                ForEach([Mode.translate, .ask], id: \.self) { m in
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(m.shortTitle).font(Theme.small).foregroundColor(.white.opacity(0.7))
                        Text(model.shortcuts[m]?.first?.label ?? "未設定").font(.system(size: 15, weight: .semibold))
                    }
                }
            }
        }
        .foregroundColor(.white)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(live ? Theme.stageLive : Theme.stage)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeOut(duration: 0.2), value: model.phase)
    }

    private func main(live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(headline).font(.system(size: 15, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            if let sc = model.shortcuts[.dictate]?.first {
                HStack(spacing: 10) {
                    ForEach(sc.parts, id: \.self) { p in
                        Text(p).font(.system(size: 30, weight: .semibold))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .foregroundColor(live ? Theme.stageLive : Theme.stage)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            } else {
                Text("先到設定加一組聽寫快捷鍵").font(.system(size: 30, weight: .semibold))
            }
            Text(detail).font(Theme.body).foregroundColor(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        switch model.phase {
        case "recording": return "聆聽中"
        case "transcribing": return "辨識中…"
        case "refining": return "潤稿中…"
        case "inserting": return "貼上中…"
        case "noPermission": return "還沒有「輔助使用」權限"
        default: return "待命中"
        }
    }

    private var detail: String {
        switch model.phase {
        case "recording": return "說完再按一下結束，按 Esc 取消。"
        case "noPermission": return "到 系統設定 › 隱私權與安全性 › 輔助使用 打開 Brainless，快捷鍵才會有反應。"
        case "transcribing", "refining", "inserting": return "好了就會貼到游標所在的地方。"
        default: return "游標點到任何能打字的地方，按一下開始說話，再按一下結束。"
        }
    }
}

/// 一個模式的所有快捷鍵，每組一行
struct ShortcutKeys: View {
    let shortcuts: [Shortcut]
    var body: some View {
        if shortcuts.isEmpty {
            Text("未設定").font(Theme.small).foregroundColor(Theme.muted)
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(shortcuts, id: \.self) { sc in
                    HStack(spacing: 4) { ForEach(sc.parts, id: \.self) { KeyChip(text: $0) } }
                }
            }
        }
    }
}

// MARK: - 歷史紀錄

struct HistoryPage: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hant"); f.dateFormat = "M月d日 HH:mm"; return f
    }()
    var body: some View {
        Page("歷史紀錄", trailing: AnyView(
            HStack(spacing: 16) {
                Text("\(history.items.count) 筆").font(Theme.small).foregroundColor(Theme.muted)
                if !history.items.isEmpty { TextAction("清除全部", role: .destructive) { confirmClear = true } }
            }
        )) {
            if history.items.isEmpty {
                Text("還沒有紀錄。按一下「\(model.shortcuts[.dictate]?.first?.label ?? "快捷鍵")」說句話試試。")
                    .font(Theme.body).foregroundColor(Theme.muted)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(history.items) { it in
                        HistoryRow(item: it, model: model, history: history, dateText: Self.fmt.string(from: it.date))
                    }
                }
            }
        }
        .alert("刪除全部歷史紀錄？", isPresented: $confirmClear) {
            Button("刪除", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        } message: { Text("只會刪掉這台電腦上的紀錄，無法復原。") }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore
    let dateText: String
    @State private var showRaw = false
    @State private var copied = false
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text("\(dateText)・\(Mode(rawValue: item.mode)?.shortTitle ?? item.mode)・\(String(format: "%.0f 秒", item.seconds))")
                        .font(Theme.small).foregroundColor(Theme.muted)
                    Spacer()
                    TextAction(copied ? "已複製" : "複製") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.finalText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    if model.refinerOK { TextAction("重新潤稿") { model.onRetry?(item) } }
                    TextAction("刪除") { history.delete(item.id) }
                }
                Text(item.finalText).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let r = item.refined, !r.isEmpty, r != item.raw {
                    TextAction(showRaw ? "隱藏原始辨識" : "看原始辨識") { showRaw.toggle() }
                    if showRaw {
                        Text(item.raw).font(Theme.small).foregroundColor(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - 詞典

struct DictionaryPage: View {
    @ObservedObject var dict: DictionaryStore
    @State private var newWord = ""
    @State private var importMessage: String?
    var body: some View {
        Page("詞典", trailing: AnyView(
            HStack(spacing: 16) {
                TextAction("從 Typeless 匯入") { importTypeless() }
                TextAction("從檔案匯入…") { importFile() }
            }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text("常講的專有名詞、人名、公司名、產品名。辨識和潤稿時會優先用這些寫法，中英夾雜的詞最有效。前 30 個每次都會送給潤稿模型。")
                    .font(Theme.body).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    TextField("輸入一個詞，按 Enter 新增", text: $newWord)
                        .textFieldStyle(.plain).font(Theme.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit(add)
                    Button("新增", action: add).buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let m = importMessage { Text(m).font(Theme.small).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            if dict.words.isEmpty {
                Text("還沒有詞。例如：AEL TECH、Sketchry、ListaDAO、Typeless").font(Theme.body).foregroundColor(Theme.muted)
            } else {
                Block("\(dict.words.count) 個詞") {
                    RowGroup {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(dict.words, id: \.self) { w in
                                WordRow(word: w) { dict.remove(w) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        dict.add(newWord)
        newWord = ""
    }

    private func importTypeless() {
        switch DictionaryImport.typelessCachedTerms() {
        case .failure(let e): importMessage = e.message
        case .success(let r):
            let n = dict.addMany(r.terms)
            let when = r.cachedAt.formatted(date: .abbreviated, time: .shortened)
            importMessage = "Typeless 詞典（\(when) 的快取）共 \(r.terms.count) 個詞，新增 \(n) 個。要匯入最新的，先在 Typeless 打開詞典頁再按一次。"
            Log.w("typeless import: \(r.terms.count) terms, \(n) new")
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch DictionaryImport.terms(fromFile: url) {
        case .failure(let e): importMessage = e.message
        case .success(let terms):
            let n = dict.addMany(terms)
            importMessage = "\(url.lastPathComponent)：共 \(terms.count) 個詞，新增 \(n) 個。"
            Log.w("file import: \(terms.count) terms, \(n) new")
        }
    }
}

/// 詞典的一列：詞在左，滑過時右邊出現刪除
struct WordRow: View {
    let word: String
    let remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack {
            Text(word).font(Theme.body)
            Spacer()
            if hover { TextAction("刪除", action: remove) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { Button("刪除「\(word)」", role: .destructive, action: remove) }
    }
}

/// 流式排版：每個子 view 的大小在一次排版裡只量一次
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func makeCache(subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }
    func updateCache(_ cache: inout [CGSize], subviews: Subviews) { cache = makeCache(subviews: subviews) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sz in cache {
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for (s, sz) in zip(subviews, cache) {
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - 設定

struct SettingsPage: View {
    @ObservedObject var model: HubModel
    var body: some View {
        Page("設定") {
            if model.setupNeeded {
                SetupCard(model: model, downloader: model.downloader, puller: model.puller)
            }
            Block("快捷鍵", note: "幾顆修飾鍵一起按（左 Shift＋左 Option），或修飾鍵加一顆鍵（左 Option＋Space）都可以。按一下開始、再按一下結束。") {
                RowGroup {
                    ForEach(Mode.allCases, id: \.self) { m in ShortcutEditor(mode: m, model: model) }
                    Row("按住說話", detail: "按住超過 0.6 秒、放開就結束；關掉時一律按一下開始、再按一下結束") { toggle(model.holdToTalk) { model.onSetHoldToTalk?($0) } }
                }
            }
            SpeechEngineBlock(model: model)
            Block("翻譯成") {
                FlowLayout(spacing: 8) {
                    ForEach(Settings.translateTargets, id: \.self) { t in
                        ChoiceChip(text: t, selected: model.translateTarget == t) { model.onSetTarget?(t) }
                    }
                }
            }
            Block("辨識語言", note: "講中英夾雜建議用自動偵測。Whisper 每段錄音只猜一種語言；猜到下面名單以外的語言，就改用主要語言（名單裡有中文就是中文）重辨一次。") {
                FlowLayout(spacing: 8) {
                    ForEach(SpeechLanguage.allCases, id: \.self) { l in
                        ChoiceChip(text: l.title, selected: model.language == l) { model.onSetLanguage?(l) }
                    }
                }
                Text("自動偵測只接受").font(Theme.small).foregroundColor(Theme.muted).padding(.top, 4)
                FlowLayout(spacing: 8) {
                    ForEach(Settings.languageChoices, id: \.name) { c in
                        ChoiceChip(text: c.title, selected: model.allowedLanguages.contains(c.name)) { model.onToggleAllowedLanguage?(c.name) }
                    }
                }
            }
            Block("潤稿", note: refineNote) {
                FlowLayout(spacing: 8) {
                    ChoiceChip(text: "自動", selected: model.refineBackend.isEmpty) { model.onSetBackend?("") }
                    ForEach(RefineBackend.allCases, id: \.self) { b in
                        ChoiceChip(text: b.title + (model.installedBackends.contains(b) ? "" : "（未安裝）"), selected: model.refineBackend == b.rawValue) { model.onSetBackend?(b.rawValue) }
                    }
                }
                RowGroup {
                    Row("AI 潤稿", detail: "去贅字、補標點、轉繁體") { toggle(model.refine) { model.onSetRefine?($0) } }
                    Row("短句不潤稿", detail: "聽寫少於這個字數就直接貼，省下等 AI 的時間；代價是同音字、詞典裡的專有名詞不會被修正。翻譯與問任何事不受影響。") {
                        HStack(spacing: 6) {
                            ForEach(Settings.refineMinCharChoices, id: \.self) { n in
                                ChoiceChip(text: n == 0 ? "關" : "\(n)", selected: model.refineMinChars == n) { model.onSetRefineMinChars?(n) }
                            }
                        }
                    }
                    Row("目前使用", detail: model.refinerLabel) {
                        HStack(spacing: 6) {
                            StatusDot(ok: model.refinerOK)
                            Text(model.refinerStatus).font(Theme.small).foregroundColor(Theme.muted)
                        }
                    }
                    if model.resolvedBackend == .openai {
                        EndpointRows(url: model.remoteChatURL, modelName: model.remoteChatModel, hasKey: model.hasChatKey,
                                     urlPlaceholder: "留空用 Groq", modelPlaceholder: "留空用 \(Settings.defaultChatModel)", keyPlaceholder: "必填",
                                     onSetConfig: { model.onSetRemoteChat?($0, $1) }, onSetKey: { model.onSetChatKey?($0) })
                    } else if model.resolvedBackend != .ollama {
                        Row("模型") {
                            TextField(model.resolvedBackend == .codex ? "用 codex 預設" : "haiku", text: Binding(get: { model.agentModel }, set: { model.onSetAgentModel?($0) }))
                                .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 160)
                        }
                    } else {
                        Row("模型常駐記憶體", detail: "關掉的話閒置 30 分鐘會卸載，下次要多等十幾秒") { toggle(model.keepModelLoaded) { model.onSetKeepModelLoaded?($0) } }
                    }
                }
                if model.resolvedBackend == .openai && model.chatSendsKeyInClear && model.hasChatKey {
                    Text("這個端點不是 https，API key 會以明文傳送。").font(Theme.small).foregroundColor(Theme.muted)
                }
            }
            Block("麥克風", note: "USB 麥克風閒置幾分鐘就會被系統休眠，醒來的前兩三秒是靜音。讓通道一直開著就隨按隨有聲音；代價是選單列會一直有橘色麥克風點（沒按快捷鍵時不存、不送任何聲音）。") {
                FlowLayout(spacing: 8) {
                    ForEach(MicKeepAlive.allCases, id: \.self) { k in
                        ChoiceChip(text: k.title, selected: model.micKeepAlive == k) { model.onSetMicKeepAlive?(k) }
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(ok: model.micStandby)
                    Text("目前\(model.micStandby ? "常駐中" : "休眠中")・\(model.micName)").font(Theme.small).foregroundColor(Theme.muted)
                }
            }
            Block("其他") {
                RowGroup {
                    Row("快速辨識", detail: "短句快一倍，但準確度會掉") { toggle(model.fastWhisper) { model.onSetFastWhisper?($0) } }
                    Row("提示音") { toggle(model.sounds) { model.onSetSounds?($0) } }
                    Row("登入時自動啟動") { toggle(model.loginEnabled) { _ in model.onToggleLogin?() } }
                }
                HStack(spacing: 20) {
                    TextAction("重啟引擎") { model.onRestartEngines?() }
                    TextAction("打開記錄檔資料夾") { model.onOpenLogs?() }
                }
                .padding(.top, 4)
            }
        }
    }

    private var refineNote: String {
        switch model.resolvedBackend {
        case .ollama: return "Ollama 在這台電腦上跑模型，潤稿的文字不離開這台電腦。"
        case .openai: return "逐字稿會送到你設定的端點（\(model.chatHost.isEmpty ? "尚未設定" : model.chatHost)），不是這台電腦；API Key 存在 macOS 鑰匙圈。Groq、OpenRouter、OpenAI 或任何 OpenAI 相容的服務都可以，不會被「自動」選到。"
        case .claude, .codex: return "用本機已登入的 \(model.resolvedBackend.title) CLI 潤稿，額度算在你的帳號上。逐字稿會送到它的雲端模型；要潤稿不離開這台電腦請選 Ollama。"
        }
    }

    private func toggle(_ value: Bool, _ set: @escaping (Bool) -> Void) -> some View { Switch(on: value, set: set) }
}

/// 語音辨識跑在本機或遠端
struct SpeechEngineBlock: View {
    @ObservedObject var model: HubModel
    var body: some View {
        Block("語音辨識", note: model.speechEngine == .local
                ? "預設在這台電腦上跑 whisper.cpp。遠端要自己提供 OpenAI 相容的端點（Groq、OpenAI、speaches、whisper.cpp server 都可以）。"
                : "遠端模式下錄音會離開這台電腦，送到上面的端點；API Key 存在 macOS 鑰匙圈。「快速辨識」只在本機辨識時有用。") {
            FlowLayout(spacing: 8) {
                ChoiceChip(text: "本機", selected: model.speechEngine == .local) { model.onSetSpeechEngine?(.local) }
                ChoiceChip(text: "遠端（OpenAI 相容）", selected: model.speechEngine == .remote) { model.onSetSpeechEngine?(.remote) }
            }
            if model.speechEngine == .local {
                FlowLayout(spacing: 8) {
                    ForEach(LocalWhisperModel.allCases, id: \.self) { m in
                        ChoiceChip(text: m.title, selected: model.localWhisperModel == m) { model.onSetLocalWhisperModel?(m) }
                    }
                }
                Text("large-v3 最準，但每句要算比較久、佔 3.1 GB。large-v3-turbo 只有 1.6 GB，解碼快很多，準確度略低一點，換模型時會重啟本機引擎。")
                    .font(Theme.small).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if !model.whisperModelPresent {
                    WhisperDownloadRow(model: model, downloader: model.downloader)
                }
            }
            if model.speechEngine == .remote {
                RowGroup {
                    EndpointRows(url: model.remoteWhisperURL, modelName: model.remoteWhisperModel, hasKey: model.hasRemoteKey,
                                 urlPlaceholder: "留空用 Groq", modelPlaceholder: "留空用 \(Settings.defaultRemoteModel)", keyPlaceholder: "Groq 必填",
                                 onSetConfig: { model.onSetRemoteWhisper?($0, $1) }, onSetKey: { model.onSetRemoteKey?($0) })
                    Row("狀態") {
                        HStack(spacing: 6) {
                            StatusDot(ok: model.whisperOK)
                            Text(model.whisperStatus).font(Theme.small).foregroundColor(Theme.muted)
                                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if model.remoteSendsKeyInClear && model.hasRemoteKey {
                    Text("這個端點不是 https，API key 會以明文傳送。").font(Theme.small).foregroundColor(Theme.muted)
                }
            }
        }
    }
}

/// 選到的本機模型檔不在時的下載列；進度在 downloader 上，要自己觀察才會重繪
struct WhisperDownloadRow: View {
    @ObservedObject var model: HubModel
    @ObservedObject var downloader: ModelDownloader
    var body: some View {
        HStack(spacing: 10) {
            if downloader.running {
                ProgressView(value: downloader.progress).frame(maxWidth: 240)
                Text("下載中 \(Int(downloader.progress * 100))%").font(Theme.small).foregroundColor(Theme.muted)
            } else {
                TextAction("下載 \(model.localWhisperModel.shortName)") { model.onDownloadWhisper?() }
                if let e = downloader.error { Text(e).font(Theme.small).foregroundColor(Theme.orange) }
            }
        }
    }
}

/// 端點、模型、API Key 三列。文字欄位用草稿，送出或離開欄位才提交（打字停頓也會提交），因為每次提交都會重跑連線檢查
struct EndpointRows: View {
    let url: String
    let modelName: String
    let hasKey: Bool
    let urlPlaceholder: String
    let modelPlaceholder: String
    let keyPlaceholder: String
    let onSetConfig: (_ url: String, _ model: String) -> Void
    let onSetKey: (String) -> Void
    private enum Field { case url, model, key }
    @FocusState private var focus: Field?
    @State private var urlDraft = ""
    @State private var modelDraft = ""
    @State private var keyDraft = ""
    @State private var configTask: Task<Void, Never>?
    @State private var keyTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row("端點") {
                TextField(urlPlaceholder, text: $urlDraft)
                    .focused($focus, equals: .url).onSubmit(commitConfig)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 280)
            }
            Row("模型") {
                TextField(modelPlaceholder, text: $modelDraft)
                    .focused($focus, equals: .model).onSubmit(commitConfig)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 280)
            }
            Row("API Key") {
                HStack(spacing: 12) {
                    if hasKey && keyDraft.isEmpty {
                        TextAction("清除") { onSetKey("") }
                    }
                    SecureField(hasKey ? "已儲存" : keyPlaceholder, text: $keyDraft)
                        .focused($focus, equals: .key).onSubmit(commitKey)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 200)
                }
            }
        }
        .onAppear {
            urlDraft = url
            modelDraft = modelName
        }
        .onChange(of: focus) { old, _ in
            switch old {
            case .url, .model: commitConfig()
            case .key: commitKey()
            case nil: break
            }
        }
        .onChange(of: urlDraft) { _, _ in scheduleConfig() }
        .onChange(of: modelDraft) { _, _ in scheduleConfig() }
        .onChange(of: keyDraft) { _, _ in scheduleKey() }
        .onDisappear {
            commitConfig()
            commitKey()
        }
    }

    private func scheduleConfig() {
        configTask?.cancel()
        configTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { commitConfig() }
        }
    }

    private func scheduleKey() {
        keyTask?.cancel()
        guard !keyDraft.isEmpty else { return }
        keyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { commitKey() }
        }
    }

    private func commitConfig() {
        configTask?.cancel()
        guard urlDraft != url || modelDraft != modelName else { return }
        onSetConfig(urlDraft, modelDraft)
    }

    private func commitKey() {
        keyTask?.cancel()
        guard !keyDraft.isEmpty else { return }
        onSetKey(keyDraft)
        keyDraft = ""
    }
}

/// 一個模式的快捷鍵：列出每一組（可刪），加一組時進入學習模式
struct ShortcutEditor: View {
    let mode: Mode
    @ObservedObject var model: HubModel
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.shortTitle).font(Theme.body)
                Text(mode.title.components(separatedBy: "：").last ?? "").font(Theme.small).foregroundColor(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(model.shortcuts[mode] ?? [], id: \.self) { sc in
                    HStack(spacing: 4) {
                        ForEach(sc.parts, id: \.self) { KeyChip(text: $0) }
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.muted)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                            .onTapGesture { model.onRemoveShortcut?(mode, sc) }
                            .help("刪除這組").accessibilityLabel("刪除 \(sc.label)").accessibilityAddTraits(.isButton)
                    }
                }
                if model.learningMode == mode {
                    Text("請按下要用的鍵或組合，Esc 取消").font(Theme.small).foregroundColor(Theme.accent)
                } else {
                    TextAction(model.shortcuts[mode]?.isEmpty ?? true ? "設定快捷鍵" : "再加一組") { model.onAddShortcut?(mode) }
                        .disabled(model.learningMode != nil)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
