import AppKit

// agent CLI 沒讀完 stdin 就結束時，寫入不該把整個 App 帶走
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
