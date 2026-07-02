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

    @Published private(set) var state: ConnectionState = .offline(.network)
    @Published private(set) var mascot: MascotState = .dormant
    @Published private(set) var isWaking: Bool = false
    /// True once ANY poll has proven a readable Claude credential (the Keychain
    /// read succeeded), even if the usage fetch itself then failed. Drives the
    /// setup walkthrough's "signed in" / "keychain allowed" checkmarks.
    @Published private(set) var tokenSeen = false
    /// Persisted "this Mac has shown real usage at least once." A user who has
    /// never connected gets the guided setup card for ANY failure state; a user
    /// who has connected before just sees the honest status line on blips.
    @Published private(set) var hasConnectedBefore: Bool
    /// Set when a Start-Window ping fails, so the panel can say so instead of
    /// silently reverting to the Start button.
    @Published private(set) var startError: String?
    /// True once we've held a good reading and are now riding out a brief failure.
    @Published private(set) var reconnecting = false
    /// False until the very first poll resolves, so we can show "checking" rather
    /// than a scary "offline" on launch.
    @Published private(set) var loadedOnce = false

    private let service = UsageService()
    private var pollTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    /// Single-flight guard: skip a tick if the previous poll is still running, so
    /// a slow path (e.g. a pending first-run Keychain dialog) can't stack polls.
    private var isPolling = false
    /// Last healthy reading, kept so a transient failure can hold real (if slightly
    /// stale) data instead of blanking to offline.
    private var lastGood: UsageSnapshot?
    private var failureStreak = 0
    /// Keep showing the last good reading through outages until it's this old, so a
    /// brief network blip (wake-from-sleep, a saturated link) never flashes "Offline".
    private let staleAfter: TimeInterval = 600   // 10 minutes

    /// How often to re-check usage when healthy. Utilization moves slowly.
    private let pollInterval: Duration = .seconds(60)

    private let defaults: UserDefaults
    private static let hasConnectedKey = "hasConnectedBefore"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasConnectedBefore = defaults.bool(forKey: Self.hasConnectedKey)
    }

    // MARK: Lifecycle

    func start() {
        pollTask?.cancel()   // idempotent: never leak a previous loop
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.refresh()
                try? await Task.sleep(for: self.nextDelay(after: result))
            }
        }
    }

    /// How long to wait before the next poll, given what just happened.
    private func nextDelay(after result: ConnectionState) -> Duration {
        switch result {
        case .ok:
            return pollInterval                                  // steady 60s
        case .rateLimited(let retryAfter):
            // NEVER fast-retry a 429 — that perpetuates it. Wait it out (respect
            // Retry-After if present), clamped to a sane 60…300s window.
            return .seconds(min(300, max(60, retryAfter ?? 90)))
        case .offline, .noBinary:
            // transient: heal fast with a bounded 4 → 8 → 16 → 32 → 60s backoff.
            return .seconds(min(60, 4 << min(max(failureStreak - 1, 0), 4)))
        case .needsAuth:
            // Each Keychain read can re-trigger the macOS "allow access" dialog
            // when the user hasn't clicked "Always Allow" yet, so a fast retry
            // storms dialogs at the exact moment a new user is most confused.
            // Retry gently (15 → 30 → 60 → 120s); the setup card's Recheck
            // button gives an instant manual path after signing in.
            return .seconds(min(120, 15 << min(max(failureStreak - 1, 0), 3)))
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        wakeTask?.cancel(); wakeTask = nil
    }

    /// Manual one-shot refresh (the walkthrough's Recheck, the post-Start poll).
    /// Guarded so an in-flight refresh is never doubled, AND a no-op while
    /// rate-limited: every request during a 429 restarts the cooldown, so no
    /// manual path may fire one (the poll loop's 60-300s pacing is the only way
    /// out of a 429).
    func poll() {
        if case .rateLimited = state { return }
        Task { [weak self] in await self?.refresh() }
    }

    /// True while the API has us in a 429 cooldown; the walkthrough disables its
    /// Recheck button on this (the diagnosis box explains the wait).
    var isRateLimited: Bool {
        if case .rateLimited = state { return true }
        return false
    }

    /// The single-flight point for BOTH the periodic loop and the manual poll().
    /// `isPolling` is set/cleared synchronously on the MainActor around the suspend,
    /// so a concurrent caller (e.g. the post-Start poll landing on a loop tick)
    /// bails instead of firing a second `/api/oauth/usage` request — which the
    /// endpoint 429-rate-limits. Returns the current state when it skips.
    @discardableResult
    private func refresh() async -> ConnectionState {
        if isPolling { return state }
        isPolling = true
        defer { isPolling = false }
        let next = await service.currentState()
        apply(next)
        return next
    }

    /// Folds a fresh result into published state. Holds the last good reading
    /// through transient network blips AND rate limits (we still have valid data,
    /// just can't refresh it yet), as long as it's fresh. Auth problems surface now.
    private func apply(_ next: ConnectionState) {
        loadedOnce = true
        if case .ok(let snap) = next {
            lastGood = snap
            failureStreak = 0
            reconnecting = false
            tokenSeen = true
            if !hasConnectedBefore {
                hasConnectedBefore = true
                defaults.set(true, forKey: Self.hasConnectedKey)
            }
            state = .ok(snap)
            // A confirmed-open window clears any stale Start error, so an old
            // "claude not found" / "timed out" can't resurface beside a fresh
            // Start button after this window later ends.
            if snap.sessionHasUsage { startError = nil }
            if !isWaking { mascot = Self.mascotState(for: state) }
            return
        }

        // Track whether the Keychain step has ever succeeded: any result past
        // the token read (a fetch that errored, a 429) still proves the
        // credential is readable. A confirmed needsAuth un-proves it.
        switch next {
        case .rateLimited:
            tokenSeen = true
        case .offline(let reason) where reason != .keychainStalled:
            tokenSeen = true
        case .needsAuth:
            tokenSeen = false
        default:
            break
        }

        // A confirmed 401 / missing credential means the login is gone. Holding
        // (or later resurrecting) the pre-revocation snapshot would paper over
        // "sign in" with a live-looking percentage, so drop it: only a NEW good
        // poll may show data again.
        if case .needsAuth = next { lastGood = nil }

        let holdable: Bool = {
            switch next { case .offline, .rateLimited: return true; default: return false }
        }()
        if holdable, let good = lastGood, Date().timeIntervalSince(good.fetchedAt) < staleAfter {
            reconnecting = true
            state = .ok(good)          // keep real data; the blip/limit is invisible
        } else {
            reconnecting = false
            state = next               // honest needsAuth / noBinary / stale offline / limited
        }

        // Transient failures (offline/auth/binary) grow the fast-backoff counter; a
        // 429 is paced by nextDelay's long wait instead, so it resets the counter.
        if case .rateLimited = next { failureStreak = 0 } else { failureStreak += 1 }

        if !isWaking { mascot = Self.mascotState(for: state) }
    }

    // MARK: Start-window flow (single tap from a deliberate panel/HUD)

    /// Fire the start ping and show the wakeup animation. The ping is bounded by
    /// SessionStarter's watchdog, so `isWaking` always clears even if `claude` hangs.
    func confirmStart() {
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
        case .rateLimited:
            return .dormant   // just waiting out the limit, not broken
        case .ok(let snap):
            // The official `severity` field is the primary driver; a high-percent
            // backstop guarantees a visible warning even if severity lags.
            if snap.sessionSeverity == .warning || snap.sessionSeverity == .critical || snap.sessionPercent >= 85 {
                return .frantic
            }
            // Use the raw-usage flag, not the rounded percent: a freshly opened
            // window can sit below 0.5% (rounds to 0) yet is genuinely open, so
            // the mascot should be alive, not dormant. Mirrors `hasOpenWindow`.
            if !snap.sessionHasUsage { return .dormant }
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

    /// Show the guided "connect your Claude" walkthrough. Always for a missing or
    /// revoked credential, and for EVERY failure state while this Mac has never
    /// connected: a brand-new install stuck behind a Keychain dialog, a network
    /// blip, or an API error needs step-by-step guidance, not a bare
    /// "Connecting…" it can't act on. Once real data has shown at least once,
    /// transient failures go back to the short honest status line.
    var needsWalkthrough: Bool {
        if case .ok = state { return false }
        if case .needsAuth = state { return true }
        return !hasConnectedBefore
    }

    /// What is blocking the connection right now, in plain words, plus what to do
    /// about it. `nil` while the very first poll is still in flight, and when the
    /// numbered steps already carry the message (no Claude Code installed yet).
    var setupProblem: (title: String, detail: String)? {
        if !loadedOnce { return nil }
        switch state {
        case .ok:
            return nil
        case .needsAuth:
            guard claudeInstalled else { return nil }   // step 1 already says "install"
            return ("No Claude login found yet",
                    "Run \u{201C}claude\u{201D} in Terminal and sign in, then hit Recheck. "
                    + "If macOS asked about the Keychain and you clicked Deny, "
                    + "Recheck and choose Always Allow this time.")
        case .noBinary:
            return ("Keychain tool unavailable",
                    "macOS wouldn't launch /usr/bin/security, which Claudometer "
                    + "uses to read your Claude login. A restart usually clears this.")
        case .rateLimited:
            return ("Rate-limited by Anthropic",
                    "Too many checks in a short burst. This clears on its own in a "
                    + "minute or two; no action needed.")
        case .offline(let reason):
            switch reason {
            case .keychainStalled:
                return ("Waiting for Keychain access",
                        "macOS is showing a dialog about \u{201C}Claude Code-credentials\u{201D}. "
                        + "Click Always Allow so Claudometer can read your Claude login.")
            case .network:
                return ("Can't reach Anthropic",
                        "Check your internet connection. Claudometer keeps retrying on its own.")
            case .httpError(let code) where code >= 500:
                // A 5xx is Anthropic's outage, never the user's login; blaming
                // their account type here would misdirect them into re-authing.
                return ("Anthropic returned an error (HTTP \(code))",
                        "Anthropic's usage service is having trouble right now. "
                        + "Claudometer keeps retrying on its own.")
            case .httpError(let code):
                return ("Anthropic returned an error (HTTP \(code))",
                        "Usage needs a Claude subscription login (Max or Pro) in Claude "
                        + "Code. An API-key-only login can't read usage limits.")
            case .badResponse:
                return ("Unexpected response from Anthropic",
                        "The usage API sent something Claudometer couldn't read. "
                        + "It keeps retrying on its own.")
            }
        }
    }

    /// Whether the Claude Code CLI is present on disk, so the onboarding card can
    /// check off step 1. Reuses the same path probe the start-window flow uses.
    var claudeInstalled: Bool { SessionStarter.claudePath() != nil }

    var collapsedLabel: String {
        if !loadedOnce { return "…" }   // first poll still in flight
        switch state {
        case .ok(let s):            return "\(s.sessionPercent)%"
        case .needsAuth, .noBinary: return "sign in"
        case .offline:              return lastGood == nil ? "…" : "offline"
        case .rateLimited:          return "…"
        }
    }

    // Render-ready values for the Liquid Glass panel's progress bars.
    var sessionPercent: Int { snapshot?.sessionPercent ?? 0 }
    var weeklyPercent: Int { snapshot?.weeklyPercent ?? 0 }
    var sessionFraction: Double { Double(min(100, max(0, sessionPercent))) / 100 }
    var weeklyFraction: Double { Double(min(100, max(0, weeklyPercent))) / 100 }
    var sessionResetText: String {
        guard let d = snapshot?.sessionResetsAt else { return "" }
        return "Resets \(Self.countdown(d))"
    }
    var weeklyResetText: String {
        guard let d = snapshot?.weeklyResetsAt else { return "" }
        return "Resets \(Self.weekday(d))"
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
        if !loadedOnce { return "Checking usage…" }
        switch state {
        case .needsAuth: return "Open Claude Code to sign in"
        case .noBinary:  return "Keychain unavailable"
        // No lastGood yet => we've never connected; say what's actually blocking
        // us instead of an unexplained "Connecting…". A real "Offline" only shows
        // after a >10min outage.
        case .offline(let reason):
            guard lastGood == nil else { return "Offline · retrying" }
            switch reason {
            case .keychainStalled:   return "Waiting for Keychain access…"
            case .network:           return "Connecting…"
            case .httpError(let c):  return "Anthropic error (HTTP \(c))"
            case .badResponse:       return "Unexpected API response"
            }
        case .rateLimited: return "Rate-limited · retrying soon"   // only before we ever have data
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
        case .needsAuth, .noBinary, .offline, .rateLimited:
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
        wakeTask?.cancel()
    }
}
