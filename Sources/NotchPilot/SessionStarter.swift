import Foundation

/// Fires a minimal, headless `claude -p "hi" --model haiku` to OPEN a fresh
/// 5-hour usage window on demand. Haiku is the cheapest model; the ping exists
/// only to start the clock, so output is discarded.
///
/// PATH gotcha: a GUI/login app does NOT inherit the shell PATH, so we resolve
/// the `claude` binary by absolute path from a list of known install locations.
enum SessionStarter {

    /// Result of trying to open a window. `.ok` only means the process exited 0;
    /// the actual window state is confirmed by the next usage poll.
    enum Outcome: Sendable, Equatable {
        case ok
        case notFound          // no `claude` binary on disk
        case failed(Int32)     // non-zero exit
        case launchError       // could not spawn the process
        case timedOut          // overran the deadline and was terminated
    }

    static func openWindow(timeout: TimeInterval = 25) async -> Outcome {
        guard let claude = claudePath() else { return .notFound }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["-p", "hi", "--model", "haiku"]
            process.currentDirectoryURL = home
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            // A login-item process inherits launchd's sparse PATH (/usr/bin:/bin:…),
            // so an npm/Homebrew `claude` wrapper (#!/usr/bin/env node) can't find
            // node and the ping fails. Augment PATH with the usual user/tool bins so
            // the binary can resolve its own interpreter/tools regardless of install.
            var env = ProcessInfo.processInfo.environment
            let binDirs = [
                home.appendingPathComponent(".local/bin").path,
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            ]
            env["PATH"] = binDirs.joined(separator: ":") + (env["PATH"].map { ":" + $0 } ?? "")
            process.environment = env

            do { try process.run() } catch { return .launchError }

            // Watchdog: SIGTERM at the deadline, then SIGKILL if it resists, so
            // waitUntilExit() can NEVER block forever (and isWaking always clears).
            // Record that WE killed it, so a genuine crash isn't mislabeled .timedOut.
            let killed = TimeoutFlag()
            let forceKill = DispatchWorkItem {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            let watchdog = DispatchWorkItem {
                if process.isRunning {
                    killed.set()
                    process.terminate()                                 // SIGTERM
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: forceKill)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()

            if killed.get() { return .timedOut }                        // our deadline fired
            return process.terminationStatus == 0 ? .ok : .failed(process.terminationStatus)
        }.value
    }

    /// First existing, executable `claude` among the known locations.
    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A tiny lock-guarded bool so the watchdog (on a global queue) can flag a kill
/// that `waitUntilExit()` (on the detached task) then reads, without a data race.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
