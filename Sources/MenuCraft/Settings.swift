import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private weak var statusBar: StatusBarController?
    private var window: NSWindow?

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
        model = SettingsModel(statusBar: statusBar)
    }

    func windowWillClose(_ notification: Notification) {
        // Hand focus back; an accessory app left frontmost blanks the app menus.
        NSApp.hide(nil)
        statusBar?.settingsDidClose()
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MenuCraft"
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            // Keeps the window from being resized smaller than the content needs.
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        guard let window else { return }
        let isOpening = !window.isVisible
        if isOpening {
            fitToContent(window)
            window.center()
        }
        // Cooperative activation won't take focus from the app in front, which leaves Settings buried.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task {
            await model.refresh()
            // The rows load after opening; grow to show them (keeping the title bar in place).
            if isOpening { fitToContent(window) }
        }
    }

    /// Sizes the window to its content's natural size, limited to the screen it's on.
    private func fitToContent(_ window: NSWindow) {
        guard let view = window.contentViewController?.view,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let fitting = view.fittingSize
        let content = NSSize(
            width: min(max(fitting.width, 520), visible.width - 40),
            height: min(fitting.height, visible.height - 60)
        )
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.y = max(frame.origin.y, visible.minY + 10)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    enum Row: Identifiable, Hashable {
        case item(MenuBarItem)
        case divider

        var id: String {
            switch self {
            case .item(let item): "item-\(item.id)"
            case .divider: "divider"
            }
        }
    }

    @Published var rows: [Row] = []
    @Published var images: [String: NSImage] = [:]
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var accessibilityGranted = Permissions.accessibility
    @Published var screenRecordingGranted = Permissions.screenRecording
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { updateLaunchAtLogin() }
    }

    private weak var statusBar: StatusBarController?

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    var dividerIndex: Int { rows.firstIndex(of: .divider) ?? 0 }

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibility
        screenRecordingGranted = Permissions.screenRecording
    }

    func refresh() async {
        refreshPermissions()
        guard let statusBar else { return }
        await statusBar.settingsDidOpen()
        let layout = await statusBar.currentLayout()
        rows = layout.hidden.map(Row.item) + [.divider] + layout.visible.map(Row.item)

        let items = layout.hidden + layout.visible
        images = ItemImageCapturer.cachedImages(for: items)
        images = await ItemImageCapturer.capture(items)
    }

    /// Rows are ordered left to right, so a row's new neighbours determine where to ⌘-drag the item.
    func move(from source: IndexSet, to destination: Int) {
        guard !isBusy, source.count == 1, let from = source.first,
              case .item(let item) = rows[from], item.isMovable
        else { return }

        var newRows = rows
        newRows.move(fromOffsets: source, toOffset: destination)
        guard let newIndex = newRows.firstIndex(of: rows[from]), newRows != rows else { return }

        let placement: MenuBarArranger.Placement
        if newIndex + 1 < newRows.count, let target = targetID(of: newRows[newIndex + 1]) {
            placement = .leftOf(target)
        } else if newIndex > 0, let target = targetID(of: newRows[newIndex - 1]) {
            placement = .rightOf(target)
        } else {
            return
        }

        rows = newRows
        perform(item, placement)
    }

    func toggleHidden(_ item: MenuBarItem, isHidden: Bool) {
        let divider = StatusBarController.dividerID
        perform(item, isHidden ? .rightOf(divider) : .leftOf(divider))
    }

    private func targetID(of row: Row) -> String? {
        switch row {
        case .item(let item): item.id
        case .divider: StatusBarController.dividerID
        }
    }

    private func perform(_ item: MenuBarItem, _ placement: MenuBarArranger.Placement) {
        guard let statusBar else { return }
        guard Permissions.accessibility else {
            Permissions.requestAccessibility()
            Task { await refresh() }
            return
        }
        isBusy = true
        errorMessage = nil
        Task {
            let moved = await statusBar.move(item.id, to: placement)
            if !moved {
                errorMessage = "Couldn't move \(item.displayName). Some system items can't be moved, and items behind the camera notch can't be dragged."
            }
            try? await Task.sleep(for: .milliseconds(300))
            await refresh()
            isBusy = false
        }
    }

    private func updateLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            errorMessage = "Couldn't update launch at login: \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(Preferences.autoRehideDelayKey) private var autoRehideDelay: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.accessibilityGranted && model.screenRecordingGranted {
                Label("Accessibility and Screen Recording are allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            } else {
                permissions
            }
            layoutSection
            behavior
        }
        .padding(20)
        .frame(minWidth: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var permissions: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets MenuCraft click and rearrange menu bar items.",
                    granted: model.accessibilityGranted,
                    action: Permissions.requestAccessibility
                )
                Divider()
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Lets MenuCraft show item icons in the hidden items bar. May need a relaunch after granting.",
                    granted: model.screenRecordingGranted,
                    action: Permissions.requestScreenRecording
                )
                if !model.screenRecordingGranted {
                    Button("Relaunch MenuCraft", action: Permissions.relaunch)
                        .controlSize(.small)
                }
            }
            .padding(6)
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Menu Bar Layout").font(.headline)
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
            }
            Text("Drag rows to rearrange. The top of the list is the left of the menu bar; items above the divider are hidden. All items stay visible while this window is open. You can also ⌘-drag icons directly in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    switch row {
                    case .divider:
                        DividerRow().moveDisabled(true)
                    case .item(let item):
                        let isHidden = index < model.dividerIndex
                        ItemRow(item: item, image: model.images[item.id], isHidden: isHidden, isBusy: model.isBusy) {
                            model.toggleHidden(item, isHidden: isHidden)
                        }
                        .moveDisabled(!item.isMovable || model.isBusy)
                    }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: listMinHeight)

            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// Tall enough to show every row without scrolling, within reason.
    private var listMinHeight: CGFloat {
        min(max(CGFloat(model.rows.count) * 36 + 16, 200), 500)
    }

    private var behavior: some View {
        GroupBox("Behavior") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Re-hide items revealed in the menu bar after", selection: $autoRehideDelay) {
                    Text("Never").tag(0.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                }
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Text("While items are hidden, click « to show them below the menu bar. ⌥-click it to reveal them in the menu bar itself, or right-click for more options. When nothing is hidden, MenuCraft's chevron does the same.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}

private struct ItemRow: View {
    let item: MenuBarItem
    let image: NSImage?
    let isHidden: Bool
    let isBusy: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MenuBarItemIcon(item: item, image: image)
                .frame(minWidth: 40)
            Text(item.displayName)
                .opacity(isHidden ? 0.7 : 1)
            Spacer()
            if item.isMovable {
                Button(isHidden ? "Show" : "Hide", action: toggle)
                    .controlSize(.small)
                    .disabled(isBusy)
            } else {
                Text("Fixed").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DividerRow: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Label("Hidden above · Shown below", systemImage: "eye.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.vertical, 4)
    }

    private var line: some View {
        Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1)
    }
}
