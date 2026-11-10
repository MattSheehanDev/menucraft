import AppKit
import ApplicationServices

/// Posts synthetic mouse events. All points are in global CoreGraphics coordinates.
@MainActor
enum EventSimulator {
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static let commandKey: CGKeyCode = 0x37

    private static var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func click(at point: CGPoint) async {
        let original = cursorLocation
        post(.mouseMoved, at: point)
        await pause(20)
        post(.leftMouseDown, at: point)
        await pause(40)
        post(.leftMouseUp, at: point)
        await pause(60)
        restoreCursor(to: original)
    }

    /// Performs the same ⌘-drag a user would do to rearrange menu bar items.
    static func commandDrag(from start: CGPoint, to end: CGPoint) async {
        let original = cursorLocation
        postKey(commandKey, down: true)
        post(.mouseMoved, at: start, flags: .maskCommand)
        await pause(50)
        post(.leftMouseDown, at: start, flags: .maskCommand)
        await pause(200)

        let steps = 15
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(.leftMouseDragged, at: point, flags: .maskCommand)
            await pause(16)
        }

        await pause(150)
        post(.leftMouseUp, at: end, flags: .maskCommand)
        await pause(50)
        postKey(commandKey, down: false)
        await pause(250)
        restoreCursor(to: original)
    }

    private static func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func postKey(_ key: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = down ? .maskCommand : []
        event.post(tap: .cghidEventTap)
    }

    private static func restoreCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private static func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
