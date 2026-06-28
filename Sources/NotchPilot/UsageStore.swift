import Foundation
import SwiftUI

/// The single source of truth the SwiftUI notch view observes.
///
/// Polls `UsageService` on a timer, derives the mascot's mood from the live
/// connection state, and exposes render-ready strings. Uses the classic
/// `ObservableObject` + `@Published` pattern on purpose: the `@Observable`
/// macro path is avoided to stay safely within what compiles on a
/// Command-Line-Tools-only toolchain.
@MainActor
final class UsageStore: ObservableObject {

    @Published private(set) var state: ConnectionState = .offline
    @Published private(set) var mascot: MascotState = .dormant
    @Published private(set) var isWaking: Bool = false
    @Published private(set) var confirming: Bool = false
    /// Set when a Start-Window ping fails, so the panel can say so instead of
    /// silently reverting to the Start button.
    @Published private(set) var startError: String?

    private let service = UsageService()
    private var pollTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    /// Single-flight guard: skip a tick if the previous poll is still running, so
    /// a slow path (e.g. a pending first-run Keychain dialog) can't stack polls.
    private var isPolling = false

    /// How often to re-check usage. Utilization moves slowly, so 60s is plenty.
    private let pollInterval: Duration = .seconds(60)

    // MARK: Lifecycle

    func start() {
        pollTask?.cancel()   // idempotent: never leak a previous loop
        poll()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        wakeTask?.cancel(); wakeTask = nil
    }

    /// One-shot refresh (also used after starting a window). Guarded so an
    /// in-flight poll is never doubled.
    func poll() {
        guard !isPolling else { return }
        isPolling = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isPolling = false }
            let next = await self.service.currentState()
            self.apply(next)
        }
    }

    private func apply(_ next: ConnectionState) {
        state = next
        if !isWaking { mascot = Self.mascotState(for: next) }
    }

    // MARK: Start-window flow (two-tap confirm, no jarring modal)

    /// First tap: arm the confirm. Auto-disarms after a few seconds.
    func requestStart() {
        startError = nil
        confirming = true
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.confirming = false
        }
    }

    /// Second tap: actually fire the ping and show the wakeup animation.
    /// The ping is bounded by SessionStarter's watchdog, so `isWaking` always
    /// clears even if `claude` hangs.
    func confirmStart() {
        confirmTask?.cancel()
        confirming = false
        guard !isWaking else { return }
        isWaking = true
        startError = nil
        mascot = .wakeup
        wakeTask = Task { [weak self] in
            let outcome = await SessionStarter.openWindow()
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            self.isWaking = false
            switch outcome {
            case .ok:          self.startError = nil
            case .notFound:    self.startError = "claude not found"
            case .launchError: self.startError = "Couldn't launch claude"
            case .timedOut:    self.startError = "Start timed out"
            case .failed:      self.startError = "Start ping failed"
            }
            self.poll()
        }
    }

    // MARK: Mascot derivation

    static func mascotState(for state: ConnectionState) -> MascotState {
        switch state {
        case .needsAuth, .noBinary:
            return .needsAuth
        case .offline:
            return .offline
        case .ok(let snap):
            // The official `severity` field is the primary driver; a high-percent
            // backstop guarantees a visible warning even if severity lags.
            if snap.sessionSeverity == .warning || snap.sessionSeverity == .critical || snap.sessionPercent >= 85 {
                return .frantic
            }
            if snap.sessionPercent <= 0 { return .dormant }
            return .playing(intensity: min(1.0, Double(snap.sessionPercent) / 100.0))
        }
    }

    // MARK: Render-ready accessors

    var snapshot: UsageSnapshot? {
        if case .ok(let s) = state { return s }
        return nil
    }

    /// True when a 5-hour window is currently open. Uses the raw-utilization flag
    /// (any usage > 0), NOT the rounded percent — a freshly opened window can sit
    /// below 0.5% and round to 0%. And NOT the API's `is_active` flag, which means
    /// "currently the binding limit," not "window open."
    var hasOpenWindow: Bool { snapshot?.sessionHasUsage ?? false }

    var collapsedLabel: String {
        switch state {
        case .ok(let s):            return "\(s.sessionPercent)%"
        case .needsAuth, .noBinary: return "sign in"
        case .offline:              return "offline"
        }
    }

    var sessionLine: String {
        guard let s = snapshot else { return statusText }
        return "Session \(s.sessionPercent)% · resets \(Self.countdown(s.sessionResetsAt))"
    }

    var weeklyLine: String {
        guard let s = snapshot else { return "" }
        return "Weekly \(s.weeklyPercent)% · resets \(Self.weekday(s.weeklyResetsAt))"
    }

    var statusText: String {
        switch state {
        case .needsAuth: return "Open Claude Code to sign in"
        case .noBinary:  return "Keychain unavailable"
        case .offline:   return "Offline · retrying"
        case .ok:        return ""
        }
    }

    /// Accent color is driven directly by the official severity (three tiers),
    /// not by the mascot mood. Driving it off the mascot collapsed warning and
    /// critical into the same red, so the amber tier never showed.
    var accentColor: Color {
        switch state {
        case .ok(let s):
            if s.sessionSeverity == .critical || s.sessionPercent >= 85 { return .severityDanger }
            if s.sessionSeverity == .warning { return .severityWarn }
            return .severityCalm
        case .needsAuth, .noBinary, .offline:
            return .secondary
        }
    }

    // MARK: Formatting helpers (value-type FormatStyle; Sendable, no static formatter)

    static func countdown(_ date: Date?) -> String {
        guard let date else { return "—" }
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "now" }
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
    }

    static func weekday(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour())
    }

    deinit {
        pollTask?.cancel()
        confirmTask?.cancel()
        wakeTask?.cancel()
    }
}
