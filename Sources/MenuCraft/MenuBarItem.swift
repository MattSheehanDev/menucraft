import AppKit
import ApplicationServices

/// A status item in the menu bar, discovered through the accessibility API.
/// Since macOS 26 status items are drawn by MenuBarAgent rather than as per-app windows,
/// so the accessibility tree is the only reliable source of their positions.
/// `frame` is in global CoreGraphics coordinates (origin at the top-left of the primary display).
struct MenuBarItem: Identifiable, Hashable, Sendable {
    /// Stable while the item is on-screen: owning process plus its index among that process's items.
    let id: String
    let pid: pid_t
    let index: Int
    let appName: String
    let label: String
    let frame: CGRect

    var displayName: String {
        if !label.isEmpty, label != appName {
            return appName == "System" ? label : "\(appName) – \(label)"
        }
        return appName
    }

    var appIcon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }

    /// The clock is pinned to the far right by macOS.
    var isMovable: Bool { !(appName == "System" && frame.width > 100) }
}

struct MenuBarLayout: Sendable {
    /// Items left of the divider, ordered left to right.
    var hidden: [MenuBarItem] = []
    /// Items right of the divider (excluding MenuCraft's own items), ordered left to right.
    var visible: [MenuBarItem] = []
}

enum MenuBarScanner {
    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let systemHosts: Set<String> = ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.controlcenter"]

    static func configureTimeouts() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Processes recently found to have no status items; querying every process each time takes seconds.
    private static let noItemsCache = NoItemsCache()

    /// Every status item currently laid out in the menu bar (other than MenuCraft's), left to right.
    static func items() -> [MenuBarItem] {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let ext = app.bundleURL?.pathExtension ?? ""
            return app.processIdentifier != ownPID
                && ext != "xpc" && ext != "appex"
                && !noItemsCache.contains(app.processIdentifier)
        }

        let results = ResultBox(count: apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            if let found = scan(apps[i]) {
                if !found.isEmpty {
                    noItemsCache.markHasItems(apps[i].processIdentifier)
                }
                results.set(i, found)
            } else {
                noItemsCache.insert(apps[i].processIdentifier)
            }
        }
        return results.all.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Returns nil for processes that have no status items at all (as opposed to only hidden ones).
    private static func scan(_ app: NSRunningApplication) -> [MenuBarItem]? {
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = AX.attribute(element, "AXExtrasMenuBar") else { return nil }
        guard let children: [AXUIElement] = AX.attribute(bar, kAXChildrenAttribute) else { return [] }

        let isSystem = systemHosts.contains(app.bundleIdentifier ?? "")
        let appName = isSystem ? "System" : (app.localizedName ?? "Unknown")
        var items: [MenuBarItem] = []
        for (index, child) in children.enumerated() {
            guard let frame = AX.frame(of: child), frame.width > 0, frame.width < 1000 else { continue }
            if isSystem, let identifier: String = AX.attribute(child, kAXIdentifierAttribute),
               identifier.hasPrefix(overflowIndicatorID) {
                continue
            }
            // System items are hosting groups whose label is on the item inside.
            var labelled = child
            if AX.attribute(child, kAXRoleAttribute) == (kAXGroupRole as String),
               let inner: [AXUIElement] = AX.attribute(child, kAXChildrenAttribute), let first = inner.first {
                labelled = first
            }
            let title: String = AX.attribute(labelled, kAXTitleAttribute) ?? ""
            let description: String = AX.attribute(labelled, kAXDescriptionAttribute) ?? ""
            let label = (description.isEmpty ? title : description).trimmingCharacters(in: .whitespaces)
            items.append(MenuBarItem(
                id: "\(pid)#\(index)",
                pid: pid,
                index: index,
                appName: appName,
                label: label,
                frame: frame
            ))
        }
        return items
    }

    private static let overflowIndicatorID = "menu-bar-overflow-indicator"

    /// The system's « button, present while any status item has overflowed. Pressing it lays the
    /// overflowed items out over the app menus until it's pressed again (or times out).
    struct OverflowIndicator {
        let element: AXUIElement
        let frame: CGRect
        let isExpanded: Bool

        func press() -> Bool {
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }

    static func overflowIndicator() -> OverflowIndicator? {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent") {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard let bar: AXUIElement = AX.attribute(element, "AXExtrasMenuBar"),
                  let children: [AXUIElement] = AX.attribute(bar, kAXChildrenAttribute)
            else { continue }
            for child in children {
                guard let identifier: String = AX.attribute(child, kAXIdentifierAttribute),
                      identifier.hasPrefix(overflowIndicatorID),
                      let frame = AX.frame(of: child)
                else { continue }
                return OverflowIndicator(element: child, frame: frame, isExpanded: identifier.hasSuffix("expanded"))
            }
        }
        return nil
    }

    /// Frames of MenuCraft's own laid-out status items, as MenuBarAgent actually placed them.
    static func ownItemFrames() async -> [CGRect] {
        await OwnFrames.query(pid: ownPID)
    }

    /// Right edge (CG x) of the frontmost app's menus, which status items can't overlap.
    static func frontmostAppMenusMaxX() -> CGFloat {
        guard let app = NSWorkspace.shared.frontmostApplication else { return 0 }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = AX.attribute(element, kAXMenuBarAttribute),
              let menus: [AXUIElement] = AX.attribute(bar, kAXChildrenAttribute)
        else { return 0 }
        return menus.compactMap { AX.frame(of: $0)?.maxX }.max() ?? 0
    }

    /// Whether another app currently has a menu open (e.g. a status item's dropdown).
    static var isMenuOpen: Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return infos.contains {
            ($0[kCGWindowLayer as String] as? Int) == level
                && ($0[kCGWindowOwnerPID as String] as? pid_t) != ownPID
        }
    }

    /// Whether a frame is on-screen and not hidden behind the camera housing. Items left of the
    /// housing are reachable too: that's where the system lays out overflowed items when expanded.
    static func isClickable(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let region = screen.cgFrame
            guard region.contains(CGPoint(x: frame.midX, y: frame.midY)),
                  frame.minX >= region.minX, frame.maxX <= region.maxX
            else { return false }
            guard let notch = screen.notchXRange else { return true }
            return frame.maxX <= notch.lowerBound || frame.minX >= notch.upperBound
        }
    }
}

/// Our own status items' real frames can only be read from another process (NSWindow frames and
/// in-process accessibility queries both return AppKit's stale local layout), so MenuCraft re-runs
/// its own executable in a helper mode to read them.
enum OwnFrames {
    static let helperFlag = "--own-frames"

    /// Must not block the main thread: the helper's accessibility request is answered by our main thread.
    static func query(pid: pid_t) async -> [CGRect] {
        guard let executable = Bundle.main.executableURL else { return [] }
        let output: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = [helperFlag, String(pid)]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
        return output.split(separator: "\n").compactMap { line in
            let values = line.split(separator: " ").compactMap { Double($0) }
            guard values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    static func printFrames(of pid: pid_t) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let element = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = AX.attribute(element, "AXExtrasMenuBar"),
              let children: [AXUIElement] = AX.attribute(bar, kAXChildrenAttribute)
        else { return }
        for frame in children.compactMap(AX.frame(of:)) {
            print("\(frame.minX) \(frame.minY) \(frame.width) \(frame.height)")
        }
    }
}

private final class NoItemsCache: @unchecked Sendable {
    private static let lifetime: TimeInterval = 30
    private let lock = NSLock()
    private var entries: [pid_t: Date] = [:]
    /// Apps whose items all overflow lose their extras menu bar entirely, so anything that has
    /// ever had items is never treated as itemless.
    private var knownOwners: Set<pid_t> = []

    func contains(_ pid: pid_t) -> Bool {
        lock.withLock {
            guard let date = entries[pid] else { return false }
            return Date().timeIntervalSince(date) < Self.lifetime
        }
    }

    func insert(_ pid: pid_t) {
        lock.withLock {
            if !knownOwners.contains(pid) {
                entries[pid] = Date()
            }
        }
    }

    func markHasItems(_ pid: pid_t) {
        lock.withLock {
            knownOwners.insert(pid)
            entries[pid] = nil
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [[MenuBarItem]]

    init(count: Int) {
        slots = Array(repeating: [], count: count)
    }

    func set(_ index: Int, _ items: [MenuBarItem]) {
        lock.withLock { slots[index] = items }
    }

    var all: [MenuBarItem] { lock.withLock { slots.flatMap { $0 } } }
}

enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// The element to press for a status item, if it's currently in its app's extras menu bar.
    static func pressTarget(for item: MenuBarItem) -> AXUIElement? {
        let app = AXUIElementCreateApplication(item.pid)
        guard let bar: AXUIElement = attribute(app, "AXExtrasMenuBar"),
              let children: [AXUIElement] = attribute(bar, kAXChildrenAttribute),
              !children.isEmpty
        else { return nil }
        let element = children.indices.contains(item.index) ? children[item.index] : children[0]
        // Hosting-view items are groups whose first child carries the press action.
        if attribute(element, kAXRoleAttribute) == (kAXGroupRole as String),
           let inner: [AXUIElement] = attribute(element, kAXChildrenAttribute), let first = inner.first {
            return first
        }
        return element
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Presses a status item without moving the mouse.
    static func press(_ item: MenuBarItem) -> Bool {
        pressTarget(for: item).map(press) ?? false
    }
}

extension NSScreen {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// The screen's frame in global CoreGraphics coordinates.
    var cgFrame: CGRect {
        CGRect(x: frame.minX, y: Self.primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Horizontal extent (global x) of the camera housing, if this screen has one.
    var notchXRange: ClosedRange<CGFloat>? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
              left.maxX <= right.minX
        else { return nil }
        return left.maxX...right.minX
    }

    var menuBarHeight: CGFloat {
        max(frame.maxY - visibleFrame.maxY, NSStatusBar.system.thickness)
    }
}

extension NSRect {
    /// Converts a Cocoa (bottom-left origin) rect to global CoreGraphics coordinates.
    var cgRect: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }

    /// Converts a global CoreGraphics rect to Cocoa screen coordinates (the flip is its own inverse).
    var cocoaRect: NSRect { cgRect }
}
