import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()

// `NSApplication.delegate` is a weak reference. The `delegate` constant above
// is what keeps the object alive for the lifetime of the process.
app.delegate = delegate

// Menu bar app: no Dock icon, and its main menu is never shown (see MainMenu).
// Info.plist says the same with LSUIElement; setting it here as well covers
// running the bare executable.
app.setActivationPolicy(.accessory)

app.run()
