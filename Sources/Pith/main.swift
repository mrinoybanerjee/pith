import AppKit

// `NSApplication.delegate` is weak; this global keeps the delegate alive.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
