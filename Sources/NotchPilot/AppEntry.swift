import AppKit
import Combine

/// Accessory-app entry point built WITHOUT Xcode/SwiftUI-App (a manual
/// NSApplication). `.accessory` policy = no Dock icon, no menu bar, but the
/// notch panel can still show and accept clicks. LSUIElement in Info.plist
/// suppresses the Dock icon at launch (before this runs) to avoid a flash.
@main
enum ClaudometerMain {
    @MainActor
    static func main() {
        // Hook mode: when Claude Code invokes our own binary as a hook
        // (`Claudometer --hook notify|clear`), handle it in a short-lived process
        // and exit BEFORE starting the GUI. Must be the very first thing main does.
        if QuestionAlerts.handleCLIIfNeeded() { return }

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
    private var menuBar: MenuBarController?
    private let store = UsageStore()
    private let settings = AppSettings()
    private let updates = UpdateChecker()
    private let waiting = WaitingStore()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // belt-and-suspenders at runtime

        // Auto-register at login on first run only. If the user later disables
        // it in System Settings, status becomes .requiresApproval and we leave
        // their choice alone.
        if LoginItem.status == .notRegistered {
            if case .failure(let error) = LoginItem.enable() {
                NSLog("Claudometer: login-item registration failed: \(error)")
            }
        }

        // Menu bar is now the always-on home for the mascot + usage %.
        menuBar = MenuBarController(store: store, settings: settings, updates: updates, waiting: waiting)

        // "Claude is waiting on you" alerts are opt-in. The @Published publisher
        // replays its current value on subscribe, so this both applies the saved
        // preference at launch and reacts to the footer toggle live. Enabling
        // (re)installs the Claude Code hook — which also refreshes the bound binary
        // path if the app moved — and starts the folder watcher; disabling removes
        // the hook and stops watching.
        settings.$questionAlertsEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if enabled {
                        QuestionAlerts.installHook()
                        self.waiting.start()
                    } else {
                        QuestionAlerts.removeHook()
                        self.waiting.stop()
                    }
                }
            }
            .store(in: &cancellables)

        // The notch HUD is now opt-in: shown only while pinNotch is true. The
        // @Published publisher replays the current value on subscribe, so this
        // both sets the initial visibility (hidden by default) and reacts to the
        // toggle live.
        let controller = NotchWindowController(store: store)
        notchController = controller   // retain, or it deallocates immediately
        settings.$pinNotch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if pinned { self.notchController?.show() } else { self.notchController?.hide() }
                }
            }
            .store(in: &cancellables)

        store.start()

        // Best-effort update check at launch (silent on failure). The menu's
        // "Check for Updates…" re-runs it on demand.
        Task { await updates.check() }
    }

    // Accessory app with no standard window: stay alive regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
