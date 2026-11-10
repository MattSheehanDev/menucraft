import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    #if DEBUG
    private var debugCommands: DebugCommands?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        ItemImageCapturer.prewarm()
        let controller = StatusBarController()
        statusBar = controller
        #if DEBUG
        debugCommands = DebugCommands(statusBar: controller)
        #endif
        if !Permissions.allGranted {
            controller.openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.openSettings()
        return false
    }
}
