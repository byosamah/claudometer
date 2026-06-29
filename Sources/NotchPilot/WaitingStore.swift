import Foundation
import SwiftUI

/// One Claude Code session currently waiting on the user.
struct WaitingSession: Identifiable, Equatable, Sendable {
    let id: String        // Claude Code session_id
    let project: String   // basename of the session's cwd
    let since: Date        // when it started waiting
    let kind: String       // "idle" or "permission"
}

/// Single source of truth for "which sessions are waiting on you," observed by the
/// menu bar (badge + pop) and the panel. Polls `QuestionAlerts.waitingDir` every
/// 1.5s — a tiny folder, negligible cost, and deterministic (no FSEvents needed).
///
/// Classic `ObservableObject` on purpose: the `@Observable` macro is unavailable on
/// the Command-Line-Tools toolchain, same as the rest of the app.
@MainActor
final class WaitingStore: ObservableObject {

    @Published private(set) var waiting: [WaitingSession] = []
    /// Set when a genuinely NEW session starts waiting (not present last poll), so
    /// the menu bar can pop a one-time toast. Never set on the first poll after
    /// start(), so enabling alerts with pre-existing markers doesn't toast-storm.
    @Published private(set) var lastArrival: WaitingSession?

    private var pollTask: Task<Void, Never>?
    private var knownIDs: Set<String> = []
    private var seeded = false

    /// A marker older than this with no clear means the session died without
    /// answering; sweep it so a ghost alert can't linger forever.
    private let staleAfter: TimeInterval = 6 * 3600

    /// Polls every 1.5s. Created inside a `@MainActor` method, so the unstructured
    /// Task inherits main-actor isolation (same pattern as `UsageStore`).
    func start() {
        stop()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.poll()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        waiting = []
        knownIDs = []
        seeded = false
        lastArrival = nil
    }

    /// Manually clear one session's alert (the panel's per-row dismiss). Removes the
    /// marker file and re-polls so the UI updates immediately.
    func dismiss(_ id: String) {
        try? FileManager.default.removeItem(at: QuestionAlerts.markerFile(for: id))
        poll()
    }

    private func poll() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: QuestionAlerts.waitingDir,
                                                includingPropertiesForKeys: nil)) ?? []
        var found: [WaitingSession] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = obj["session_id"] as? String else { continue }
            let since = (obj["since"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()
            if Date().timeIntervalSince(since) > staleAfter {
                try? fm.removeItem(at: url)   // sweep stale ghost
                continue
            }
            found.append(WaitingSession(
                id: id,
                project: (obj["project"] as? String) ?? "a session",
                since: since,
                kind: (obj["kind"] as? String) ?? "idle"))
        }
        found.sort { $0.since < $1.since }

        // First poll only seeds the known set (no toast); later polls surface a new
        // arrival for the pop.
        if seeded, let arrival = found.first(where: { !knownIDs.contains($0.id) }) {
            lastArrival = arrival
        }
        seeded = true
        knownIDs = Set(found.map(\.id))
        if found != waiting { waiting = found }
    }

    /// "3m", "just now", etc. — a compact elapsed-since label for the panel rows.
    static func elapsed(since date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "just now" }
        let m = secs / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        return "\(h)h \(m % 60)m"
    }
}
