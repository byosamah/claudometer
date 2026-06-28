import AppKit

/// Accessory-app entry point built WITHOUT Xcode/SwiftUI-App (a manual
/// NSApplication). `.accessory` policy = no Dock icon, no menu bar, but the
/// notch panel can still show and accept clicks. LSUIElement in Info.plist
/// suppresses the Dock icon at launch (before this runs) to avoid a flash.
@main
enum NotchPilotMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // belt-and-suspenders at runtime

        // Auto-register at login on first run only. If the user later disables
        // it in System Settings, status becomes .requiresApproval and we leave
        // their choice alone.
        if LoginItem.status == .notRegistered {
            if case .failure(let error) = LoginItem.enable() {
                NSLog("NotchPilot: login-item registration failed: \(error)")
            }
        }

        let controller = NotchWindowController(store: store)
        controller.show()
        notchController = controller   // retain, or it deallocates immediately

        store.start()
    }

    // Accessory app with no standard window: stay alive regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
