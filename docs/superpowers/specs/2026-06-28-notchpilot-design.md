# NotchPilot — Design Spec

**Date:** 2026-06-28
**Status:** Approved design, ready for implementation plan
**Owner:** Osama

## 1. Goal

A tiny macOS app that lives in the MacBook **notch** (the camera area) and shows
the real Claude **Max-plan usage limits** at a glance, fronted by an animated
Claude-sparkle mascot whose mood reflects how close you are to your limit. A
**Start Window** button opens a fresh 5-hour usage window on demand by firing a
cheap, headless `claude` ping.

The app answers one question without you opening Claude: *"How much of my limit is
left, and when does it reset?"*

## 2. Verified facts (feasibility confirmed 2026-06-28)

These were validated live on the owner's machine before this spec was written.

- **CLI present:** `claude` 2.1.195 at `~/.local/bin/claude` (symlink to a
  Mach-O binary under `~/.local/share/claude/versions/`).
- **Auth:** OAuth token stored in macOS Keychain as generic password,
  service name **`Claude Code-credentials`**. Blob is JSON:
  `{"claudeAiOauth":{"accessToken","refreshToken","expiresAt","scopes","subscriptionType"}}`.
  Confirmed `subscriptionType: "max"`, scopes include `user:inference` and
  `user:sessions:claude_code`.
- **Data source:** `GET https://api.anthropic.com/api/oauth/usage`
  with headers `Authorization: Bearer <accessToken>` and
  `anthropic-beta: oauth-2025-04-20`. Returns **HTTP 200** with the real,
  server-side utilization. This is the same endpoint Claude Code's `/usage`
  command uses.

### Response shape (the fields we consume)

```jsonc
{
  "five_hour":  { "utilization": 20.0, "resets_at": "2026-06-28T15:50:00Z", "limit_dollars": null },
  "seven_day":  { "utilization": 29.0, "resets_at": "2026-07-02T03:00:00Z", "limit_dollars": null },
  "seven_day_sonnet": { "utilization": 0.0, "resets_at": null },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 20, "severity": "normal", "resets_at": "...15:50...", "is_active": false },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 29, "severity": "normal", "resets_at": "...Jul 2...",  "is_active": true  },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 0,  "severity": "normal", "resets_at": null, "scope": { "model": { "display_name": "Sonnet" } } }
  ],
  "extra_usage": { "is_enabled": false }
}
```

- **Session window** = `five_hour` (the "5-hour window" the user cares about).
- **Weekly** = `seven_day`.
- `limit_dollars`/`used_dollars` are `null` on Max plans (utilization is %-based).
  We render **percent, never dollars**.
- **`severity`** per limit (`normal` and, when near the cap, escalated values)
  drives the mascot mood. We do NOT hardcode thresholds; we trust this field and
  treat any non-`normal` value as escalated.

## 3. Non-goals (v1, YAGNI)

- No history charts or trend graphs.
- No multi-account / org switching.
- No dollar-spend display (Max plan returns null dollars).
- No self-managed OAuth refresh flow (deferred to v1.1; see §10).
- No settings UI beyond what §8 requires.

## 4. Architecture

Native **Swift / SwiftUI**, built as an **accessory app** (`LSUIElement`, no Dock
icon, no menu bar by default). Notch geometry handled by **DynamicNotchKit**
(SwiftUI Swift Package). Login-item registration via **`SMAppService`**.

Components, each with a single responsibility:

| Component | Responsibility | Depends on |
|---|---|---|
| `KeychainReader` | Read the OAuth access token from `Claude Code-credentials`. | Security.framework |
| `UsageClient` | `GET /api/oauth/usage`, decode JSON → `UsageSnapshot`. | `KeychainReader`, URLSession |
| `UsageStore` | `@Observable` source of truth. Polls on a timer, exposes snapshot + `ConnectionState`. | `UsageClient` |
| `NotchView` | Collapsed peek + hover-expanded panel. | `UsageStore`, `Mascot` |
| `Mascot` | SwiftUI-drawn animated character; renders a `MascotState`. | (pure view) |
| `SessionStarter` | Confirm sheet → headless `claude -p "hi"` on Haiku. | absolute `claude` path |
| `AppController` | App lifecycle, login item, notch-vs-fallback placement. | all of the above |

**Data flow (one direction):**
`UsageStore.poll()` → `UsageClient` → `UsageSnapshot` → `UsageStore` updates →
SwiftUI re-renders `NotchView` and derives `MascotState`. No component reaches
backward.

## 5. Data model

```swift
struct UsageSnapshot {
    let sessionPercent: Int          // five_hour.utilization, rounded
    let sessionResetsAt: Date?       // five_hour.resets_at
    let sessionSeverity: Severity    // from limits[kind == session]
    let sessionIsActive: Bool         // "currently binding limit" — NOT "window open"; see §7
    let weeklyPercent: Int           // seven_day.utilization
    let weeklyResetsAt: Date?
    let weeklySeverity: Severity
    let fetchedAt: Date
}

enum Severity { case normal, warning, critical }   // map any non-"normal" string → warning/critical
enum ConnectionState { case ok(UsageSnapshot), needsAuth, offline, noBinary }
```

## 6. Polling strategy

- Default interval: **60s** (utilization moves slowly).
- **Immediate refresh** on: hover-expand, app foreground, and right after a
  successful Start ping.
- Token is re-read from Keychain **every poll** (Claude Code keeps it fresh while
  in use), so a refreshed token is picked up automatically.
- On `401` → `ConnectionState.needsAuth`. On network error → `.offline`. These are
  honest states with their own mascot/visual, never a fabricated percentage.

## 7. UI spec

**Collapsed (always visible in/around the notch):**
- The mascot peeking out, plus a minimal **session-% ring** (thin arc) or a 2-digit
  `%` micro-label. Color accent follows `sessionSeverity`.

**Hover-expanded (drops down below the notch):**
- **Hero:** `Session 20% · resets in 4h 31m` with a circular progress ring.
- **Subline:** `Weekly 29% · resets Thu`.
- **Start Window** button — shown only when **no window is currently open**,
  defined as `sessionPercent == 0` OR `sessionResetsAt` is null/in the past.
  (Do NOT use `is_active` for this — live data showed `session.is_active == false`
  while a window was open at 20%, so that flag means "currently the binding limit,"
  not "window open.") Otherwise the button is replaced by a subtle "Window active"
  pulse.
- Reset times rendered as friendly relative strings ("4h 31m", "Thu 3:00 AM").

**Severity → accent color:** `normal` = calm (Claude coral), `warning` = amber,
`critical` = red.

## 8. Mascot spec (SwiftUI-drawn)

The Claude-sparkle (coral asterisk/burst) drawn with SwiftUI `Canvas`/shapes and
animated entirely in code (no external asset, no editor). It renders a
`MascotState`, derived purely from the snapshot:

| State | Trigger | Behavior |
|---|---|---|
| `dormant` | no window open (`sessionPercent == 0` / reset elapsed) | slow idle breathing, eyes half-closed |
| `playing` | session active, `severity == normal` | bouncy idle; bounce speed scales with `sessionPercent` |
| `frantic` | `severity >= warning` | faster motion, sweat drop, worried tilt |
| `wakeup` | transient, after Start ping | quick stretch/pop, then settles into `playing` |
| `needsAuth` | `ConnectionState.needsAuth` | sleepy "zzz" + tooltip "Open Claude Code to refresh" |
| `offline` | `ConnectionState.offline` | dimmed, tiny "no signal" mark |

Derivation lives in one pure function `MascotState(for: ConnectionState) ->
MascotState` so it is trivially testable.

## 9. Start-session flow

1. User taps **Start Window**.
2. Confirm sheet: *"Open a fresh 5-hour window? Sends a minimal `hi` ping."*
3. On confirm, `SessionStarter` runs, using the **absolute** `claude` path
   (resolved at launch from `~/.local/bin/claude`, because GUI apps don't inherit
   the shell PATH):
   `claude -p "hi" --model <cheapest available, e.g. haiku>`
   run headless, output discarded.
4. Mascot plays `wakeup`; `UsageStore` triggers an immediate refresh.
5. Next snapshot shows `five_hour` now active with a new `resets_at` (+5h).

Failure (non-zero exit / binary missing) surfaces an honest inline error, not a
silent success.

## 10. Auth & token handling

- v1 reads the access token from Keychain each poll and relies on Claude Code to
  refresh it during normal use.
- If the token is expired and the call returns `401`, app enters `needsAuth`.
- **v1.1 (deferred):** self-refresh using the stored `refreshToken` against the
  OAuth token endpoint, so NotchPilot stays live even when Claude Code is idle.

## 11. Edge cases & lifecycle

- **No notch** (external display, older Mac, clamshell): fall back to a small
  floating pill centered at the top of the active screen.
- **Multiple displays:** render on the screen that has the notch / is active.
- **Missing `claude` or non-200 Keychain read:** `ConnectionState.noBinary` /
  `needsAuth`, honest empty state.
- **Launch at login:** registered via `SMAppService`, default ON (user chose
  auto-launch). Runs silently as accessory app.

## 12. Security & privacy

- The OAuth token is read locally and sent **only** to `api.anthropic.com`
  (its rightful owner), over HTTPS, read-only `GET`. It is never logged, written
  to disk by NotchPilot, or sent anywhere else.
- No telemetry. No third-party network calls.
- The app calls a private, undocumented endpoint (`/api/oauth/usage`). It may
  change without notice; the app must degrade gracefully (honest states) if the
  response shape or auth changes.

## 13. Dependencies

- **DynamicNotchKit** (SwiftPM) — notch surface + animation.
- Apple frameworks: SwiftUI, Security (Keychain), ServiceManagement
  (`SMAppService`), Foundation (URLSession, Process).
- No JS/Node runtime dependency (ccusage dropped in favor of the official
  endpoint).

## 14. Success criteria

1. Within ~60s of any usage, the notch reflects the same `session %` Claude's own
   `/usage` shows (±1% rounding).
2. Hover reveals session + weekly with correct relative reset times.
3. As severity escalates, the mascot visibly changes mood.
4. Start Window opens a real 5-hour window (verified by the percentage/`resets_at`
   updating) after a single confirm.
5. Pulling the token (signing out of Claude Code) yields an honest `needsAuth`
   state, never a fake number.
6. App launches at login, shows no Dock icon, idles cheaply.

## 15. Deferred (v1.1+)

- Self OAuth refresh (§10).
- Optional ccusage burn-rate / projection overlay.
- Click-to-open `/usage` or claude.ai settings.
- Configurable poll interval and mascot personality.
