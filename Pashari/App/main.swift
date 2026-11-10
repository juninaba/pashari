import AppKit

// Entry point of the app. A file named main.swift is the one place where Swift
// allows statements at the top level, and they run when the process starts.
//
// Pashari has no storyboard or nib, so the application object and its delegate
// are wired up by hand here.

let app = NSApplication.shared
let delegate = AppDelegate()

// `NSApplication.delegate` is a weak reference. The `delegate` constant above
// is what keeps the object alive for the lifetime of the process.
app.delegate = delegate

// Menu bar app: no Dock icon and no main menu. Info.plist says the same with
// LSUIElement; setting it here as well covers running the bare executable.
app.setActivationPolicy(.accessory)

// Starts the event loop. This call does not return until the app quits.
app.run()
