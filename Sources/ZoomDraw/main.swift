import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement: 通过 Info.plist 设置为 true，使其作为菜单栏应用
app.setActivationPolicy(.accessory)
app.run()
