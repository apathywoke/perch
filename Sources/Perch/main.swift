import AppKit

// Commands go to the media helper through a pipe. If the helper has just exited,
// the write must fail with an error instead of the default SIGPIPE, which would
// terminate Perch.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
