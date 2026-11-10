import AppKit

/// Owns MenuCraft's two status items:
/// - the toggle (chevron), which opens the hidden items bar
/// - the divider; everything left of it is hidden by stretching it across the free menu bar space
///
/// macOS 26+ drops a status item entirely when it can't fit, so the divider can't simply be made
/// huge: it has to be sized to overflow the free space left of it, and no more. Items left of it then
/// have no room and move into the system overflow. While they're hidden the system's « button stands
/// in for the chevron (MenuCraft intercepts its clicks) and the toggle is just an invisible spacer.
///
/// How much space macOS grants depends on the frontmost app (it reserves more than its visible menus).
/// The first fit is measured by trial; after that fits are predicted from what it taught and cached per app.
@MainActor
final class StatusBarController: NSObject {
    static let dividerID = "menucraft.divider"

    private static let expandedDividerLength: CGFloat = 14

    private let toggleItem: NSStatusItem
    private let dividerItem: NSStatusItem
    private let overflowButton = OverflowButton()
    private(set) var isExpanded = true
    /// Expanded only to click a hidden item, with MenuCraft's own items invisible.
    private var isRevealing = false
    private var isSettingsOpen = false
    /// Bumped on every expand/collapse so stale async work can tell it's been superseded.
    private var generation = 0

    /// Hidden items as of the last time they were on-screen; they're absent from the accessibility tree while hidden.
    private var hiddenItems: [MenuBarItem] = []
    /// Number of status items each app had when last expanded, to spot hidden ones that are showing.
    private var expandedItemCounts: [pid_t: Int] = [:]
    /// Measured fits, keyed by frontmost app bundle ID (each app reserves a different amount of menu space).
    private var fits: [String: Fit] = [:]
    private var fitModel = FitModel.load()
    private var isFitting = false
    private var refitAfterCurrentFit = false
    private var toggleExtraWidth: CGFloat = 0
    /// Set when no fit could hide the items; the chevron comes back so MenuCraft stays usable.
    private var hidingFailed = false
    private var lastFailedFit: Date?
    private var rehideTimer: Timer?
    private var pressTargets: [String: AXUIElement] = [:]
    private var fitTimer: Timer?
    private var didWarnAboutLayout = false

    private lazy var hiddenBar = HiddenBarController(statusBar: self)
    private lazy var settingsWindow = SettingsWindowController(statusBar: self)

    override init() {
        // New status items are inserted leftmost, so the divider starts left of the toggle.
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        dividerItem = NSStatusBar.system.statusItem(withLength: Self.expandedDividerLength)
        super.init()

        MenuBarScanner.configureTimeouts()
        toggleItem.autosaveName = "MenuCraftToggle"
        dividerItem.autosaveName = "MenuCraftDivider"

        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(toggleClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "MenuCraft: click to show hidden items, ⌥-click to expand the menu bar"
        }
        if let button = dividerItem.button {
            button.target = self
            button.action = #selector(dividerClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "MenuCraft divider: ⌘-drag icons to the left of this to hide them"
        }
        overflowButton.onClick = { [weak self] click in
            guard let self else { return }
            switch click {
            case .primary: hiddenBar.toggle()
            case .alternate: toggleExpanded()
            case .menu: showMenu()
            }
        }
        updateItems()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(frontmostAppChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.collapse()
        }
    }

    /// Where the hidden items bar hangs from, in Cocoa screen coordinates: the « while it stands in for
    /// the chevron, else the chevron. Read fresh; the toggle's NSWindow frame is AppKit's stale layout.
    func hiddenBarAnchor() async -> NSRect? {
        if toggleIsSpacer, let indicator = MenuBarScanner.overflowIndicator() {
            return indicator.frame.cocoaRect
        }
        if let toggle = await ownFrames().toggle {
            return toggle.cocoaRect
        }
        return toggleItem.button?.window?.frame
    }

    private var screen: NSScreen? {
        toggleItem.button?.window?.screen ?? NSScreen.main
    }

    // MARK: - Layout

    /// MenuCraft's divider as a menu bar item, so it can be used as a drag target. Only valid while expanded.
    private func dividerAsItem() async -> MenuBarItem? {
        guard let frame = await ownFrames().divider else { return nil }
        return MenuBarItem(
            id: Self.dividerID, pid: ProcessInfo.processInfo.processIdentifier, index: -1,
            appName: "MenuCraft", label: "Divider", frame: frame
        )
    }

    /// The divider can briefly be missing from the accessibility tree right after a relayout.
    private func locateDivider() async -> MenuBarItem? {
        for attempt in 0..<3 {
            if let divider = await dividerAsItem() { return divider }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        return nil
    }

    /// Real frames of MenuCraft's items. While expanded the divider is the narrower one; while
    /// collapsed the toggle may be narrower, but the divider is known to be left of it.
    private func ownFrames() async -> (toggle: CGRect?, divider: CGRect?) {
        let frames = await MenuBarScanner.ownItemFrames()
        guard frames.count == 2 else { return (frames.first, nil) }
        if isExpanded {
            let sorted = frames.sorted { $0.width < $1.width }
            return (sorted[1], sorted[0])
        }
        let sorted = frames.sorted { $0.minX < $1.minX }
        return (sorted[1], sorted[0])
    }

    /// Everything in the menu bar including the divider, left to right. Only complete while expanded.
    func snapshot() async -> [MenuBarItem] {
        var items = MenuBarScanner.items()
        if let divider = await locateDivider() {
            items.append(divider)
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// A snapshot in which the given items can be reached with the mouse. Items that don't fit
    /// (e.g. behind the camera housing) are in the system overflow, which is expanded to reach them.
    private func reachableSnapshot(_ ids: [String]) async -> [MenuBarItem] {
        let items = await snapshot()
        let unreachable = ids.contains { id in
            guard let item = items.first(where: { $0.id == id }) else { return true }
            return !MenuBarScanner.isClickable(item.frame)
        }
        guard unreachable, await revealOverflow() else { return items }
        return await snapshot()
    }

    private func revealOverflow() async -> Bool {
        guard let indicator = MenuBarScanner.overflowIndicator() else { return false }
        if indicator.isExpanded { return true }
        guard indicator.press() else { return false }
        try? await Task.sleep(for: .milliseconds(500))
        return true
    }

    func currentLayout() async -> MenuBarLayout {
        let items = MenuBarScanner.items()
        guard isExpanded, let divider = await locateDivider() else {
            let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            let hidden = hiddenItems.filter { running.contains($0.pid) }
            let hiddenIDs = Set(hidden.map(\.id))
            return MenuBarLayout(hidden: hidden, visible: items.filter { !hiddenIDs.contains($0.id) })
        }
        var layout = MenuBarLayout()
        for item in items {
            if item.frame.midX < divider.frame.minX {
                layout.hidden.append(item)
            } else {
                layout.visible.append(item)
            }
        }
        return layout
    }

    // MARK: - Expand / collapse

    func expand() {
        stopTimers()
        generation += 1
        isExpanded = true
        isRevealing = false
        hidingFailed = false
        dividerItem.length = Self.expandedDividerLength
        toggleExtraWidth = 0
        updateItems()
    }

    /// Brings hidden items back just long enough to click one, with MenuCraft's own items invisible
    /// and zero-width so the bar shifts as little as possible.
    private func reveal() {
        stopTimers()
        generation += 1
        isExpanded = true
        isRevealing = true
        hidingFailed = false
        dividerItem.length = 0
        toggleExtraWidth = 0
        updateItems()
    }

    /// Remembers which items are hidden (and what they look like) while they're still on-screen, then hides them.
    func collapse() {
        guard !isSettingsOpen else { return }
        if isRevealing {
            // Nothing was rearranged, so the remembered hidden items still apply.
            isRevealing = false
            generation += 1
            applyCollapsed()
            return
        }
        if isExpanded {
            generation += 1
            let token = generation
            Task {
                let frames = await ownFrames()
                if let toggle = frames.toggle, let divider = frames.divider, toggle.minX < divider.maxX {
                    warnAboutLayout()
                    return
                }
                let layout = await currentLayout()
                guard generation == token else { return }
                hiddenItems = layout.hidden
                capturePressTargets(layout.hidden)
                expandedItemCounts = Dictionary(grouping: layout.hidden + layout.visible, by: \.pid).mapValues(\.count)

                // Collapse once the icons are captured, but don't let a slow capture hold it up.
                let finish = { [weak self] in
                    guard let self, self.generation == token, self.isExpanded, !self.isSettingsOpen else { return }
                    self.applyCollapsed()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
                await ItemImageCapturer.capture(layout.hidden + layout.visible) { [weak self] in
                    guard let self else { return false }
                    return self.generation == token && self.isExpanded
                }
                finish()
            }
        } else {
            applyCollapsed()
        }
    }

    private func applyCollapsed() {
        stopTimers()
        isExpanded = false
        hidingFailed = false
        updateItems()
        if hiddenItems.isEmpty {
            dividerItem.length = Self.expandedDividerLength
            return
        }
        if let fit = fits[frontmostAppKey] {
            apply(fit)
            verifySoon()
        } else {
            Task { await fitDivider() }
        }
        fitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verifyHidden() }
        }
    }

    // MARK: - Fitting

    /// How far the divider (and, past macOS's per-item width cap, the toggle) must stretch.
    private struct Fit {
        var dividerLength: CGFloat
        var toggleExtra: CGFloat
        var total: CGFloat { dividerLength + toggleExtra }
    }

    /// Where the hiding threshold lies relative to whatever limits the status item area: the
    /// frontmost app's menus or the camera housing. Learned from a measured fit and kept across launches.
    private struct FitModel {
        /// Distance from the menus' right edge to the threshold boundary.
        var menusPad: CGFloat?
        /// Distance from the camera housing's right edge to the threshold boundary.
        var notchPad: CGFloat?
        /// Widest divider macOS was seen to keep.
        var widestKept: CGFloat?
        /// Narrowest divider macOS was seen to evict.
        var narrowestEvicted: CGFloat?

        private static let keys = (
            menus: "fitModel.menusPad", notch: "fitModel.notchPad",
            widest: "fitModel.widestKept", evicted: "fitModel.narrowestEvicted"
        )

        static func load() -> FitModel {
            let defaults = UserDefaults.standard
            func value(_ key: String) -> CGFloat? {
                defaults.object(forKey: key) == nil ? nil : CGFloat(defaults.double(forKey: key))
            }
            let plausiblePad = { (pad: CGFloat?) in pad.flatMap { (-20...200).contains($0) ? $0 : nil } }
            return FitModel(
                menusPad: plausiblePad(value(keys.menus)), notchPad: plausiblePad(value(keys.notch)),
                widestKept: value(keys.widest), narrowestEvicted: value(keys.evicted)
            )
        }

        /// macOS caps a status item's width at about half the screen; stay clear of any width seen evicted.
        func maxDividerLength(on screen: NSScreen) -> CGFloat {
            let estimate = min(screen.frame.width / 2 - 24, (narrowestEvicted ?? .infinity) - 4)
            return max(widestKept ?? 0, estimate)
        }

        func save() {
            let defaults = UserDefaults.standard
            let values = [
                (Self.keys.menus, menusPad), (Self.keys.notch, notchPad),
                (Self.keys.widest, widestKept), (Self.keys.evicted, narrowestEvicted),
            ]
            for (key, value) in values {
                if let value { defaults.set(Double(value), forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// What limits the status item area on the left right now: the menus, or the housing when the
    /// menus end well before it.
    private enum Limit {
        case menus(CGFloat)
        case notch(CGFloat)

        static func current(on screen: NSScreen?) -> Limit {
            let menusMaxX = MenuBarScanner.frontmostAppMenusMaxX()
            if let notch = screen?.notchXRange, menusMaxX < notch.lowerBound - 40 {
                return .notch(notch.upperBound)
            }
            return .menus(menusMaxX)
        }
    }

    private enum HiddenState {
        /// Every hidden item is out of the menu bar.
        case hidden
        /// Some hidden item still has room left of the divider: stretch further.
        case tooNarrow
        /// macOS dropped the divider (too wide), so hidden items are back in their usual spots.
        case evicted
    }

    private var frontmostAppKey: String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    }

    private func apply(_ fit: Fit) {
        dividerItem.length = fit.dividerLength
        setToggleExtraWidth(fit.toggleExtra)
    }

    /// Checks the real menu bar (as other processes report it) for hidden items that are showing.
    /// Items pushed into the system overflow vanish from the accessibility tree; an item still listed
    /// beyond its app's expected visible count is a hidden one. Where it sits tells why it's showing.
    private func observeHidden() -> HiddenState {
        let current = Dictionary(grouping: MenuBarScanner.items(), by: \.pid)
        var state = HiddenState.hidden
        for (pid, hidden) in Dictionary(grouping: hiddenItems, by: \.pid) {
            let expectedVisible = (expandedItemCounts[pid] ?? hidden.count) - hidden.count
            let showing = (current[pid] ?? []).filter { MenuBarScanner.isClickable($0.frame) }
            let leakedCount = showing.count - expectedVisible
            guard leakedCount > 0 else { continue }
            // Hidden items are left of the divider, so they're the app's leftmost items.
            let leaked = showing.prefix(leakedCount)
            let original = hidden.sorted { $0.frame.minX < $1.frame.minX }.suffix(leakedCount)
            let pushedLeft = zip(leaked, original).contains { $0.frame.minX < $1.frame.minX - 8 }
            if pushedLeft {
                state = .tooNarrow
            } else {
                return .evicted
            }
        }
        return state
    }

    /// Lets MenuBarAgent finish relaying out, then observes. Items briefly drop out of the
    /// accessibility tree mid-relayout, so a "hidden" reading is only trusted if it repeats.
    /// The divider must have overflowed too: if it's still laid out it's a wide blank gap that
    /// pushes the « far left, so that counts as too narrow.
    private func settledObservation(_ token: Int) async -> HiddenState? {
        try? await Task.sleep(for: .milliseconds(250))
        guard generation == token, !isExpanded else { return nil }
        let first = observeHidden()
        guard first == .hidden else { return first }
        try? await Task.sleep(for: .milliseconds(300))
        guard generation == token, !isExpanded else { return nil }
        let second = observeHidden()
        guard second == .hidden else { return second }
        let dividerShowing = await ownFrames().divider != nil
        guard generation == token, !isExpanded else { return nil }
        if dividerShowing { return .tooNarrow }
        // Hidden items always bring up the «; without it something is stretched too far.
        return MenuBarScanner.overflowIndicator() == nil ? .evicted : .hidden
    }

    /// While MenuCraft itself is frontmost (Settings), the menu bar shows no app menus to measure against.
    private var isOwnAppFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Finds a stretch that pushes every hidden item out: a prediction if the model can make one
    /// (one relayout), otherwise a search, which also teaches the model.
    private func fitDivider() async {
        guard !isFitting, !isExpanded, let screen else { return }
        if isOwnAppFrontmost {
            // Settings just closed; fit once focus is back with a real app.
            refitAfterCurrentFit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isOwnAppFrontmost else { return }
                Task { await self.fitDivider() }
            }
            return
        }
        isFitting = true
        defer {
            isFitting = false
            if refitAfterCurrentFit {
                refitAfterCurrentFit = false
                DispatchQueue.main.async { [weak self] in self?.frontmostAppChanged() }
            }
        }
        let token = generation
        if hidingFailed {
            hidingFailed = false
            updateItems()
        }

        if let predicted = await predictedFit(on: screen) {
            guard generation == token else { return }
            apply(predicted)
            let observed = await settledObservation(token)
            debugLog("fit: predicted \(Int(predicted.dividerLength))+\(Int(predicted.toggleExtra)) -> \(observed.map { "\($0)" } ?? "superseded")")
            switch observed {
            case nil: return
            case .hidden: return fitSucceeded(predicted)
            case .tooNarrow: break
            case .evicted:
                fitModel.narrowestEvicted = min(fitModel.narrowestEvicted ?? .infinity, predicted.dividerLength)
                fitModel.save()
            }
        }

        guard let measured = await searchFit(token, maxLength: screen.frame.width) else {
            if generation == token { fitFailed() }
            return
        }
        let (fit, threshold) = measured
        debugLog("fit: searched \(Int(fit.dividerLength))+\(Int(fit.toggleExtra)), threshold \(Int(threshold))")
        apply(fit)
        guard await settledObservation(token) == .hidden else {
            if generation == token { fitFailed() }
            return
        }
        await learn(threshold: threshold, on: screen)
        fitSucceeded(fit)
    }

    /// Binary-searches the smallest stretch that hides everything: the divider alone, then (past
    /// macOS's per-item width cap) the toggle too. Returns the fit with a margin, and the bare threshold.
    private func searchFit(_ token: Int, maxLength: CGFloat) async -> (Fit, threshold: CGFloat)? {
        setToggleExtraWidth(0)
        var narrow = Self.expandedDividerLength
        var wide = maxLength
        var smallestHidden: CGFloat?
        var smallestEvicted: CGFloat?
        while wide - narrow > 4 {
            let candidate = ((narrow + wide) / 2).rounded()
            dividerItem.length = candidate
            let observed = await settledObservation(token)
            if observed == .hidden || observed == .tooNarrow {
                fitModel.widestKept = max(fitModel.widestKept ?? 0, candidate)
            } else if observed == .evicted {
                fitModel.narrowestEvicted = min(fitModel.narrowestEvicted ?? .infinity, candidate)
            }
            switch observed {
            case nil: return nil
            case .hidden: smallestHidden = candidate; wide = candidate
            case .tooNarrow: narrow = candidate
            case .evicted: smallestEvicted = candidate; wide = candidate
            }
        }
        if let smallestHidden {
            let length = min(smallestHidden + Self.fitMargin, (smallestEvicted ?? .infinity) - 4)
            return (Fit(dividerLength: length, toggleExtra: 0), smallestHidden)
        }

        let length = max(narrow - 4, Self.expandedDividerLength)
        dividerItem.length = length
        var low: CGFloat = 0
        var high = maxLength / 2
        while high - low > 4 {
            let candidate = ((low + high) / 2).rounded()
            setToggleExtraWidth(candidate)
            switch await settledObservation(token) {
            case nil: return nil
            case .hidden, .evicted: high = candidate
            case .tooNarrow: low = candidate
            }
        }
        return (Fit(dividerLength: length, toggleExtra: high + Self.fitMargin), length + high)
    }

    /// A little past the minimum, so small changes in free space don't let an item back in.
    private static let fitMargin: CGFloat = 12
    /// Predictions are less certain than measurements; the usable range above the threshold is wide.
    private static let predictionMargin: CGFloat = 24

    /// The hiding threshold sits a fixed distance left of the toggle's right edge, measured from the
    /// menus (or housing); only that distance has to be learned.
    private func predictedFit(on screen: NSScreen) async -> Fit? {
        let boundary: CGFloat? = switch Limit.current(on: screen) {
        case .menus(let x): fitModel.menusPad.map { x + $0 }
        case .notch(let x): fitModel.notchPad.map { x + $0 }
        }
        guard let boundary, let toggleMaxX = await ownFrames().toggle?.maxX else { return nil }
        let total = toggleMaxX - boundary + Self.predictionMargin
        let cap = fitModel.maxDividerLength(on: screen)
        let length = max(min(total, cap), Self.expandedDividerLength)
        return Fit(dividerLength: length, toggleExtra: max(0, total - length))
    }

    private func canPredict(on screen: NSScreen?) -> Bool {
        switch Limit.current(on: screen) {
        case .menus: fitModel.menusPad != nil
        case .notch: fitModel.notchPad != nil
        }
    }

    private func learn(threshold: CGFloat, on screen: NSScreen) async {
        guard !isOwnAppFrontmost, let toggleMaxX = await ownFrames().toggle?.maxX else { return }
        let boundary = toggleMaxX - threshold
        // macOS reserves a little space past the menus; anything else is a bad measurement.
        let plausible: ClosedRange<CGFloat> = -20...200
        switch Limit.current(on: screen) {
        case .menus(let x) where x > 0 && plausible.contains(boundary - x):
            fitModel.menusPad = boundary - x
        case .notch(let x) where plausible.contains(boundary - x):
            fitModel.notchPad = boundary - x
        default:
            debugLog("fit: ignoring implausible measurement, boundary \(Int(boundary))")
            return
        }
        fitModel.save()
    }

    private func fitSucceeded(_ fit: Fit) {
        fits[frontmostAppKey] = fit
        lastFailedFit = nil
        refreshOverflowButton()
    }

    private func fitFailed() {
        lastFailedFit = Date()
        hidingFailed = true
        updateItems()
    }

    /// Re-fits when hidden items reappear (app switches change the free space, apps add items, ...).
    private func verifyHidden() {
        guard !isExpanded, !isFitting, !hiddenItems.isEmpty else { return }
        if let lastFailedFit, Date().timeIntervalSince(lastFailedFit) < 30 { return }
        // Items laid out by an expanded system overflow aren't leaks.
        if MenuBarScanner.overflowIndicator()?.isExpanded == true { return }
        if !hidingFailed, observeHidden() == .hidden {
            refreshOverflowButton()
            return
        }
        fits[frontmostAppKey] = nil
        Task { await fitDivider() }
    }

    private func verifySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.verifyHidden()
        }
    }

    @objc private func frontmostAppChanged() {
        guard !isExpanded, !hiddenItems.isEmpty, !isOwnAppFrontmost else { return }
        if isFitting {
            // The free space just changed under the fit in progress: abandon it and start over.
            generation += 1
            refitAfterCurrentFit = true
            return
        }
        if let fit = fits[frontmostAppKey] {
            apply(fit)
            verifySoon()
        } else if canPredict(on: screen) {
            // Relayout along with the menu change rather than after items have leaked.
            Task { await fitDivider() }
        } else {
            verifySoon()
        }
    }

    private func refreshOverflowButton() {
        guard toggleIsSpacer, let indicator = MenuBarScanner.overflowIndicator(), !indicator.isExpanded else {
            overflowButton.frame = nil
            return
        }
        overflowButton.frame = indicator.frame
    }

    private func stopTimers() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        fitTimer?.invalidate()
        fitTimer = nil
    }

    private func warnAboutLayout() {
        guard !didWarnAboutLayout else { return }
        didWarnAboutLayout = true
        let alert = NSAlert()
        alert.messageText = "The MenuCraft divider is on the wrong side"
        alert.informativeText = "Hold ⌘ and drag the divider (│) so it sits to the left of the MenuCraft chevron. Icons left of the divider get hidden."
        NSApp.activate()
        alert.runModal()
    }

    func scheduleRehide() {
        rehideTimer?.invalidate()
        let delay = Preferences.autoRehideDelay
        guard delay > 0 else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rehideIfIdle() }
        }
    }

    private func rehideIfIdle() {
        guard isExpanded, !isSettingsOpen else { return }
        if MenuBarScanner.isMenuOpen || mouseIsInMenuBar {
            rehideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.rehideIfIdle() }
            }
            return
        }
        collapse()
    }

    private var mouseIsInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return false }
        return mouse.y >= screen.frame.maxY - screen.menuBarHeight
    }

    // MARK: - Item actions

    /// Elements for hidden items, grabbed while they were on-screen. Many apps keep these alive
    /// after the item overflows, so pressing one opens the item without revealing anything.
    private func capturePressTargets(_ items: [MenuBarItem]) {
        pressTargets = [:]
        for item in items {
            pressTargets[item.id] = AX.pressTarget(for: item)
        }
    }

    /// Opens a hidden item without revealing it if possible; otherwise reveals it just long enough to press it.
    func activate(_ item: MenuBarItem) {
        hiddenBar.close()
        guard Permissions.accessibility else {
            Permissions.requestAccessibility()
            return
        }
        if !isExpanded, let target = pressTargets[item.id], AX.press(target) {
            debugLog("activate: pressed hidden \(item.id)")
            return
        }
        Task {
            if !isExpanded {
                await pressRevealed(item)
                return
            }
            var current = MenuBarScanner.items().first { $0.id == item.id }
            if current.map({ !MenuBarScanner.isClickable($0.frame) }) ?? true, await revealOverflow() {
                current = MenuBarScanner.items().first { $0.id == item.id }
            }
            if let current, MenuBarScanner.isClickable(current.frame) {
                debugLog("activate: clicking \(current.id) at \(current.frame)")
                await EventSimulator.click(at: CGPoint(x: current.frame.midX, y: current.frame.midY))
            } else if !AX.press(current ?? item) {
                debugLog("activate: couldn't find or press \(item.id)")
                NSSound.beep()
            }
        }
    }

    /// For items whose app discards the element when it overflows: briefly lays the hidden items
    /// out (MenuCraft's own items stay invisible), presses the item, and hides them again.
    private func pressRevealed(_ item: MenuBarItem) async {
        reveal()
        let token = generation
        var target: AXUIElement?
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(50))
            guard generation == token else { return }
            if let current = MenuBarScanner.items().first(where: { $0.id == item.id }),
               MenuBarScanner.isClickable(current.frame) {
                target = AX.pressTarget(for: current)
                break
            }
        }
        guard let target, AX.press(target) else {
            debugLog("activate: couldn't press \(item.id) after revealing")
            NSSound.beep()
            collapse()
            return
        }
        pressTargets[item.id] = target
        try? await Task.sleep(for: .milliseconds(150))
        guard generation == token else { return }
        if MenuBarScanner.isMenuOpen {
            debugLog("activate: pressed revealed \(item.id), waiting for its menu")
            collapseWhenMenuCloses()
        } else {
            debugLog("activate: pressed revealed \(item.id)")
            collapse()
        }
    }

    /// After opening a hidden item, hides the items again as soon as its menu closes, or after a
    /// few seconds if it never opened one (some items show other UI).
    private func collapseWhenMenuCloses() {
        rehideTimer?.invalidate()
        let token = generation
        var sawMenu = false
        var closedFor: TimeInterval = 0
        let interval: TimeInterval = 0.4
        rehideTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isExpanded, self.generation == token, !self.isSettingsOpen else {
                    debugLog("rehide: abandoned")
                    timer.invalidate()
                    return
                }
                if MenuBarScanner.isMenuOpen {
                    sawMenu = true
                    closedFor = 0
                    return
                }
                closedFor += interval
                if (sawMenu && closedFor >= interval) || closedFor >= 4 {
                    debugLog("rehide: collapsing (sawMenu=\(sawMenu))")
                    timer.invalidate()
                    self.collapse()
                }
            }
        }
    }

    /// Moves an item, expanding the menu bar first so both items are on-screen.
    func move(_ itemID: String, to placement: MenuBarArranger.Placement) async -> Bool {
        let wasExpanded = isExpanded && !isRevealing
        if !wasExpanded {
            expand()
            try? await Task.sleep(for: .milliseconds(400))
        }
        let ids = [itemID, placement.targetID]
        let moved = await MenuBarArranger.move(itemID, placement, snapshot: { await self.reachableSnapshot(ids) })
        if !wasExpanded {
            collapse()
        }
        return moved
    }

    func openSettings() {
        hiddenBar.close()
        settingsWindow.show()
    }

    #if DEBUG
    func debugShowHiddenBar() {
        hiddenBar.show()
    }

    /// Forgets cached fits and fits again, as if a new app had come to the front.
    func debugRefit() {
        fits = [:]
        Task { await fitDivider() }
    }

    var debugState: String {
        let model = "menusPad=\(fitModel.menusPad.map { "\(Int($0))" } ?? "-") notchPad=\(fitModel.notchPad.map { "\(Int($0))" } ?? "-") widest=\(fitModel.widestKept.map { "\(Int($0))" } ?? "-") evicted=\(fitModel.narrowestEvicted.map { "\(Int($0))" } ?? "-")"
        return "expanded=\(isExpanded) length=\(Int(dividerItem.length)) toggleExtra=\(Int(toggleExtraWidth)) toggleLength=\(Int(toggleItem.length)) failed=\(hidingFailed) overflow=\(overflowButton.frame.map { "\($0)" } ?? "-") \(model) fits=\(fits.mapValues { "\(Int($0.dividerLength))+\(Int($0.toggleExtra))" }) fitting=\(isFitting) menusMaxX=\(Int(MenuBarScanner.frontmostAppMenusMaxX())) hiddenCache=\(hiddenItems.map(\.id))"
    }
    #endif

    /// While Settings is open everything stays visible so it can be rearranged.
    func settingsDidOpen() async {
        isSettingsOpen = true
        if !isExpanded || isRevealing {
            expand()
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    func settingsDidClose() {
        isSettingsOpen = false
        collapse()
    }

    // MARK: - Clicks & menu

    @objc private func toggleClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else if event.modifierFlags.contains(.option) {
            toggleExpanded()
        } else {
            hiddenBar.toggle()
        }
    }

    @objc private func dividerClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggleExpanded()
        }
    }

    @objc private func toggleExpanded() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    @objc private func toggleHiddenBar() {
        hiddenBar.toggle()
    }

    @objc private func settingsSelected() {
        openSettings()
    }

    private func showMenu() {
        hiddenBar.close()
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Hidden Items Bar", action: #selector(toggleHiddenBar), keyEquivalent: "").target = self
        menu.addItem(withTitle: isExpanded ? "Hide Items in Menu Bar" : "Show Items in Menu Bar", action: #selector(toggleExpanded), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsSelected), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit MenuCraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        if toggleIsSpacer, let anchor = overflowButton.frame?.cocoaRect {
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY - 4), in: nil)
            return
        }
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    // MARK: - Appearance

    /// While items are hidden the system's « takes the chevron's place, so the toggle only holds space.
    private var toggleIsSpacer: Bool {
        !isExpanded && !hiddenItems.isEmpty && !hidingFailed
    }

    private func updateItems() {
        if isRevealing {
            toggleItem.length = 0
            toggleItem.button?.image = nil
            dividerItem.button?.image = nil
            overflowButton.frame = nil
            return
        }
        if toggleIsSpacer {
            toggleItem.length = toggleExtraWidth
            toggleItem.button?.image = nil
        } else {
            let thickness = NSStatusBar.system.thickness
            toggleItem.length = toggleExtraWidth > 0 ? thickness + toggleExtraWidth : NSStatusItem.squareLength
            toggleItem.button?.image = chevronImage()
            overflowButton.frame = nil
        }
        dividerItem.button?.image = isExpanded ? Self.dividerImage : nil
    }

    private func chevronImage() -> NSImage? {
        let symbol = isExpanded ? "chevron.right" : "chevron.left"
        guard let chevron = NSImage(systemSymbolName: symbol, accessibilityDescription: "MenuCraft")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        else { return nil }
        guard toggleExtraWidth > 0 else {
            chevron.isTemplate = true
            return chevron
        }
        // Keep the chevron at the right end; the extra width is blank space on the hidden side.
        let slot = NSStatusBar.system.thickness
        let size = NSSize(width: slot + toggleExtraWidth, height: max(chevron.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(
                x: rect.maxX - slot + (slot - chevron.size.width) / 2,
                y: (rect.height - chevron.size.height) / 2
            )
            chevron.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setToggleExtraWidth(_ extra: CGFloat) {
        guard extra != toggleExtraWidth else { return }
        toggleExtraWidth = extra
        updateItems()
    }

    private static let dividerImage: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1, width: 1.5, height: rect.height - 2), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
