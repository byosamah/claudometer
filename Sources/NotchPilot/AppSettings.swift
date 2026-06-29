import SwiftUI

/// What the menu bar status item renders.
enum MenuBarStyle: String, CaseIterable, Sendable {
    case glyphAndPercent   // mood-tinted mascot glyph + session %  (default)
    case glyphOnly         // just the glyph
    case percentOnly       // just the % text
}

/// User-facing preferences, persisted in `UserDefaults`.
///
/// Classic `ObservableObject` (not `@Observable`) on purpose: the `@Observable`
/// macro plugin is absent on the Command-Line-Tools toolchain this builds with,
/// the same reason the rest of the app avoids `@State`.
@MainActor
final class AppSettings: ObservableObject {

    /// When true the carved notch HUD stays visible; when false (default) only
    /// the menu bar item shows. This is the "stay or hide" toggle.
    @Published var pinNotch: Bool { didSet { defaults.set(pinNotch, forKey: Keys.pinNotch) } }

    /// What the menu bar item shows.
    @Published var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) } }

    /// When true, Claudometer installs Claude Code hooks and alerts (badge + pop)
    /// whenever a terminal session is waiting on the user. Default false (opt-in,
    /// since it writes to ~/.claude/settings.json).
    @Published var questionAlertsEnabled: Bool { didSet { defaults.set(questionAlertsEnabled, forKey: Keys.questionAlerts) } }

    private let defaults: UserDefaults
    private enum Keys {
        static let pinNotch = "pinNotch"
        static let menuBarStyle = "menuBarStyle"
        static let questionAlerts = "questionAlertsEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Setting stored properties inside init does not trigger their didSet,
        // so this seeds from disk without writing back.
        pinNotch = defaults.bool(forKey: Keys.pinNotch)   // absent -> false (hidden by default)
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "")
            ?? .glyphAndPercent
        questionAlertsEnabled = defaults.bool(forKey: Keys.questionAlerts)   // absent -> false
    }
}
