import AppKit
import SwiftUI
import Combine
import QuartzCore   // CAMediaTimingFunction

/// Owns the menu bar status item: a mood-tinted `MascotGlyph` plus the session
/// `%`. Left-click toggles the Liquid Glass panel (wired in step 2); right-click
/// (or control-click) opens a native menu with the pin / login / quit actions.
///
/// The glyph is rendered to an `NSImage` (via `ImageRenderer`) and set as the
/// button's image, with the `%` as the button title. That keeps native click
/// handling and auto-sizing while still showing our custom vector mascot.
@MainActor
final class MenuBarController: NSObject {

    private let store: UsageStore
    private let settings: AppSettings
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    /// The anchored Liquid Glass panel (created on demand, torn down on dismiss).
    private var panel: NSPanel?
    private var clickMonitor: Any?   // clicks in OTHER apps' windows
    private var localMonitor: Any?   // clicks in OUR other windows (e.g. pinned notch)

    init(store: UsageStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        // Refresh whenever usage or settings change. objectWillChange fires just
        // BEFORE the value updates, so hop to the main queue to read the new value.
        for publisher in [store.objectWillChange.eraseToAnyPublisher(),
                          settings.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
                .store(in: &cancellables)
        }

        refresh()
    }

    // MARK: Rendering

    private func refresh() {
        guard let button = statusItem.button else { return }
        let mood = store.mascot
        let style = settings.menuBarStyle

        button.image = style == .percentOnly ? nil : Self.glyphImage(for: mood)

        // Percent text: only in the .ok state, and never in glyphOnly mode.
        // Other states (offline / signed-out) show a dimmed glyph and no number.
        if style != .glyphOnly, case .ok(let snap) = store.state {
            let leading = style == .percentOnly ? "" : " "
            button.attributedTitle = Self.title("\(leading)\(snap.sessionPercent)%",
                                                color: store.accentColor)
        } else if style == .percentOnly {
            // No glyph in this style, so never blank the ONLY affordance: a nil
            // image + empty title collapses the item to zero width and the user
            // loses the panel/Quit menu. Show the honest status label instead.
            button.attributedTitle = Self.title(store.collapsedLabel, color: store.accentColor)
        } else {
            button.title = ""
        }

        resizeOpenPanelIfNeeded()
    }

    private static func title(_ string: String, color: Color) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(color),
        ])
    }

    private static func glyphImage(for state: MascotState) -> NSImage {
        let renderer = ImageRenderer(content: MascotGlyph(state: state, size: 18))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false   // we want the coral color, not a template tint
        return image
    }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.type == .rightMouseDown
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            closePanel()
            showMenu(from: sender)
        } else {
            togglePanel()
        }
    }

    // MARK: Anchored glass panel

    private func togglePanel() {
        if panel != nil { closePanel() } else { showPanel() }
    }

    private func showPanel() {
        let content = UsagePanelView()
            .environmentObject(store)
            .environmentObject(settings)
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize

        // NotchPanel = a borderless non-activating panel that can still become key,
        // so the toggles/buttons inside receive clicks without activating the app.
        let p = NotchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                 // the glass shape casts its own; avoid a rect ghost
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.contentView = hosting
        panel = p

        // Entrance: fade in + drop down a few px, like a menu unfurling.
        let dest = panelOrigin(size: size)
        p.setFrameOrigin(NSPoint(x: dest.x, y: dest.y + 8))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            p.animator().alphaValue = 1
            p.animator().setFrameOrigin(dest)
        }

        // Dismiss when the user clicks anywhere outside the panel. A global monitor
        // only sees clicks in OTHER apps' windows, so a click inside never closes
        // it; a click on our own status button is excluded so it can toggle.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let b = self.statusItem.button, let w = b.window {
                    let bf = w.convertToScreen(b.convert(b.bounds, to: nil))
                    if bf.contains(NSEvent.mouseLocation) { return }
                }
                self.closePanel()
            }
        }

        // Clicks in OUR OWN other windows (notably the pinned notch HUD) are local
        // events the global monitor never sees, so dismiss on those too. Always
        // return the event so panel-internal clicks (toggles/buttons) still work.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let panel = self.panel, event.window !== panel {
                    self.closePanel()
                }
            }
            return event
        }
    }

    private func closePanel() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    /// Keep an OPEN panel sized to its content. UsagePanelView's height depends on
    /// store.state (a short status line vs. the full meters + Start button), so a
    /// state change while the panel is open must re-fit, or the newly-added Start
    /// button overflows the fixed window and becomes clipped/unclickable. Re-anchors
    /// the top edge (panelOrigin pins y so it grows downward from the status item).
    private func resizeOpenPanelIfNeeded() {
        guard let panel, let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 1, size.height > 1, size != panel.frame.size else { return }
        panel.setFrame(NSRect(origin: panelOrigin(size: size), size: size), display: true)
    }

    /// Destination origin for the panel: under the status item, right-aligned
    /// (Control-Center style), clamped to the screen.
    private func panelOrigin(size: NSSize) -> NSPoint {
        guard let button = statusItem.button, let bwin = button.window else { return .zero }
        let bf = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bwin.screen ?? NSScreen.main
        let gap: CGFloat = 6
        var x = bf.maxX - size.width
        if let f = screen?.frame {
            x = max(f.minX + 8, min(x, f.maxX - size.width - 8))
        }
        let y = bf.minY - gap - size.height
        return NSPoint(x: x, y: y)
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let pin = NSMenuItem(
            title: settings.pinNotch ? "Unpin from Notch" : "Pin to Notch",
            action: #selector(togglePin), keyEquivalent: ""
        )
        pin.target = self
        pin.state = settings.pinNotch ? .on : .off
        menu.addItem(pin)

        let login = NSMenuItem(
            title: LoginItem.isEnabled ? "Disable Launch at Login" : "Launch at Login",
            action: #selector(toggleLogin), keyEquivalent: ""
        )
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NotchPilot",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        // Pop the menu under the button without permanently attaching it to the
        // status item (which would also hijack left-click).
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func togglePin() { settings.pinNotch.toggle() }

    @objc private func toggleLogin() {
        _ = LoginItem.toggle()
        // If macOS requires explicit approval, the toggle can't take effect on its
        // own, so deep-link to Login Items instead of letting it silently snap back.
        if LoginItem.needsApproval { LoginItem.openLoginItemsSettings() }
    }
}
