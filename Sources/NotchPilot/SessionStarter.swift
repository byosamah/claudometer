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
    }

    static func openWindow() async -> Outcome {
        guard let claude = claudePath() else { return .notFound }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["-p", "hi", "--model", "haiku"]
            process.currentDirectoryURL = home
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return .launchError }
            process.waitUntilExit()
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
