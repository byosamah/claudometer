import AppKit
import SwiftUI
import QuartzCore   // CAMediaTimingFunction

// MARK: - Shared state (bridges the AppKit controller <-> the SwiftUI view)
// Owned by the controller, injected into the hosting view via .environmentObject.
@MainActor
final class NotchState: ObservableObject {
    @Published var isExpanded: Bool = false
}

// MARK: - Non-activating panel subclass
// nonactivatingPanel already prevents app activation; we further refuse `main`
// so the panel never becomes the app's main window. canBecomeKey stays true so
// SwiftUI controls (buttons) inside still work, gated by becomesKeyOnlyIfNeeded.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Hover container that owns the NSTrackingArea
// Robust hover detection lives here (NOT on the NSHostingView, whose tracking
// areas are managed internally by SwiftUI). `.inVisibleRect` makes the tracking
// area auto-match the view's current size, so it survives the expand/collapse
// resize with zero manual rect math. `.activeAlways` is mandatory because the
// panel is non-activating: without it, mouseEntered/Exited would only fire while
// our app is frontmost.
@MainActor
final class NotchHoverContainer: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEntered?() }
    override func mouseExited(with event: NSEvent)  { onExited?() }
}

// MARK: - Notch geometry, derived purely from NSScreen
struct NotchMetrics {
    var screenFrame: NSRect   // full screen frame (global coords, bottom-left origin)
    var notchHeight: CGFloat  // safeAreaInsets.top on a notched screen; menu-bar height otherwise
    var notchCenterX: CGFloat // global x of the notch's horizontal center
    var notchWidth: CGFloat   // physical notch width (camera housing) when known
    var hasNotch: Bool
}

// MARK: - The controller
@MainActor
final class NotchWindowController: NSWindowController {

    private let state = NotchState()
    private let store: UsageStore
    private let hoverContainer = NotchHoverContainer()

    // Pill (collapsed) vs dropped-down panel (expanded). Tune to taste.
    private let collapsedSize = NSSize(width: 124, height: 30)
    private let expandedSize  = NSSize(width: 360, height: 190)

    // MARK: Init
    init(store: UsageStore) {
        self.store = store
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 124, height: 30)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configure(panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(_ panel: NotchPanel) {
        // ---- Float over everything, never steal focus ----
        panel.level = .statusBar                       // above the menu bar (CGWindowLevel "status" == 25)
        panel.collectionBehavior = [.canJoinAllSpaces, // visible on every Space
                                    .stationary,        // doesn't slide with Mission Control / Spaces
                                    .fullScreenAuxiliary] // shows over other apps' full-screen spaces
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true            // only takes key when a control truly needs it
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false               // we WANT hover/clicks

        // ---- Host the SwiftUI view inside the hover container ----
        let hosting = NSHostingView(
            rootView: NotchRootView()
                .environmentObject(state)
                .environmentObject(store)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hoverContainer.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: hoverContainer.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: hoverContainer.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: hoverContainer.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: hoverContainer.bottomAnchor),
        ])
        panel.contentView = hoverContainer

        hoverContainer.onEntered = { [weak self] in self?.setExpanded(true) }
        hoverContainer.onExited  = { [weak self] in self?.setExpanded(false) }

        // ---- React to display reconfiguration (notch screen unplugged, resolution change, etc.) ----
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: Geometry
    // The screen that physically HAS a notch (safeAreaInsets.top > 0).
    private func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private func currentMetrics() -> NotchMetrics? {
        if let s = notchedScreen() {
            let f = s.frame
            let h = s.safeAreaInsets.top
            // The two auxiliary rects flank the camera housing. The notch spans
            // from the LEFT area's right edge to the RIGHT area's left edge.
            if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
                let notchLeftX  = left.maxX
                let notchRightX = right.minX
                return NotchMetrics(
                    screenFrame: f,
                    notchHeight: h,
                    notchCenterX: (notchLeftX + notchRightX) / 2,   // exact notch center
                    notchWidth: notchRightX - notchLeftX,
                    hasNotch: true
                )
            }
            // Notch present but aux rects unavailable -> notch is geometrically centered.
            return NotchMetrics(screenFrame: f, notchHeight: h,
                                notchCenterX: f.midX, notchWidth: 200, hasNotch: true)
        }
        // ---- Fallback: no notch anywhere -> top-center pill under the menu bar of main screen ----
        guard let s = NSScreen.main else { return nil }
        let f = s.frame
        let menuBarHeight = f.maxY - s.visibleFrame.maxY   // height of the menu bar strip
        return NotchMetrics(screenFrame: f, notchHeight: menuBarHeight,
                            notchCenterX: f.midX, notchWidth: 200, hasNotch: false)
    }

    /// Window frame for a given expansion state.
    ///
    /// Cocoa screen coords are bottom-left origin, y grows UP.
    /// We anchor the window's TOP edge at the notch's bottom line
    /// (`screen.maxY - notchHeight`) and grow DOWNWARD, so:
    ///   - collapsed pill sits centered directly *under* the notch
    ///   - expanded panel drops further down *below* the notch
    private func frame(expanded: Bool, _ m: NotchMetrics) -> NSRect {
        let size = expanded ? expandedSize : collapsedSize
        let topY    = m.screenFrame.maxY - m.notchHeight   // bottom edge of the notch / menu bar
        let originX = m.notchCenterX - size.width / 2       // (a) horizontal centering
        let originY = topY - size.height                   // (b) drop downward by full height
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    // MARK: Public API
    func show() {
        reposition(animated: false)
        window?.orderFrontRegardless()   // show WITHOUT activating the app
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: Expand / collapse
    private func setExpanded(_ expanded: Bool) {
        guard state.isExpanded != expanded else { return }
        state.isExpanded = expanded
        // Expand INSTANTLY so the hover/hit area reaches full size immediately and
        // moving the pointer down into the panel can't race the resize and collapse.
        // SwiftUI still crossfades the inner content for a soft feel. Collapse animates.
        reposition(animated: !expanded)
    }

    private func reposition(animated: Bool) {
        guard let panel = window, let m = currentMetrics() else { return }
        let target = frame(expanded: state.isExpanded, m)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        // Re-pin to whatever screen now owns the notch (or fall back).
        reposition(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
