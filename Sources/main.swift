import AppKit

// agent CLI 沒讀完 stdin 就結束時，寫入不該把整個 App 帶走
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)

// ⌘V／⌘C／⌘X／⌘A 是由「編輯」選單派送的；選單列 App 沒有主選單，主視窗的文字框就收不到這些快捷鍵
let editMenu = NSMenu(title: "編輯")
editMenu.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editItem = NSMenuItem()
editItem.submenu = editMenu
let mainMenu = NSMenu()
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

app.run()
