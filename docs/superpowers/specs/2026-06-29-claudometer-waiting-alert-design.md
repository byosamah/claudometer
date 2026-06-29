# Claudometer — "Claude is waiting on you" alerts

Date: 2026-06-29

## Problem

A Claude Code session in a terminal often pauses to ask the user something (a
permission prompt, or it finished its turn and awaits the next message). When the
user has tabbed away to another window, they miss it and Claude sits idle. The
menu-bar/notch app is always visible, so it should surface a small, on-brand alert:
"Claude's waiting on you."

## Detection (verified)

Claude Code's hooks fire the exact signals we need:

- `Notification` hook, matcher `permission_prompt` → Claude is BLOCKED needing your
  decision. This is the only trigger we hook: a genuine "Claude has something for
  you" moment.
- `Notification` hook, matcher `idle_prompt` → fires at the END OF EVERY TURN
  (whether or not Claude asked anything). Deliberately NOT hooked: it would alert
  you for the session you're actively in every time Claude merely finishes. Noise.
- `UserPromptSubmit` hook → the user answered (our CLEAR signal).

Each payload (stdin JSON) includes `session_id` and `cwd`. The matcher type is NOT
in the JSON, so we pass it as a CLI arg on the hook command.

## Data flow

```
Claude Code (any terminal)
  Notification(permission_prompt) ─────────────▶ Claudometer --hook notify --kind permission
       writes  <support>/waiting/<session_id>.json  { session_id, project, cwd, since, kind }
  PostToolUse | Stop | UserPromptSubmit | SessionEnd ─▶ Claudometer --hook clear  (async)
       removes <support>/waiting/<session_id>.json

WaitingStore (poll folder ~1.5s) ──▶ @Published waiting: [WaitingSession]
  ├─ menu-bar mascot: "waiting" mood + coral count badge (persists until answered)
  ├─ branded Liquid Glass pop near the item ("Claude's waiting on you · <project>")
  └─ panel "Waiting" section (pop click opens it; lists each project + elapsed + dismiss)
```

`<support>` = `~/Library/Application Support/Claudometer/waiting/`.

## Decisions

- **Hook command = the Claudometer binary itself** (`--hook notify|clear`). Parses
  the JSON in Swift; no `jq` dependency, no fragile shell parsing. Binds to the app
  path (like the login item): moving the app means re-toggling alerts once.
- **Watcher = 1.5s directory poll.** Tiny folder; trivial cost; deterministic.
  FSEvents is a later optimization.
- **Hook install = safe JSON merge** into `~/.claude/settings.json` on the
  "Alert me when Claude's waiting" toggle. Preserves existing keys/hooks; removable.
  Our entries are identified by the binary path in the command string.
- **Surfaces = branded pop + persistent mascot badge + panel section.** No native
  macOS notification in v1 (user choice). Caveat: invisible over a full-screen app
  on another Space until the menu bar is revealed. Native notification is a possible
  fast-follow toggle.
- **Clearing = any "no longer blocked" event + staleness sweep + manual dismiss.**
  Clear on `PostToolUse` (you approved → tool ran), `Stop` (turn ended, also covers
  a denied prompt), `UserPromptSubmit` (you typed), and `SessionEnd` (async, so the
  per-tool clear adds no latency). Answering a permission prompt is NOT a
  `UserPromptSubmit`, so clearing on that alone left the alert stuck. A killed
  session still leaves a stale file; the store sweeps files past a cutoff, and the
  panel offers per-row dismiss.

## Components

- `QuestionAlerts.swift` — support-dir paths; the `--hook` CLI handler
  (`runHook`, reads stdin, writes/removes the file, always exit 0); the
  `~/.claude/settings.json` merge/unmerge (`installHook` / `removeHook`, atomic).
- `WaitingStore.swift` — `ObservableObject` (same pattern as `UsageStore`). Polls
  the folder, decodes files, sweeps stale, exposes `[WaitingSession]` and signals
  new arrivals (for the pop). `WaitingSession { id, project, since }`.
- `AppSettings.questionAlertsEnabled` (default false) + footer toggle.
- `MenuBarController` — count badge composited on the glyph + "waiting" mood; shows
  the branded pop on a new arrival; pop click opens the main panel.
- `UsagePanelView` — a "Waiting" section at the top when non-empty (project +
  elapsed + dismiss), and the footer toggle.
- `AppEntry` — `--hook` branch at the top of `main()` (before NSApplication); wires
  `WaitingStore` + drives install/uninstall + start/stop from `questionAlertsEnabled`.

## Out of scope (v1)

- Native macOS notifications (fast-follow toggle).
- Focusing/raising the waiting terminal window (unreliable across terminals).
- FSEvents (poll is enough).

## Verification

- Pipe sample JSON to `Claudometer --hook notify --kind idle` / `--hook clear` →
  file appears / is removed with correct fields.
- `installHook` then `removeHook` on a sample settings.json → correct merge, other
  keys preserved, idempotent, fully removable.
- Run the app; drop a waiting file by hand → badge + pop + panel section appear;
  remove it → they clear. Confirm via on-screen check + debug log.
- Compiles at `-swift-version 6 -strict-concurrency=complete`.
