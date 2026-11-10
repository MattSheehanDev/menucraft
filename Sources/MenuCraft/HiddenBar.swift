import AppKit
import SwiftUI

@MainActor
final class HiddenBarModel: ObservableObject {
    @Published var items: [MenuBarItem] = []
    @Published var images: [String: NSImage] = [:]
    @Published var hoveredID: String?
    var onActivate: (MenuBarItem) -> Void = { _ in }
}

/// The floating capsule under the menu bar that shows hidden items.
@MainActor
final class HiddenBarController {
    private static let height: CGFloat = 34

    private weak var statusBar: StatusBarController?
    private let model = HiddenBarModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<HiddenBarView>?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
        model.onActivate = { [weak statusBar] item in statusBar?.activate(item) }
    }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        guard let statusBar else { return }
        Task {
            guard let anchor = await statusBar.hiddenBarAnchor() else { return }
            let hidden = await statusBar.currentLayout().hidden
            model.items = hidden
            model.images = ItemImageCapturer.cachedImages(for: hidden)

            let panel = self.panel ?? makePanel()
            position(panel, below: anchor)
            panel.orderFrontRegardless()
            panel.invalidateShadow()
            installClickMonitor()

            // While collapsed the hidden items aren't drawn anywhere, so the cached images are all there is.
            guard statusBar.isExpanded else { return }
            let images = await ItemImageCapturer.capture(hidden) { statusBar.isExpanded }
            guard model.items == hidden else { return }
            model.images = images
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.capsuleMask(radius: Self.height / 2)

        let hosting = FirstMouseHostingView(rootView: HiddenBarView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    /// `anchor` is in Cocoa screen coordinates.
    private func position(_ panel: NSPanel, below anchor: NSRect) {
        guard let hostingView else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let width = max(hostingView.fittingSize.width, Self.height)
        let size = NSSize(width: width, height: Self.height)

        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private static func capsuleMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Lets the first click on a non-key panel hit SwiftUI buttons instead of just focusing the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct HiddenBarView: View {
    @ObservedObject var model: HiddenBarModel

    var body: some View {
        HStack(spacing: 2) {
            if model.items.isEmpty {
                Text("No hidden items. ⌘-drag icons left of the │ divider to hide them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            ForEach(model.items) { item in
                HiddenItemButton(
                    item: item,
                    image: model.images[item.id],
                    isHovering: model.hoveredID == item.id,
                    onHover: { hovering in
                        if hovering {
                            model.hoveredID = item.id
                        } else if model.hoveredID == item.id {
                            model.hoveredID = nil
                        }
                    },
                    action: { model.onActivate(item) }
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct HiddenItemButton: View {
    let item: MenuBarItem
    let image: NSImage?
    let isHovering: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuBarItemIcon(item: item, image: image)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.14 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .help(item.displayName)
    }
}

/// Shows the captured menu bar image at its natural scale, cropped to a standard bar height,
/// falling back to the owning app's icon.
struct MenuBarItemIcon: View {
    let item: MenuBarItem
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(width: image.size.width, height: 22)
                    .clipped()
            } else if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .frame(width: max(item.frame.width, 22), height: 22)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .frame(width: max(item.frame.width, 22), height: 22)
            }
        }
    }
}
