import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Theme {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let pageBG = dyn(NSColor(white: 0.975, alpha: 1), NSColor(white: 0.11, alpha: 1))
    static let sidebarBG = dyn(NSColor(white: 0.945, alpha: 1), NSColor(white: 0.145, alpha: 1))
    static let card = dyn(.white, NSColor(white: 0.17, alpha: 1))
    static let innerBG = dyn(NSColor(white: 0.965, alpha: 1), NSColor(white: 0.14, alpha: 1))
    static let chip = dyn(.white, NSColor(white: 0.23, alpha: 1))
    static let border = dyn(NSColor(white: 0, alpha: 0.09), NSColor(white: 1, alpha: 0.12))
    static let selected = dyn(NSColor(white: 0.88, alpha: 1), NSColor(white: 0.25, alpha: 1))
    static let cell = dyn(NSColor(white: 0.90, alpha: 1), NSColor(white: 0.24, alpha: 1))
    static let accent = Color(red: 0.33, green: 0.40, blue: 0.96)
    static let green = Color(red: 0.22, green: 0.72, blue: 0.40)
    static let orange = Color(red: 0.95, green: 0.60, blue: 0.20)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    let content: Content
    init(padding: CGFloat = 20, @ViewBuilder _ c: () -> Content) { self.padding = padding; content = c() }
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct KeyChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.chip)
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

struct ChoiceChip: View {
    let text: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Theme.accent.opacity(0.14) : Theme.chip)
                .foregroundColor(selected ? Theme.accent : .primary)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// MARK: - 主視窗

struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore
    @ObservedObject var dict: DictionaryStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            ZStack(alignment: .topLeading) {
                Theme.pageBG.ignoresSafeArea()
                switch model.page {
                case .home: HomePage(model: model, history: history)
                case .history: HistoryPage(model: model, history: history)
                case .dictionary: DictionaryPage(dict: dict)
                case .settings: SettingsPage(model: model)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 660)
    }
}

struct Sidebar: View {
    @ObservedObject var model: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 18, weight: .bold))
                Text(AppInfo.name).font(.system(size: 17, weight: .bold))
                Text("本地").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.selected).cornerRadius(5)
            }
            .padding(.leading, 12).padding(.top, 44).padding(.bottom, 14)
            ForEach(HubModel.Page.allCases, id: \.self) { p in
                Button(action: { model.page = p }) {
                    HStack(spacing: 12) {
                        Image(systemName: p.icon).frame(width: 18)
                        Text(p.title).font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(model.page == p ? Theme.selected : Color.clear)
                    .cornerRadius(10)
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "lock.shield").foregroundColor(Theme.accent).font(.system(size: 18))
                Text("免登入・免訂閱・全本地").font(.system(size: 12, weight: .bold))
                Text("語音辨識與 AI 全部在本機執行，不上傳任何資料。").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card).cornerRadius(12)
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
        .padding(12)
        .frame(width: 230)
        .background(Theme.sidebarBG)
    }
}

// MARK: - 首頁

struct StatTile: View {
    let value: String
    let unit: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 40, weight: .bold))
                Text(unit).font(.system(size: 13, weight: .semibold))
            }
            Text(label).font(.system(size: 13)).foregroundColor(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card).cornerRadius(12)
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }
}

struct Heatmap: View {
    let counts: [Date: Int]
    private let weeks = 24
    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 1; return c }

    private var start: Date {
        let today = cal.startOfDay(for: Date())
        let wd = cal.component(.weekday, from: today) - 1 // 0 = Sunday
        return cal.date(byAdding: .day, value: -((weeks - 1) * 7 + wd), to: today)!
    }
    private func date(col: Int, row: Int) -> Date {
        cal.date(byAdding: .day, value: col * 7 + row, to: start)!
    }
    private func color(_ n: Int, future: Bool) -> Color {
        if future { return Color.clear }
        switch n {
        case 0: return Theme.cell
        case 1...2: return Theme.accent.opacity(0.35)
        case 3...5: return Theme.accent.opacity(0.6)
        default: return Theme.accent
        }
    }
    private func monthLabel(col: Int) -> String? {
        let d = date(col: col, row: 0)
        let m = cal.component(.month, from: d)
        if col == 0 { return nil }
        let pm = cal.component(.month, from: date(col: col - 1, row: 0))
        if m != pm {
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hant"); f.dateFormat = "M月"
            return f.string(from: d)
        }
        return nil
    }
    var body: some View {
        let today = cal.startOfDay(for: Date())
        let rowLabels = ["S", "M", "T", "W", "T", "F", "S"]
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(rowLabels[r]).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 10, height: 13)
                    }
                }
                ForEach(0..<weeks, id: \.self) { c in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { r in
                            let d = date(col: c, row: r)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(counts[d] ?? 0, future: d > today))
                                .frame(width: 13, height: 13)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Color.clear.frame(width: 10, height: 1)
                ForEach(0..<weeks, id: \.self) { c in
                    Text(monthLabel(col: c) ?? "").font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .frame(width: 13, alignment: .leading)
                }
            }
        }
    }
}

struct HomePage: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("說話，不要打字").font(.system(size: 44, weight: .bold))
                if model.setupNeeded {
                    SetupCard(model: model, downloader: model.downloader, puller: model.puller)
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("洞察").font(.system(size: 22, weight: .bold)).foregroundColor(.secondary)
                        HStack(spacing: 16) {
                            StatTile(value: "\(history.totalChars)", unit: "字", label: "口述字數")
                            StatTile(value: "\(history.savedMinutes)", unit: "分鐘", label: "節省時間")
                        }
                        HStack(spacing: 16) {
                            StatTile(value: "\(history.charsPerMinute)", unit: "每分鐘字數", label: "平均口述速度")
                            StatTile(value: "\(Int(history.totalSeconds / 60))", unit: "分鐘", label: "總口述時間")
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack(spacing: 40) {
                                    miniStat("\(history.activeDays)", "活躍天數")
                                    miniStat("\(history.currentStreak)", "當前連續天數")
                                    miniStat("\(history.longestStreak)", "最長連續天數")
                                }
                                Heatmap(counts: history.countsByDay)
                            }
                        }
                    }
                    .padding(20)
                    .background(Theme.innerBG).cornerRadius(16)
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 20) {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                shortcutRow("口述", [model.hotkey.shortLabel], note: model.mode == .dictate ? "目前模式" : "在設定裡把模式切到「聽寫」")
                                shortcutRow("翻譯", [model.hotkey.shortLabel], note: model.mode == .translate ? "目前模式，翻成\(model.translateTarget)" : "在設定裡把模式切到「翻譯」")
                                shortcutRow("問任何事", [model.hotkey.shortLabel], note: model.mode == .ask ? "目前模式，先選取文字再說" : "在設定裡把模式切到「問任何事」")
                                Divider()
                                HStack(spacing: 10) {
                                    KeyChip(text: "Esc")
                                    Text("說話時按下取消").font(.system(size: 13)).foregroundColor(.secondary)
                                }
                                Text("按一下開始、再按一下結束；按住說完放開也可以。").font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("模型狀態").font(.system(size: 15, weight: .bold))
                                modelRow(ok: model.whisperOK, title: "whisper.cpp 語音辨識", sub: "\(model.whisperModelName)・\(model.whisperStatus)")
                                modelRow(ok: model.refinerOK, title: "潤色／翻譯", sub: "\(model.refinerLabel)・\(model.refinerStatus)")
                                modelRow(ok: model.refinerOK, title: "問任何事", sub: "\(model.refinerLabel)・\(model.refinerStatus)")
                                if model.usesImage {
                                    modelRow(ok: model.volumeMounted, title: "模型磁碟映像", sub: model.volumeMounted ? "已掛載" : "未掛載，請插上外接硬碟")
                                }
                                modelRow(ok: model.micStandby, title: "麥克風", sub: "\(model.micName)・\(model.micStandby ? "常駐中" : "休眠中（\(model.micKeepAlive.shortTitle)）")")
                            }
                        }
                        HStack { Spacer(); Text("\(AppInfo.name) v\(AppInfo.version)").font(.system(size: 11)).foregroundColor(.secondary) }
                    }
                    .frame(width: 300)
                }
            }
            .padding(36)
        }
    }
    private func miniStat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(v).font(.system(size: 30, weight: .bold))
                Text("天").font(.system(size: 12, weight: .semibold))
            }
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }
    private func shortcutRow(_ title: String, _ keys: [String], note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundColor(.secondary)
            HStack(spacing: 8) { ForEach(keys, id: \.self) { KeyChip(text: $0) } }
            Text(note).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
    private func modelRow(ok: Bool, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(ok ? Theme.green : Theme.orange).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("歷史紀錄").font(.system(size: 32, weight: .bold))
                Spacer()
                Text("\(history.items.count) 筆").foregroundColor(.secondary)
                Button("清除全部") { confirmClear = true }.disabled(history.items.isEmpty)
            }
            if history.items.isEmpty {
                Card { Text("還沒有紀錄。按一下 \(model.hotkey.shortLabel) 說句話試試。").foregroundColor(.secondary) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(history.items) { it in
                            HistoryRow(item: it, model: model, history: history, dateText: HistoryPage.fmt.string(from: it.date))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(36)
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
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(dateText).font(.system(size: 12)).foregroundColor(.secondary)
                    Text(Mode(rawValue: item.mode)?.shortTitle ?? item.mode).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.selected).cornerRadius(5)
                    Text(String(format: "%.0f 秒", item.seconds)).font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Button(copied ? "已複製" : "複製") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.finalText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    Button("重新潤稿") { model.onRetry?(item) }.disabled(!model.refinerOK)
                    Button(role: .destructive) { history.delete(item.id) } label: { Image(systemName: "trash") }
                }
                Text(item.finalText).font(.system(size: 15)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let r = item.refined, !r.isEmpty, r != item.raw {
                    Button(showRaw ? "隱藏原始辨識" : "看原始辨識") { showRaw.toggle() }.buttonStyle(.link).font(.system(size: 12))
                    if showRaw {
                        Text(item.raw).font(.system(size: 13)).foregroundColor(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("詞典").font(.system(size: 32, weight: .bold))
                Spacer()
                Button("從 Typeless 匯入") { importTypeless() }
                Button("從檔案匯入…") { importFile() }
            }
            if let m = importMessage { Text(m).font(.system(size: 12)).foregroundColor(.secondary) }
            Text("把常講的專有名詞、人名、公司名、產品名放進來。辨識和潤稿時會優先用這些寫法，中英夾雜的詞最有效。")
                .foregroundColor(.secondary).font(.system(size: 13))
            HStack {
                TextField("輸入一個詞，按 Enter 新增", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { dict.add(newWord); newWord = "" }
                Button("新增") { dict.add(newWord); newWord = "" }.disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if dict.words.isEmpty {
                Card { Text("還沒有詞。例如：AEL TECH、Sketchry、ListaDAO、Typeless").foregroundColor(.secondary) }
            } else {
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(dict.words, id: \.self) { w in
                            HStack(spacing: 6) {
                                Text(w).font(.system(size: 13, weight: .medium))
                                Button { dict.remove(w) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.chip).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(36)
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

/// 簡單的流式排版（詞典標籤用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("設定").font(.system(size: 32, weight: .bold))
                section("快捷鍵") {
                    FlowLayout(spacing: 8) {
                        ForEach(HotkeyChoice.allCases.filter { $0 != .custom }, id: \.self) { h in
                            ChoiceChip(text: h.title, selected: model.hotkey == h) { model.onSetHotkey?(h) }
                        }
                        ChoiceChip(text: model.learningHotkey ? "請按下想用的鍵…" : "自訂：按下你想用的鍵", selected: model.hotkey == .custom) { model.onLearnHotkey?() }
                    }
                    Text("目前：\(model.hotkey.shortLabel)。Windows 鍵盤的 Alt 是 Option、Win 是 Command；按一下開始、再按一下結束。")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                section("模式") {
                    HStack(spacing: 8) {
                        ForEach(Mode.allCases, id: \.self) { m in
                            ChoiceChip(text: m.title, selected: model.mode == m) { model.onSetMode?(m) }
                        }
                    }
                    if model.mode == .translate {
                        HStack(spacing: 8) {
                            Text("翻譯成").font(.system(size: 13)).foregroundColor(.secondary)
                            ForEach(Settings.translateTargets, id: \.self) { t in
                                ChoiceChip(text: t, selected: model.translateTarget == t) { model.onSetTarget?(t) }
                            }
                        }
                    }
                }
                section("辨識語言") {
                    HStack(spacing: 8) {
                        ForEach(SpeechLanguage.allCases, id: \.self) { l in
                            ChoiceChip(text: l.title, selected: model.language == l) { model.onSetLanguage?(l) }
                        }
                    }
                    Text("講中英夾雜建議用自動偵測。").font(.system(size: 12)).foregroundColor(.secondary)
                    Divider()
                    Text("自動偵測只接受這些語言").font(.system(size: 13, weight: .medium))
                    FlowLayout(spacing: 8) {
                        ForEach(Settings.languageChoices, id: \.name) { c in
                            ChoiceChip(text: c.title, selected: model.allowedLanguages.contains(c.name)) { model.onToggleAllowedLanguage?(c.name) }
                        }
                    }
                    Text("Whisper 每段錄音只會猜一種語言。猜到名單外的語言（例如印地語）就自動用主要語言重辨一次。一句話裡同時混好幾種語言目前辨識不好，一次講一種最準。")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                section("麥克風保持喚醒") {
                    HStack(spacing: 8) {
                        ForEach(MicKeepAlive.allCases, id: \.self) { k in
                            ChoiceChip(text: k.title, selected: model.micKeepAlive == k) { model.onSetMicKeepAlive?(k) }
                        }
                    }
                    Text("USB 麥克風閒置幾分鐘就會被系統休眠，醒來的前兩三秒是靜音。讓通道一直開著就隨按隨有聲音；代價是選單列會一直有橘色麥克風點（App 沒按快捷鍵時不存、不送任何聲音）。")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        Circle().fill(model.micStandby ? Theme.green : Theme.orange).frame(width: 8, height: 8)
                        Text("目前：\(model.micStandby ? "常駐中" : "休眠中")・\(model.micName)")
                    }
                }
                section("行為") {
                    Toggle("AI 潤稿（\(model.refinerLabel) 去贅字、補標點、轉繁體）", isOn: Binding(get: { model.refine }, set: { model.onSetRefine?($0) }))
                    Toggle("快速辨識（短句快一倍，但準確度會掉，預設關閉）", isOn: Binding(get: { model.fastWhisper }, set: { model.onSetFastWhisper?($0) }))
                    if model.resolvedBackend == .ollama {
                        Toggle("潤稿模型常駐記憶體（關掉的話閒置 30 分鐘會卸載，下次要多等十幾秒）", isOn: Binding(get: { model.keepModelLoaded }, set: { model.onSetKeepModelLoaded?($0) }))
                    }
                    Toggle("提示音", isOn: Binding(get: { model.sounds }, set: { model.onSetSounds?($0) }))
                    Toggle("登入時自動啟動", isOn: Binding(get: { model.loginEnabled }, set: { _ in model.onToggleLogin?() }))
                }
                section("潤稿後端") {
                    FlowLayout(spacing: 8) {
                        ChoiceChip(text: "自動（偵測到的第一個）", selected: model.refineBackend.isEmpty) { model.onSetBackend?("") }
                        ForEach(RefineBackend.allCases, id: \.self) { b in
                            ChoiceChip(text: b.title + (model.installedBackends.contains(b) ? "" : "（未安裝）"), selected: model.refineBackend == b.rawValue) { model.onSetBackend?(b.rawValue) }
                        }
                    }
                    if model.resolvedBackend != .ollama {
                        HStack(spacing: 8) {
                            Text("模型").font(.system(size: 13)).foregroundColor(.secondary)
                            TextField(model.resolvedBackend == .codex ? "留空用 codex 設定檔的預設" : "例如 haiku、sonnet", text: Binding(get: { model.agentModel }, set: { model.onSetAgentModel?($0) }))
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        }
                        Text("用本機已登入的 \(model.resolvedBackend.title) CLI 潤稿，額度算在你的帳號上。錄音仍只在本機辨識，但逐字稿會送到它的雲端模型；要完全不離開這台電腦請選 Ollama。")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                section("模型") {
                    HStack(spacing: 10) { Circle().fill(model.whisperOK ? Theme.green : Theme.orange).frame(width: 8, height: 8); Text("whisper.cpp \(model.whisperModelName)：\(model.whisperStatus)") }
                    HStack(spacing: 10) { Circle().fill(model.refinerOK ? Theme.green : Theme.orange).frame(width: 8, height: 8); Text("潤稿 \(model.refinerLabel)：\(model.refinerStatus)") }
                    if model.usesImage {
                        HStack(spacing: 10) { Circle().fill(model.volumeMounted ? Theme.green : Theme.orange).frame(width: 8, height: 8); Text("模型磁碟映像：\(model.volumeMounted ? "已掛載" : "未掛載")") }
                    }
                    HStack {
                        Button("重啟引擎") { model.onRestartEngines?() }
                        Button("打開記錄檔資料夾") { model.onOpenLogs?() }
                    }
                    if model.setupNeeded {
                        SetupCard(model: model, downloader: model.downloader, puller: model.puller)
                    }
                }
            }
            .padding(36)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder _ c: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 15, weight: .bold))
                c()
            }
        }
    }
}
