import AppKit

let application = NSApplication.shared
let applicationDelegate = AppDelegate()

application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
exit(NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv))
