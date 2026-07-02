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
    private let updates: UpdateChecker
    private let waiting: WaitingStore
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    /// The anchored Liquid Glass panel (created on demand, torn down on dismiss).
    private var panel: NSPanel?
    private var clickMonitor: Any?   // clicks in OTHER apps' windows
    private var localMonitor: Any?   // clicks in OUR other windows (e.g. pinned notch)

    /// The transient "Claude's waiting on you" pop, and its auto-dismiss timer.
    private var toast: NSPanel?
    private var toastDismiss: DispatchWorkItem?

    init(store: UsageStore, settings: AppSettings, updates: UpdateChecker, waiting: WaitingStore) {
        self.store = store
        self.settings = settings
        self.updates = updates
        self.waiting = waiting
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        // Refresh whenever usage, settings, updates, or the waiting set change.
        // objectWillChange fires just BEFORE the value updates, so hop to the main
        // queue to read the new value.
        for publisher in [store.objectWillChange.eraseToAnyPublisher(),
                          settings.objectWillChange.eraseToAnyPublisher(),
                          updates.objectWillChange.eraseToAnyPublisher(),
                          waiting.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
                .store(in: &cancellables)
        }

        // A brand-new waiting session pops the branded toast once.
        waiting.$lastArrival
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] session in
                MainActor.assumeIsolated { self?.showWaitingToast(for: session) }
            }
            .store(in: &cancellables)

        refresh()
    }

    // MARK: Rendering

    private func refresh() {
        guard let button = statusItem.button else { return }
        let mood = store.mascot
        let style = settings.menuBarStyle
        let badge = waiting.waiting.count   // sessions waiting on the user

        button.image = style == .percentOnly ? nil : Self.glyphImage(for: mood, badge: badge)

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

    private static func glyphImage(for state: MascotState, badge: Int) -> NSImage {
        // When nothing is waiting, render the bare 18pt glyph exactly as before.
        // With a badge, render a slightly larger canvas so the count dot isn't
        // clipped by the status item's tight image bounds.
        let renderer: ImageRenderer<AnyView> = badge > 0
            ? ImageRenderer(content: AnyView(StatusGlyph(state: state, badge: badge)))
            : ImageRenderer(content: AnyView(MascotGlyph(state: state, size: 18)))
        // The status item is drawn in EVERY screen's menu bar, so rasterize at the
        // sharpest attached scale (NSScreen.main is just the key window's screen,
        // which on a mixed-DPI setup can be the blurrier 1x one).
        renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
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
            .environmentObject(updates)
            .environmentObject(waiting)
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
        // only sees clicks in OTHER apps' windows (never our own status button or
        // panel), so any event here is by definition an outside click.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }

        // Clicks in OUR OWN other windows (notably the pinned notch HUD) are local
        // events the global monitor never sees, so dismiss on those too. The status
        // button's window is excluded: its mouseDown must NOT close the panel here,
        // or the button's mouseUp action would find panel == nil and re-open it,
        // making left-click-to-dismiss impossible. Always return the event so
        // panel-internal clicks (toggles/buttons) still work.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let panel = self.panel, event.window !== panel,
                   event.window !== self.statusItem.button?.window {
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

    // MARK: "Claude's waiting on you" pop (transient, on-brand)

    /// Slide a small Liquid Glass toast out from under the status item when a new
    /// session starts waiting. Auto-dismisses after a few seconds; tapping it opens
    /// the full panel (which lists every waiting session).
    private func showWaitingToast(for session: WaitingSession) {
        dismissToast()

        let view = AlertToastView(project: session.project) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismissToast()
                if self.panel == nil { self.showPanel() }   // open the list
            }
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let p = NotchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.contentView = hosting
        toast = p

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

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismissToast() }
        }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    private func dismissToast() {
        toastDismiss?.cancel(); toastDismiss = nil
        guard let t = toast else { return }
        toast = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            t.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { t.orderOut(nil) } })
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
        // Manual enabling: with auto-enabling on, AppKit re-enables any item whose
        // target responds to its action, silently overriding `isEnabled = false`
        // (the "Checking for Updates…" guard below would be a no-op).
        menu.autoenablesItems = false

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

        // Updates: a one-tap download when a newer build is live, otherwise a
        // manual "check now" (the app also checks once at launch).
        if updates.available {
            let title = updates.latestVersion.map { "Download Update · v\($0)" } ?? "Download Update"
            let item = NSMenuItem(title: title, action: #selector(downloadUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(
                title: updates.isChecking ? "Checking for Updates…" : "Check for Updates…",
                action: #selector(checkForUpdates), keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = !updates.isChecking
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Claudometer",
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

    @objc private func checkForUpdates() { Task { await updates.check() } }

    @objc private func downloadUpdate() { updates.openDownload() }

    @objc private func toggleLogin() {
        _ = LoginItem.toggle()
        // If macOS requires explicit approval, the toggle can't take effect on its
        // own, so deep-link to Login Items instead of letting it silently snap back.
        if LoginItem.needsApproval { LoginItem.openLoginItemsSettings() }
    }
}

// MARK: - Status-item glyph with a waiting-count badge

/// The menu bar mascot with a small coral count badge for waiting sessions. Drawn
/// on a slightly larger canvas than the bare glyph so the offset badge isn't
/// clipped by the status item's tight image bounds. Used only when badge > 0.
private struct StatusGlyph: View {
    let state: MascotState
    let badge: Int

    var body: some View {
        MascotGlyph(state: state, size: 18)
            .frame(width: 18, height: 18)
            .overlay(alignment: .topTrailing) {
                Text(badge > 9 ? "9+" : "\(badge)")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, badge > 9 ? 2 : 0)
                    .frame(minWidth: 11, minHeight: 11)
                    .background(Circle().fill(Color.mascotCoral))
                    .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
                    .offset(x: 5, y: -4)
            }
            .frame(width: 26, height: 22)
    }
}

// MARK: - The branded "waiting" pop

/// A small Liquid Glass toast: the mascot plus "Claude's waiting on you · <project>".
/// Tapping anywhere on it runs `onOpen` (to surface the full panel).
private struct AlertToastView: View {
    let project: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                MascotGlyph(state: .playing(intensity: 0.9), size: 24)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude's waiting on you")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text(project)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: GlassTheme.controlCorner))
    }
}
