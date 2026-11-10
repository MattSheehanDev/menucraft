import AppKit

/// Turns the system's « overflow button into MenuCraft's button while items are hidden: clicks on it
/// are swallowed by an event tap (so the system overflow doesn't expand) and reported instead.
@MainActor
final class OverflowButton {
    enum Click {
        case primary
        case alternate
        case menu
    }

    var onClick: (Click) -> Void = { _ in }

    /// The «'s frame in global CoreGraphics coordinates. Clicks are only intercepted while it's set.
    var frame: CGRect? {
        didSet {
            guard frame != oldValue else { return }
            if frame != nil { installTapIfNeeded() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: frame != nil) }
            if frame == nil { pendingClick = nil }
        }
    }

    private var tap: CFMachPort?
    /// Set between an intercepted mouse-down and its mouse-up, which is swallowed too.
    private var pendingClick: (up: CGEventType, click: Click)?

    private func installTapIfNeeded() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let button = Unmanaged<OverflowButton>.fromOpaque(refcon).takeUnretainedValue()
                let keep = MainActor.assumeIsolated { button.handle(type, event) }
                return keep ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Returns whether the event should continue on to the system.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap, frame != nil { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown, .rightMouseDown:
            guard let frame, frame.insetBy(dx: -2, dy: -2).contains(event.location) else { return true }
            let flags = event.flags
            let click: Click
            if type == .rightMouseDown || flags.contains(.maskControl) {
                click = .menu
            } else if flags.contains(.maskAlternate) {
                click = .alternate
            } else {
                click = .primary
            }
            pendingClick = (type == .leftMouseDown ? .leftMouseUp : .rightMouseUp, click)
            return false
        case .leftMouseUp, .rightMouseUp:
            guard let pending = pendingClick, pending.up == type else { return true }
            pendingClick = nil
            DispatchQueue.main.async { [weak self] in self?.onClick(pending.click) }
            return false
        default:
            return true
        }
    }
}
