import AppKit
import SwiftUI
import TokenBarCore

enum MainStatusItemPreference {
    static let storageKey = "tokenbar.menuBar.showMainItem"

    static func isShown(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }
}

/// One deliberate AppKit rendering path for every individual status item. The
/// status-bar button keeps ownership of highlighting and placement; this type
/// owns only the icon scale and typographic hierarchy.
@MainActor
enum ClientStatusItemRenderer {
    static let iconSize: CGFloat = 16

    private static let titleGap = "\u{2009}"
    fileprivate static let stackedHorizontalInset: CGFloat = 3
    fileprivate static let stackedIconTextGap: CGFloat = 2
    private static let stackedTextTrailingInkSafety: CGFloat = 1.5
    private static let stackedContentIdentifier = NSUserInterfaceItemIdentifier(
        "tokenbar.client-status.stacked-content")

    struct Content {
        let title: NSAttributedString
        let stacked: Stacked?

        var isMultiline: Bool { stacked != nil }
    }

    struct Stacked {
        let percent: String
        let reset: String
        let textWidth: CGFloat
    }

    static func content(for presentation: ClientTray.Presentation) -> Content {
        guard let reset = presentation.compactResetText else {
            return Content(
                title: attributed(
                    titleGap + presentation.valueText,
                    font: .monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize, weight: .semibold)),
                stacked: nil)
        }

        switch presentation.layout {
        case .stacked:
            return stacked(percent: presentation.valueText, reset: reset)
        case .inline:
            return inline(percent: presentation.valueText, reset: reset)
        }
    }

    static func preferredItemLength(for content: Content) -> CGFloat? {
        guard let stacked = content.stacked else { return nil }
        return stackedHorizontalInset * 2 + iconSize + stackedIconTextGap + stacked.textWidth
    }

    /// Applies both halves of an item presentation together. In stacked mode
    /// the icon is intentionally hosted in a subview, so its source image must
    /// be supplied on every update rather than inferred from button.image.
    static func apply(_ content: Content, image: NSImage, to button: NSStatusBarButton) {
        if content.isMultiline {
            applyStacked(content, image: image, to: button)
        } else {
            removeStackedOverlay(from: button)
            button.image = image
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleNone
            button.cell?.wraps = false
            button.cell?.lineBreakMode = .byClipping
            button.attributedTitle = content.title
        }
    }

    /// Stacked content is an explicit AppKit layout. The button retains click,
    /// highlighting, placement, and independent status-item reordering.
    private static func applyStacked(
        _ content: Content, image: NSImage, to button: NSStatusBarButton
    ) {
        guard let stacked = content.stacked else { return }
        button.image = nil
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.cell?.wraps = false
        button.cell?.lineBreakMode = .byClipping
        button.attributedTitle = NSAttributedString()
        button.layoutSubtreeIfNeeded()

        let visual = stackedContent(in: button) ?? makeStackedContent()
        if visual.superview == nil { button.addSubview(visual) }
        visual.frame = button.bounds
        visual.configure(image: image, stacked: stacked)
        visual.layoutSubtreeIfNeeded()
    }

    private static func stackedContent(in button: NSStatusBarButton) -> ClientStatusItemStackedContentView? {
        button.subviews.first {
            $0.identifier == stackedContentIdentifier
        } as? ClientStatusItemStackedContentView
    }

    private static func removeStackedOverlay(from button: NSStatusBarButton) {
        if let visual = stackedContent(in: button) {
            button.image = visual.providerImage
            visual.removeFromSuperview()
        }
    }

    /// The rendered icon is in the button for inline items and in the custom
    /// overlay for stacked items. The overlay is authoritative while stacked
    /// content is active, regardless of AppKit's status-button image state.
    static func providerImage(on button: NSStatusBarButton) -> NSImage? {
        stackedContent(in: button)?.providerImage ?? button.image
    }

    private static func makeStackedContent() -> ClientStatusItemStackedContentView {
        let visual = ClientStatusItemStackedContentView(frame: .zero)
        visual.identifier = stackedContentIdentifier
        visual.autoresizingMask = [.width, .height]
        return visual
    }

    private static func stacked(percent: String, reset: String) -> Content {
        let percentWidth = NSAttributedString(
            string: percent,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)]
        ).size().width
        let resetWidth = NSAttributedString(
            string: reset,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)]
        ).size().width
        return Content(
            title: NSAttributedString(),
            stacked: Stacked(
                percent: percent,
                reset: reset,
                textWidth: ceil(max(percentWidth, resetWidth)) + stackedTextTrailingInkSafety))
    }

    private static func inline(percent: String, reset: String) -> Content {
        let value = NSMutableAttributedString(
            string: titleGap + percent,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        value.append(NSAttributedString(
            string: " \u{00B7} ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        value.append(NSAttributedString(
            string: reset,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        return Content(title: value, stacked: nil)
    }

    private static func attributed(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
    }
}

/// A non-interactive visual layer inside the status button. Each label is laid
/// out from the button's actual bounds, so the two-line group is centered as a
/// single unit instead of inheriting title-cell baselines.
final class ClientStatusItemStackedContentView: NSView {
    struct Geometry {
        let icon: NSRect
        let percent: NSRect
        let reset: NSRect

        var textBlock: NSRect { percent.union(reset) }
        var content: NSRect { icon.union(textBlock) }
    }
    private static let labelHeight: CGFloat = 13
    private static let lineAdvance: CGFloat = 9.5
    private let icon = NSImageView()
    private let percent = NSTextField(labelWithString: "")
    private let reset = NSTextField(labelWithString: "")
    private var textWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleNone
        for label in [percent, reset] {
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        percent.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        reset.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        percent.textColor = .labelColor
        reset.textColor = .labelColor
        icon.setAccessibilityElement(false)
        addSubview(icon)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    var providerImage: NSImage? { icon.image }
    var geometry: Geometry {
        Geometry(icon: icon.frame, percent: percent.frame, reset: reset.frame)
    }

    func configure(image: NSImage, stacked: ClientStatusItemRenderer.Stacked) {
        icon.image = image
        percent.stringValue = stacked.percent
        reset.stringValue = stacked.reset
        textWidth = stacked.textWidth
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textX = ClientStatusItemRenderer.stackedHorizontalInset
            + ClientStatusItemRenderer.iconSize
            + ClientStatusItemRenderer.stackedIconTextGap
        let textTop = (bounds.height - (Self.labelHeight + Self.lineAdvance)) / 2
        icon.frame = NSRect(
            x: ClientStatusItemRenderer.stackedHorizontalInset,
            y: (bounds.height - ClientStatusItemRenderer.iconSize) / 2,
            width: ClientStatusItemRenderer.iconSize,
            height: ClientStatusItemRenderer.iconSize)
        percent.frame = NSRect(
            x: textX, y: textTop, width: textWidth, height: Self.labelHeight)
        reset.frame = NSRect(
            x: textX, y: textTop + Self.lineAdvance,
            width: textWidth, height: Self.labelHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Owns the NSStatusItem and its NSPopover (AppKit-hosted icon, SwiftUI
/// popover content — the codexbar pattern). Later phases talk to it through
/// `updateTitle(_:)` and `showPopover()`.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    /// Source of truth for the popover's (user-adjustable) height.
    let chrome = PopoverChrome()
    private var defaultsObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var host: NSHostingController<AnyView>?
    private var animationSurface: StatusItemAnimationSurface?
    private var hasPresentedIcon = false
    private var clientStatusItems: [String: NSStatusItem] = [:]
    private var clientStatusImages: [String: NSImage] = [:]
    private let routeMemory: StatusItemRouteMemory
    private var popoverAnchorIdentity: String?

    override init() {
        let defaults = UserDefaults.standard
        routeMemory = StatusItemRouteMemory(
            mainClient: defaults.string(forKey: ClientTray.activeTabKey)
                ?? ClientTray.overviewTab,
            mainView: defaults.string(forKey: ClientTray.activeViewKey)
                ?? AppView.overview.rawValue)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        let host = NSHostingController(rootView: AnyView(PopoverView(routeMemory: routeMemory).environmentObject(chrome)))
        self.host = host
        // The SwiftUI root has a fixed frame; let the popover keep our size
        // instead of chasing intrinsic-size updates. The real size is set per
        // open in showPopover() against the status item's actual screen.
        host.sizingOptions = []
        popover.contentSize = NSSize(width: chrome.width, height: chrome.minHeight)
        popover.contentViewController = host

        // Swap the live UI for a placeholder when the popover closes for any
        // reason (transient outside-click, Esc, programmatic close) — mirrors
        // the SettingsWindowController pattern. Without this, PopoverView's
        // .task loops run for the process lifetime because the hosting
        // controller persists across transient open/close cycles.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // didCloseNotification fires on a later runloop turn (after the
                // ~200ms close animation), by which point a fast close→reopen
                // may already have reinstalled the live view. Re-check on the
                // next turn and only blank if the popover is still closed, so a
                // reopen that landed meanwhile isn't swapped to the placeholder.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.popover.isShown else { return }
                    self.popoverAnchorIdentity = nil
                    self.host?.rootView = AnyView(
                        Color.clear.frame(width: self.chrome.width, height: self.chrome.minHeight))
                }
            }
        }

        // The chrome model drives the popover window from three inputs: the
        // bottom drag handle, the settings slider, and the screen-size resolve.
        chrome.onResize = { [weak popover] height, live in
            guard let popover else { return }
            popover.animates = !live // 1:1 tracking mid-drag; animate otherwise
            popover.contentSize = NSSize(width: PopoverChrome.width, height: height)
        }
        // The settings window's slider writes the height default from another
        // window — mirror it onto a live popover.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // macOS can post this synchronously from registerDefaults() while
            // SwiftUI is laying out a newly opened popover. Resizing in that
            // AttributeGraph transaction aborts the process, so apply the
            // value-gated reload on the next main-queue turn.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.chrome.reloadFromDefaults() }
            }
        }

        if let button = statusItem.button {
            let placeholder = NSImage(size: .zero)
            placeholder.isTemplate = true
            placeholder.accessibilityDescription = "TokenBar"
            button.image = placeholder
            button.imagePosition = .imageLeft
            button.toolTip = "TokenBar"
            button.setAccessibilityLabel("TokenBar")
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Right-click opens the quota-source menu (battery-icon pattern).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            animationSurface = StatusItemAnimationSurface(button: button)
        }
        statusItem.isVisible = MainStatusItemPreference.isShown(defaults: defaults)
    }

    /// Supplies the latest quota payload for the right-click menu
    /// (AppDelegate wires this to the tray animator's cache).
    var quotaPayloadProvider: (() -> AgentUsagePayload?)?

    func setAnimatedFrames(_ frames: [NSImage], speed: Float) {
        guard !frames.isEmpty else {
            showFallbackIconIfNeeded()
            return
        }
        hasPresentedIcon = true
        animationSurface?.showAnimated(frames: frames, speed: speed)
    }

    func setAnimationSpeed(_ speed: Float) {
        animationSurface?.setSpeed(speed)
    }

    func setStaticIcon(_ image: NSImage, isTemplate: Bool) {
        hasPresentedIcon = true
        animationSurface?.showStatic(image, isTemplate: isTemplate)
    }

    func stopTrayAnimation() {
        animationSurface?.stopAnimation()
    }

    func setAppearanceChangeHandler(_ handler: (() -> Void)?) {
        animationSurface?.onAppearanceChange = handler
    }

    private func showFallbackIconIfNeeded() {
        guard !hasPresentedIcon,
              let image = NSImage(
                  systemSymbolName: "chart.bar.fill",
                  accessibilityDescription: "TokenBar")
        else { return }
        setStaticIcon(image, isTemplate: true)
    }

    /// Whether the menu bar around the item renders dark (picks the white
    /// frame set over the black one). Status-item buttons report *vibrant*
    /// appearances (NSAppearanceNameVibrantDark), which bestMatch against
    /// [.darkAqua, .aqua] misses — match on the name instead.
    var isDarkAppearance: Bool {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.name.rawValue.localizedCaseInsensitiveContains("dark")
    }

    private var lastTitleKey = ""

    /// Sets the text shown next to the menu-bar icon ("" = icon only). A
    /// color (the quota gauge) renders as an attributed title.
    func updateTitle(_ title: String, color: NSColor? = nil) {
        guard let button = statusItem.button else { return }
        // Leading space keeps a gap between the template icon and the text.
        let value = title.isEmpty ? "" : " \(title)"
        let key = "\(value)|\(color?.description ?? "")"
        if key != lastTitleKey {
            lastTitleKey = key
            if let color, !value.isEmpty {
                button.attributedTitle = NSAttributedString(
                    string: value,
                    attributes: [
                        .font: NSFont.menuBarFont(ofSize: 0),
                        .foregroundColor: color,
                    ])
            } else {
                button.title = value
            }
        }
        button.imagePosition = value.isEmpty ? .imageOnly : .imageLeft
        animationSurface?.scheduleLayout()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        guard !popover.isShown else { return }
        let current = persistedRoute()
        applyRoute(routeMemory.activateMain(
            currentClient: current.clientId, currentView: current.view))
        presentPopover(from: button, identity: "main")
    }

    private func persistedRoute() -> StatusItemRouteMemory.Route {
        let defaults = UserDefaults.standard
        return StatusItemRouteMemory.Route(
            clientId: defaults.string(forKey: ClientTray.activeTabKey)
                ?? ClientTray.overviewTab,
            view: defaults.string(forKey: ClientTray.activeViewKey)
                ?? AppView.overview.rawValue)
    }

    private func applyRoute(_ route: StatusItemRouteMemory.Route) {
        UserDefaults.standard.set(route.clientId, forKey: ClientTray.activeTabKey)
        UserDefaults.standard.set(route.view, forKey: ClientTray.activeViewKey)
    }

    func closePopover() {
        popoverAnchorIdentity = nil
        popover.performClose(nil)
    }

    func setMainItemVisible(_ isVisible: Bool) {
        guard statusItem.isVisible != isVisible else { return }
        if !isVisible, popoverAnchorIdentity == "main" {
            closePopover()
        }
        statusItem.isVisible = isVisible
    }

    private func presentPopover(from button: NSStatusBarButton, identity: String) {
        guard !popover.isShown else { return }
        // Reinstall the live PopoverView so its .task loops start fresh
        // (the previous close swapped it for a static placeholder).
        host?.rootView = AnyView(PopoverView(routeMemory: routeMemory).environmentObject(chrome))
        // Size against the screen the status item actually lives on (reliable,
        // unlike NSScreen.main at launch with no key window) every time we open.
        let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        chrome.resolve(visibleHeight: visible)
        // Accessory apps are never frontmost; activate so the transient
        // popover gets key status and closes on outside clicks.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverAnchorIdentity = identity
    }

    private func reanchorPopover(to button: NSStatusBarButton, identity: String) {
        guard popover.isShown else {
            presentPopover(from: button, identity: identity)
            return
        }
        // Re-clamp against the DESTINATION item's screen before moving: a height
        // the user chose on a taller display would otherwise stay taller than a
        // shorter display's visible frame and leave the popover clipped. Same
        // resolve the normal presentation path does.
        let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        chrome.resolve(visibleHeight: visible)
        // NSPopover supports changing the relative anchor while shown. Keep the
        // live host and Dashboard tasks intact; only the native anchor moves.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverAnchorIdentity = identity
    }

    func reconcileClientItems(_ presentations: [ClientTray.Presentation]) {
        let ordered = presentations.sorted { $0.clientId < $1.clientId }
        let next = Dictionary(uniqueKeysWithValues: ordered.map { ($0.clientId, $0) })

        for id in Array(clientStatusItems.keys) where next[id] == nil {
            removeClientItem(id)
        }
        for presentation in ordered {
            if let item = clientStatusItems[presentation.clientId] {
                updateClientItem(item, presentation: presentation)
            } else if !createClientItem(presentation) {
                continue
            }
        }
    }

    private func createClientItem(_ presentation: ClientTray.Presentation) -> Bool {
        guard clientImage(for: presentation.clientId) != nil else { return false }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = presentation.autosaveName
        clientStatusItems[presentation.clientId] = item
        updateClientItem(item, presentation: presentation)
        return true
    }

    /// Resolves on every reconciliation. `statusItemImage` caches its static
    /// 1x/2x renderings, while this controller cache preserves a successfully
    /// created shell if resource resolution ever transiently fails later.
    private func clientImage(for clientId: String) -> NSImage? {
        if let image = AgentIconView.statusItemImage(
            clientId: clientId, size: ClientStatusItemRenderer.iconSize)
        {
            clientStatusImages[clientId] = image
            return image
        }
        return clientStatusImages[clientId]
    }

    private func updateClientItem(_ item: NSStatusItem, presentation: ClientTray.Presentation) {
        guard let button = item.button else { return }
        let imageBeforeUpdate = ClientStatusItemRenderer.providerImage(on: button)
        guard let image = clientImage(for: presentation.clientId) else {
#if DEBUG
            print("[TokenBar DEBUG] client status item image resolution failed: client=\(presentation.clientId)")
#endif
            return
        }
        let content = ClientStatusItemRenderer.content(for: presentation)
        // A stacked item owns an explicit icon-plus-text width so the button's
        // image stays at the same left inset while its text subview is
        // laid out. Inline keeps AppKit's variable title-cell sizing.
        item.length = ClientStatusItemRenderer.preferredItemLength(for: content)
            ?? NSStatusItem.variableLength
        ClientStatusItemRenderer.apply(content, image: image, to: button)
        button.toolTip = presentation.toolTip
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.setAccessibilityIdentifier(presentation.processIdentity)
        button.identifier = NSUserInterfaceItemIdentifier(presentation.processIdentity)
        button.target = self
        button.action = #selector(clientItemAction(_:))
        button.sendAction(on: [.leftMouseUp])
#if DEBUG
        logClientItemState(
            item, button: button, presentation: presentation, imageBeforeUpdate: imageBeforeUpdate)
#endif
    }

#if DEBUG
    private func logClientItemState(
        _ item: NSStatusItem,
        button: NSStatusBarButton,
        presentation: ClientTray.Presentation,
        imageBeforeUpdate: NSImage?
    ) {
        let imageAfterUpdate = ClientStatusItemRenderer.providerImage(on: button)
        let imageSize = imageAfterUpdate?.size
        let attributedTitle = button.attributedTitle.string
        let fields = [
            "client=\(presentation.clientId)",
            "imageBeforeNil=\(imageBeforeUpdate == nil)",
            "imageAfterNil=\(imageAfterUpdate == nil)",
            "imageSize=\(String(describing: imageSize))",
            "imagePosition=\(button.imagePosition.rawValue)",
            "imageScaling=\(button.imageScaling.rawValue)",
            "attributedTitle=\(String(reflecting: attributedTitle))",
            "title=\(String(reflecting: button.title))",
            "itemLength=\(item.length)",
            "buttonWidth=\(button.bounds.width)",
        ]
        print("[TokenBar DEBUG] client status item reconciled: \(fields.joined(separator: " "))")
    }
#endif

    private func removeClientItem(_ clientId: String) {
        guard let item = clientStatusItems.removeValue(forKey: clientId) else { return }
        clientStatusImages.removeValue(forKey: clientId)
        if popoverAnchorIdentity == ClientTray.processIdentity(for: clientId) {
            closePopover()
        }
        if let button = item.button {
            button.target = nil
            button.action = nil
            button.identifier = nil
            button.setAccessibilityIdentifier(nil)
            button.setAccessibilityLabel(nil)
            button.toolTip = nil
        }
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clientItemAction(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let clientId = clientStatusItems.first(where: { $0.value.button === button })?.key
        else { return }

        let current = persistedRoute()
        applyRoute(routeMemory.activateClient(
            clientId, currentClient: current.clientId, currentView: current.view))
        let identity = ClientTray.processIdentity(for: clientId)
        if popover.isShown {
            if popoverAnchorIdentity == identity {
                closePopover()
            } else {
                reanchorPopover(to: button, identity: identity)
            }
        } else {
            presentPopover(from: button, identity: identity)
        }
    }

    /// Clean teardown on app termination: drop the defaults observer, close
    /// the popover, and remove the status item so ControlCenter tears the
    /// menu-bar item down via a normal removal instead of an abrupt
    /// connection-invalidation — the latter left RunningBoard "waiting on
    /// exit context" for ~40s on quit (seen in the 2026-06-16 freeze logs).
    func tearDown() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if popover.isShown { closePopover() }
        for clientId in Array(clientStatusItems.keys) {
            removeClientItem(clientId)
        }
        clientStatusImages.removeAll()
        popover.contentViewController = nil
        animationSurface?.tearDown()
        animationSurface = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuotaMenu()
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    // MARK: - Right-click quota-source menu

    /// "What does the icon track?" — Auto plus every known quota window with
    /// its live remaining percent, checkmark on the current pick. Writes the
    /// same defaults key the settings panel edits; the icon follows within a
    /// couple of seconds.
    private func showQuotaMenu() {
        let menu = NSMenu()
        let payload = quotaPayloadProvider?()
        let persistedSelection = UserDefaults.standard.string(forKey: TrayAnimator.quotaSourceKey)
            ?? QuotaResolver.auto
        let current = QuotaResolver.canonicalSelection(
            payload: payload, selection: persistedSelection)

        let header = NSMenuItem(
            title: "Menu bar tracks".localized, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        func add(_ title: String, selection: String) {
            let item = NSMenuItem(
                title: title, action: #selector(pickQuotaSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = selection
            item.state = selection == current ? .on : .off
            menu.addItem(item)
        }
        add("Auto (tightest window)".localized, selection: QuotaResolver.auto)

        if let payload {
            // Primary account only: the persisted selection is one global
            // string with no account component (`QuotaResolver.selection`
            // encodes `clientId|cardId`, never an account), and two accounts
            // of the same client can offer identically-carded windows (both a
            // "session.v1"), so listing an extra account's window here would
            // draw a second, indistinguishable "Claude Code" section whose
            // checkmark and pick could not be told apart from the primary's.
            // An extra account's windows remain visible and selectable in the
            // Agent-limits overview; this menu targets the primary only.
            for agent in payload.agents where agent.error == nil && agent.accountKey == nil {
                let windows = agent.uniqueCardWindows
                guard !windows.isEmpty else { continue }
                menu.addItem(.separator())
                let name = NSMenuItem(
                    title: ClientRegistry.style(agent.clientId).displayName,
                    action: nil, keyEquivalent: "")
                name.isEnabled = false
                menu.addItem(name)
                for window in windows {
                    let left = "%lld%% left".localized(
                        Int(min(100, max(0, window.remainingPercent)).rounded()))
                    // `label` is display-only here; the persisted selection
                    // below is keyed by `cardId`.
                    add(
                        "\(window.label.localized) — \(left)",
                        selection: QuotaResolver.selection(
                            clientId: agent.clientId, cardId: window.cardId))
                }
            }
        } else {
            let loading = NSMenuItem(
                title: "Loading quotas…".localized, action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }

        // Pop up via a transient menu assignment so the next left-click still
        // toggles the popover instead of re-opening the menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func pickQuotaSource(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? String else { return }
        UserDefaults.standard.set(selection, forKey: TrayAnimator.quotaSourceKey)
    }
}
