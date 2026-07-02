import Foundation

/// Bridges Claude Code's hooks to Claudometer's "waiting for you" alerts.
///
/// Two responsibilities, both dependency-free:
///  1. **CLI hook handler** — when Claudometer's own binary is invoked by a Claude
///     Code hook (`Claudometer --hook notify|clear`), it reads the event JSON on
///     stdin and writes/removes a small per-session marker file. Parsing the JSON
///     in Swift sidesteps a `jq` dependency and brittle shell parsing.
///  2. **Install/remove** our hook entries in `~/.claude/settings.json`, merged so
///     the user's existing settings and hooks are preserved, and fully removable.
///
/// The marker directory is the single contract between the (short-lived) hook
/// process and the running app's `WaitingStore`, which watches it.
enum QuestionAlerts {

    // MARK: Paths

    /// `~/Library/Application Support/Claudometer/waiting/`. The hook writes here;
    /// `WaitingStore` polls here. Both compute it the same way.
    static var waitingDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Claudometer/waiting", isDirectory: true)
    }

    /// Marker file for one session. Session ids are uuid-ish, but sanitise anyway so
    /// a stray character can never escape the directory or break the filename.
    static func markerFile(for sessionID: String) -> URL {
        waitingDir.appendingPathComponent(safeName(sessionID) + ".json")
    }

    static func safeName(_ id: String) -> String {
        String(id.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
    }

    /// Absolute path to the running Claudometer executable, used as the hook
    /// command. Binds to the current location (like the login item): if the app
    /// moves, re-toggling alerts — or simply relaunching while enabled — rewrites it.
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "Claudometer"
    }

    static var claudeSettingsURL: URL {
        // CLAUDOMETER_SETTINGS_PATH redirects the merge target (used to test the
        // install/remove logic against a throwaway file without touching the real
        // config). Absent in normal use -> the real ~/.claude/settings.json.
        if let override = ProcessInfo.processInfo.environment["CLAUDOMETER_SETTINGS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    // MARK: CLI hook handler (runs in a short-lived process, NEVER the GUI)

    /// If the process was launched as a hook (`--hook <mode>`), handle it and return
    /// true so `main()` exits before starting NSApplication. Otherwise false.
    static func handleCLIIfNeeded() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--hook"), i + 1 < args.count else { return false }
        let mode = args[i + 1]
        var kind = "idle"
        if let k = args.firstIndex(of: "--kind"), k + 1 < args.count { kind = args[k + 1] }
        runHook(mode: mode, kind: kind)
        return true
    }

    /// Reads the event JSON from stdin and writes/removes the session marker. Always
    /// best-effort and silent: a hook must never block or fail Claude Code's turn.
    private static func runHook(mode: String, kind: String) {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let sessionID = (obj?["session_id"] as? String) ?? ""
        guard !sessionID.isEmpty else { return }   // nothing to key the marker on
        let cwd = (obj?["cwd"] as? String) ?? ""
        let file = markerFile(for: sessionID)

        switch mode {
        case "notify":
            try? FileManager.default.createDirectory(at: waitingDir, withIntermediateDirectories: true)
            let project = cwd.isEmpty ? "a session" : URL(fileURLWithPath: cwd).lastPathComponent
            let payload: [String: Any] = [
                "session_id": sessionID,
                "project": project,
                "cwd": cwd,
                "since": Date().timeIntervalSince1970,
                "kind": kind,
            ]
            if let out = try? JSONSerialization.data(withJSONObject: payload) {
                try? out.write(to: file, options: .atomic)
            }
        case "clear":
            // The clear hooks run async, so Claude Code doesn't wait for them: a
            // clear spawned at PostToolUse can still be paying dyld startup when a
            // NEWER permission prompt writes its marker milliseconds later, and an
            // unconditional delete would silently eat that genuine alert. Only
            // remove a marker that already existed when this process was spawned;
            // a younger marker belongs to the newer prompt and must survive (the
            // session's next turn event clears it normally).
            if let spawned = processStartTime,
               let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
               mtime > spawned {
                return
            }
            try? FileManager.default.removeItem(at: file)
        default:
            break
        }
    }

    /// This process's kernel-recorded start time (sysctl KERN_PROC), used as the
    /// generation stamp for the clear-vs-notify race above. `nil` on any sysctl
    /// failure, in which case clear falls back to the old unconditional delete.
    private static var processStartTime: Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Delete every waiting marker. Used when alerts are switched off: the clear
    /// hooks that would normally remove an answered session's marker are gone at
    /// that point, so anything left on disk would resurrect as a ghost
    /// "Waiting for you" alert the next time alerts are enabled.
    static func clearAllMarkers() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: waitingDir, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: settings.json install / remove (safe merge)

    /// True if our hook entries are currently present in the user's settings.
    static var isInstalled: Bool {
        guard let hooks = (readSettingsForMerge() ?? [:])["hooks"] as? [String: Any] else { return false }
        for event in managedEvents {
            if let groups = hooks[event] as? [[String: Any]], groups.contains(where: groupIsOurs) {
                return true
            }
        }
        return false
    }

    /// Idempotently add our Notification + UserPromptSubmit hooks. Strips any prior
    /// Claudometer entries first (so re-installing after the app moved refreshes the
    /// path), then appends, leaving every other key and hook untouched.
    static func installHook() {
        let exe = shellQuoted(executablePath)
        // A present-but-unparseable settings file must abort the install: writing
        // a merge based on an empty dict would wipe the user's whole config.
        guard var root = readSettingsForMerge() else { return }
        var hooks = stripOurEntries(from: (root["hooks"] as? [String: Any]) ?? [:])

        // Only `permission_prompt` — Claude is genuinely BLOCKED needing your
        // decision. `idle_prompt` is deliberately NOT hooked: it fires at the end of
        // EVERY turn (whether or not Claude asked anything), so it would alert you for
        // the session you're actively in every time Claude merely finishes. That's
        // noise, not a question.
        var notification = (hooks["Notification"] as? [[String: Any]]) ?? []
        notification.append(group(matcher: "permission_prompt",
                                  command: "\(exe) --hook notify --kind permission"))
        hooks["Notification"] = notification

        // Clear the marker on ANY "no longer blocked" event. Answering a permission
        // prompt is NOT a UserPromptSubmit, so clearing on that alone left the alert
        // stuck after the user approved. async so the per-tool PostToolUse clear adds
        // zero latency to Claude.
        let clear = "\(exe) --hook clear"
        for event in clearEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.append(group(matcher: nil, command: clear, async: true))
            hooks[event] = groups
        }

        root["hooks"] = hooks
        writeSettings(root)
    }

    /// Remove only our entries; if an event's array (or the whole `hooks` key) is
    /// left empty, drop it so we don't leave dangling structure behind. No-ops when
    /// none of our entries are present, so a normal (alerts-off) launch never even
    /// touches — let alone reformats — the user's settings file.
    static func removeHook() {
        guard isInstalled else { return }
        guard var root = readSettingsForMerge() else { return }
        guard let hooks = root["hooks"] as? [String: Any] else { return }
        let stripped = stripOurEntries(from: hooks)
        if stripped.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = stripped }
        writeSettings(root)
    }

    // MARK: settings.json helpers

    /// Events that mean "this session is no longer blocked on the user," so the
    /// marker should clear. PostToolUse = you approved and the tool ran; Stop = the
    /// turn ended (also covers a DENIED prompt); UserPromptSubmit = you typed;
    /// SessionEnd = the session closed.
    private static let clearEvents = ["PostToolUse", "Stop", "UserPromptSubmit", "SessionEnd"]
    private static let managedEvents = ["Notification"] + clearEvents

    private static func group(matcher: String?, command: String, async: Bool = false) -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "command": command]
        if async { hook["async"] = true }
        var g: [String: Any] = ["hooks": [hook]]
        if let matcher { g["matcher"] = matcher }
        return g
    }

    private static func stripOurEntries(from hooks: [String: Any]) -> [String: Any] {
        var out = hooks
        for event in managedEvents {
            guard let groups = out[event] as? [[String: Any]] else { continue }
            let kept = groups.filter { !groupIsOurs($0) }
            if kept.isEmpty { out.removeValue(forKey: event) } else { out[event] = kept }
        }
        return out
    }

    /// A matcher-group is ours if any inner hook command carries our CLI signature.
    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String).map(isOurCommand) ?? false }
    }

    private static func isOurCommand(_ cmd: String) -> Bool {
        cmd.contains("--hook notify") || cmd.contains("--hook clear")
    }

    /// Reads the settings file for a read-modify-write merge. Distinguishes two
    /// very different "can't read" cases:
    ///   - The file does not exist -> `[:]` (a fresh start; writing is safe).
    ///   - The file EXISTS but can't be read or parsed as a JSON object (syntax
    ///     error, merge-conflict markers, truncated write, permissions) -> `nil`.
    ///     Merging into an empty dict and writing back would REPLACE the user's
    ///     entire config with only our hooks, so callers must abort instead.
    private static func readSettingsForMerge() -> [String: Any]? {
        let url = claudeSettingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func writeSettings(_ root: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        // Skip the write if the file is already byte-identical, so re-installing on
        // each launch (which keeps the bound binary path fresh) doesn't rewrite an
        // unchanged file. The first install still normalises formatting once.
        if let existing = try? Data(contentsOf: claudeSettingsURL), existing == data { return }
        try? FileManager.default.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: claudeSettingsURL, options: .atomic)
    }

    /// Single-quote a path for the shell that Claude Code runs the command in, so a
    /// space in the app's path can't split the command.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
