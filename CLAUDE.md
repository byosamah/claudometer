# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NotchPilot is a menu-less macOS **accessory app** that pins a HUD at the MacBook
**notch** showing live Claude **Max-plan** usage (session + weekly %), fronted by a
code-drawn animated "Claude sparkle" mascot. A Start Window button opens a fresh
5-hour usage window on demand.

Full design rationale: `docs/superpowers/specs/2026-06-28-notchpilot-design.md`.

## Build / run (no Xcode, no SwiftPM)

This machine has **Command Line Tools only**. `xcodebuild` and `.xcodeproj` are
unavailable, and **SwiftPM (`swift build`) is broken here** (its `swift-package`
tool fails to launch). Build by compiling sources directly with `swiftc`.

```sh
./build.sh                 # compile + assemble NotchPilot.app + ad-hoc codesign
open NotchPilot.app        # launch (accessory app: no Dock icon, no window — look at the notch)
pkill -f "MacOS/NotchPilot"  # stop the running instance before rebuilding

# fast inner loop: typecheck the whole module without bundling
swiftc -parse-as-library -typecheck Sources/NotchPilot/*.swift

# strictest bar (what the code is held to):
swiftc -parse-as-library -typecheck -swift-version 6 -strict-concurrency=complete Sources/NotchPilot/*.swift
```

There are no tests. Verify changes by rebuilding, relaunching, and screenshotting
the notch (`screencapture -x -R<x>,0,960,300 out.png`; the notch is top-center).
Use `cliclick m:<x>,<y>` to drive hover for the expanded panel. Record the GSAP
mascot's live motion with `screencapture -v -V <secs> -R <x,y,w,h> out.mov`.
For runtime diagnostics, `NSLog`/`log show` was unreliable here; temporarily append
to a file (`/tmp/notchpilot-debug.log`) and `cat` it for deterministic per-poll evidence.

## Hard toolchain constraints (these will bite you)

- **Never use `@State`.** The `SwiftUIMacros` plugin that implements it is NOT
  shipped with Command Line Tools, so any `@State` (or `@Observable`) fails the
  build with "plugin for module SwiftUIMacros not found". Use `@StateObject` +
  `ObservableObject`, `@ObservedObject`, `@EnvironmentObject`, `@Environment`.
  All view/store state in this project follows that pattern on purpose.
- `@main` lives in `AppEntry.swift` (a manual `NSApplication`, not a SwiftUI
  `App`/`Scene`). Exactly one `@main` may exist; sources compile with
  `-parse-as-library` (no top-level code, no `main.swift`).
- Must ship **unsandboxed**: a sandboxed app cannot spawn `/usr/bin/security` or
  reach the Claude CLI's Keychain item.

## Architecture (the data flow is the whole app)

One-directional pipeline, all UI is `@MainActor`:

```
TokenProvider ──> UsageClient ──> UsageService ──> UsageStore ──> NotchRootView
(/usr/bin/security)  (GET /api/oauth/usage)   (ObservableObject)   + MascotView
```

- **`UsageModel.swift`** is the data layer (one file): `TokenProvider` reads the
  OAuth token by spawning `/usr/bin/security find-generic-password -s "Claude
  Code-credentials" -w` (NOT native Keychain APIs — that sidesteps the per-app
  ACL prompt). `UsageClient` GETs `https://api.anthropic.com/api/oauth/usage`
  with `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`, decodes into
  `UsageSnapshot`. `UsageService` combines them into a `ConnectionState`
  (`.ok` / `.needsAuth` / `.offline` / `.noBinary`).
- **`UsageStore.swift`** polls `UsageService` every 60s, derives `MascotState`
  from the snapshot, and exposes render-ready strings. The SwiftUI views observe
  this single store.
- **`NotchWindow.swift`** owns the AppKit side: a borderless non-activating
  `NSPanel` pinned at the notch via `NSScreen` geometry, hosting the SwiftUI view.
- **`NotchRootView.swift`** is the collapsed pill + hover-expanded panel. The expanded
  background is a custom `NotchCarveShape` (flat top spanning the notch width, concave
  flares to full width) fed by `notch.notchWidth` — NOT a RoundedRectangle; it reads
  as carved out of the notch.
- **`MascotView.swift`** hosts the real Claude sunburst mascot
  (`Resources/mascot.html`, an SVG + vendored GSAP animation) in a transparent
  WKWebView, driven by mood via `window.NotchMascot.setMood(name, intensity)`.
  Keep it ONE persistent instance (it's the stable first child of the HStack in
  `NotchRootView`, resized between pill/panel) so the always-visible pill never
  flashes. `Resources/` is copied into the bundle by `build.sh`. Transparency needs
  `webView.setValue(false, forKey: "drawsBackground")`.
- **`SessionStarter.swift`** spawns `claude -p "hi" --model haiku` (absolute path)
  to open a window. **`LoginItem.swift`** wraps `SMAppService.mainApp`.

## Domain facts that are easy to get wrong

- **The usage % is server-side truth**, fetched live from `/api/oauth/usage`. Do
  not estimate it from local token logs (e.g. ccusage); that is a different,
  weaker number. `limit_dollars` is null on Max plans, so render **percent, not
  dollars**.
- **`severity` drives the mascot mood** (`normal` / escalated). Trust the field;
  a `sessionPercent >= 85` backstop exists only as a safety net.
- **`is_active` does NOT mean "5-hour window is open."** It means "currently the
  binding limit." Detect an open window via `sessionPercent > 0`. The Start button
  only shows when no window is open.
- **Reset timestamps have 6 fractional-second digits** (e.g.
  `...:00.220578+00:00`). Parse with `Date.ISO8601FormatStyle`, not
  `ISO8601DateFormatter` (which is brittle on no-fractional / 6-digit variants).
- **Expand the notch panel instantly, not animated.** Animating the window frame
  on expand races the mouse-tracking area and collapses when the pointer moves
  into the panel. The window snaps to full size; SwiftUI crossfades the content.
- **`NSPanel.hasShadow = false`.** A transparent window with rounded/carved content
  otherwise casts a rectangular window shadow that ghosts behind the shape. Let the
  SwiftUI shape cast its own (or none, for the carved look).
- **`/api/oauth/usage` rate-limits (HTTP 429) under rapid requests** and clears the
  instant you stop. The poller treats 429 as `.rateLimited` and backs off 60–300s —
  NEVER fast-retry a 429 (that perpetuates it, looking like a permanent "Offline").
  Dev-loop trap: each launch + diagnostic curl fires a request, so rapid
  rebuild/relaunch can trip it. Steady 60s polling is safe.

## Operational / trust-model notes

- **Token ACL is broad by design.** Reading the token via `/usr/bin/security`
  means the user's first "Always Allow" adds the `security` tool to the keychain
  item's ACL, after which any user-level process can read the Claude credential
  prompt-free. This is an accepted tradeoff (avoids the per-app ACL prompt and an
  entitlement-bearing build) and does not change the threat model: Claude Code
  already stores and reads the same item the same way.
- **The login item binds to the bundle path** at first registration, so moving
  `NotchPilot.app` out of its built location breaks auto-launch until it is
  re-run (and re-registered) from the new path.

## Conventions

- No third-party Swift dependencies (Apple frameworks only). The mascot is the one
  exception: `Resources/mascot.html` vendors GSAP inline (a JS asset, no Swift dep,
  no runtime network).
- Honest empty states only: on missing token / 401 / offline, show the real state,
  never a fabricated percentage.
- Do not add a Co-Authored-By trailer to commits. Do not use em-dashes anywhere.
