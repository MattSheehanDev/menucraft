import AppKit

/// Appends to /tmp/menucraft-debug.log in debug builds; compiled out of release builds.
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    let line = message() + "\n"
    let url = URL(fileURLWithPath: "/tmp/menucraft-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif
}

#if DEBUG

/// Lets scripts drive a debug build:
///   echo dump > /tmp/menucraft-debug.cmd && notifyutil -p com.matthewsheehan.menucraft.debug
/// Commands: expand, collapse, bar, activate, dump, hide <id>, show <id>. Output goes to /tmp/menucraft-debug.log.
@MainActor
final class DebugCommands: NSObject {
    private static let notificationName = "com.matthewsheehan.menucraft.debug"
    private static let commandFile = URL(fileURLWithPath: "/tmp/menucraft-debug.cmd")

    private weak var statusBar: StatusBarController?
    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
        super.init()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let commands = Unmanaged<DebugCommands>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { commands.received() }
                }
            },
            Self.notificationName as CFString, nil, .deliverImmediately
        )
    }

    private func received() {
        guard let statusBar,
              let command = try? String(contentsOf: Self.commandFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "expand": statusBar.expand()
        case "collapse": statusBar.collapse()
        case "bar": statusBar.debugShowHiddenBar()
        case "settings": statusBar.openSettings()
        case "activate":
            Task {
                let hidden = await statusBar.currentLayout().hidden
                let item = parts.count == 2 ? hidden.first { $0.id == parts[1] } : hidden.first
                guard let item else { return log("nothing hidden") }
                statusBar.activate(item)
            }
        case "dump": dump()
        case "refit": statusBar.debugRefit()
        case "rclickat" where parts.count == 3:
            if let x = Double(parts[1]), let y = Double(parts[2]) {
                let point = CGPoint(x: x, y: y)
                for type in [CGEventType.rightMouseDown, .rightMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right)?
                        .post(tap: .cghidEventTap)
                }
            }
        case "clickat" where parts.count == 3:
            if let x = Double(parts[1]), let y = Double(parts[2]) {
                Task { await EventSimulator.click(at: CGPoint(x: x, y: y)) }
            }
        case "odrag" where parts.count == 3:
            Task {
                let items = await statusBar.snapshot()
                guard let item = items.first(where: { $0.id == parts[1] }),
                      let target = items.first(where: { $0.id == parts[2] })
                else { return log("odrag: missing items") }
                log("odrag: \(item.id) at \(item.frame) -> left of \(target.id) \(target.frame)")
                await EventSimulator.commandDrag(
                    from: CGPoint(x: item.frame.midX, y: item.frame.midY),
                    to: CGPoint(x: target.frame.minX + 2, y: target.frame.midY)
                )
                try? await Task.sleep(for: .milliseconds(600))
                let after = await statusBar.snapshot().map { "\($0.id)@\(Int($0.frame.minX))" }
                log("odrag after: \(after)")
            }
        case "press" where parts.count == 2:
            Task {
                guard let item = await statusBar.snapshot().first(where: { $0.id == parts[1] }) else { return log("no \(parts[1])") }
                log("press \(item.id) -> \(AX.press(item))")
            }
        case "ax": axDump(bundleID: parts.count > 1 ? parts[1] : "com.apple.MenuBarAgent")
        case "hide" where parts.count == 2:
            Task { log("hide \(parts[1]) -> \(await statusBar.move(parts[1], to: .leftOf(StatusBarController.dividerID)))") }
        case "show" where parts.count == 2:
            Task { log("show \(parts[1]) -> \(await statusBar.move(parts[1], to: .rightOf(StatusBarController.dividerID)))") }
        default: log("unknown command: \(command)")
        }
    }

    private func dump() {
        guard let statusBar else { return }
        Task {
            let start = Date()
            let layout = await statusBar.currentLayout()
            let scanTime = Date().timeIntervalSince(start)
            var lines = ["\(statusBar.debugState) own=\(await MenuBarScanner.ownItemFrames()) layout=\(String(format: "%.3f", scanTime))s"]
            lines += layout.hidden.map { "  hidden  \($0.id) \($0.displayName) \($0.frame)" }
            lines += layout.visible.map { "  visible \($0.id) \($0.displayName) \($0.frame)" }
            log(lines.joined(separator: "\n"))
        }
    }

    private func axDump(bundleID: String) {
        var lines: [String] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            lines.append("app \(app.processIdentifier) attrs=\(attributeNames(element))")
            for attr in ["AXExtrasMenuBar", kAXMenuBarAttribute as String, kAXWindowsAttribute as String] {
                guard let root: AXUIElement = AX.attribute(element, attr) else { continue }
                lines.append(" \(attr):")
                describe(root, depth: 1, into: &lines)
            }
        }
        log(lines.joined(separator: "\n"))
    }

    private func describe(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth < 4 else { return }
        let keys = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXIdentifier", "AXHelp"]
        let fields = keys.compactMap { key -> String? in
            guard let value: String = AX.attribute(element, key), !value.isEmpty else { return nil }
            return "\(key.dropFirst(2))=\(value)"
        }
        let frame = AX.frame(of: element).map { "\($0)" } ?? "-"
        lines.append(String(repeating: "  ", count: depth) + fields.joined(separator: " ") + " " + frame)
        let children: [AXUIElement] = AX.attribute(element, kAXChildrenAttribute as String) ?? []
        for child in children { describe(child, depth: depth + 1, into: &lines) }
    }

    private func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        return (names as? [String]) ?? []
    }

    private func log(_ message: String) {
        debugLog(message)
    }
}
#endif
