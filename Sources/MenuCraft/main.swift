import AppKit

// Helper mode: reports MenuCraft's own status item frames as seen from outside the process.
// Querying our own accessibility tree in-process returns AppKit's local guess, not the real layout.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == OwnFrames.helperFlag,
   let pid = pid_t(CommandLine.arguments[2]) {
    OwnFrames.printFrames(of: pid)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
