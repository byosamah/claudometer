# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Claudometer** (formerly NotchPilot; the Swift sources still live under
`Sources/NotchPilot/`, the product/bundle/executable are Claudometer) is a macOS
**accessory app** (no Dock icon) that lives in the **menu bar** showing live
Claude **Max-plan** usage (session + weekly %), fronted by a "Claude sparkle"
mascot. Clicking the menu bar item opens a **Liquid Glass panel** (macOS 26 /
Tahoe) with the meters, reset times, and a one-tap Start Window button. When not
connected it shows an **onboarding card** (`OnboardingView`) guiding install +
sign-in. The original **notch HUD is now opt-in**: hidden by default, shown only
when the user flips "Pin to notch" (the toggle lives in the panel footer and the
right-click menu).

It is built to be **shared**: `package.sh` produces a distributable `.dmg`, a
zero-dependency `UpdateChecker` polls `claudometer-byosama.vercel.app/updates.json`
for new builds, and `web/` is the static landing page (live on Vercel; `.dmg` is a
GitHub Release asset on `github.com/byosamah/claudometer`). See `docs/RELEASING.md`
for the ship steps. (`claudometer.vercel.app` is an unrelated product, hence the
team-scoped domain.)

Design rationale:
- Original: `docs/superpowers/specs/2026-06-28-notchpilot-design.md`.
- Menu-bar-first + Liquid Glass redesign:
  `docs/superpowers/specs/2026-06-28-notchpilot-liquid-glass-redesign-design.md`.
- Ship + landing page:
  `docs/superpowers/specs/2026-06-28-claudometer-ship-and-landing-design.md`.

## Build / run (no Xcode, no SwiftPM)

This machine has **Command Line Tools only**. `xcodebuild` and `.xcodeproj` are
unavailable, and **SwiftPM (`swift build`) is broken here** (its `swift-package`
tool fails to launch). Build by compiling sources directly with `swiftc`.

```sh
./build.sh                 # compile + assemble Claudometer.app + ad-hoc codesign
./package.sh               # build + wrap in Claudometer.dmg (env-gated signing/notarize)
open Claudometer.app        # launch (accessory app: no Dock icon, no window — look at the menu bar)
pkill -f "MacOS/Claudometer"  # stop the running instance before rebuilding

# fast inner loop: typecheck the whole module without bundling
swiftc -parse-as-library -typecheck Sources/NotchPilot/*.swift

# strictest bar (what the code is held to):
swiftc -parse-as-library -typecheck -swift-version 6 -strict-concurrency=complete Sources/NotchPilot/*.swift
```

`package.sh` is ad-hoc (free, unsigned) by default; set `SIGN_IDENTITY` +
`NOTARY_PROFILE` to Developer-ID codesign + notarize + staple the `.dmg`.
The landing page lives in `web/` (static; `python3 -m http.server --directory web`
to preview). hdiutil + screencapture + pkill need the **sandbox disabled**.

`build.sh` passes `-target arm64-apple-macos26.0` so the Liquid Glass APIs
(`.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass/.glassProminent)`)
resolve directly with no availability fallbacks. `LSMinimumSystemVersion` is 26.0.

There are no tests. Verify changes by rebuilding, relaunching, and screenshotting.
The **menu bar item** is top-right (status area); reveal a hidden menu bar (a
full-screen app auto-hides it) with `cliclick m:<x>,1` before capturing. Click the
item with `cliclick c:<x>,11` to open the glass panel (it appears below, right of
the item). The **notch HUD** only exists while pinned; it's top-center, hover it
with `cliclick m:<notchCenterX>,<y≈50>` to expand. Record the GSAP mascot's live
motion with `screencapture -v -V <secs> -R <x,y,w,h> out.mov`.

Dev-loop gotcha: a sandboxed `pkill`/`open`/`screencapture` silently fails (the
command sandbox blocks process control + screen capture), leaving a STALE instance
running while `open` re-activates it — you screenshot the old build and chase
ghosts. Run launch / kill / capture with the sandbox disabled, and verify the kill
(`pgrep -f "MacOS/NotchPilot"`) before rebuilding.

For runtime diagnostics, `NSLog`/`log show` was unreliable here; temporarily append
to a file (`/tmp/notchpilot-debug.log`) and `cat` it for deterministic per-poll evidence.

- **App icon:** `./icon/build-icns.sh` regenerates `Resources/AppIcon.icns` (the
  coral sunburst mascot) from `icon/Claudometer-1024.png`; `Info.plist` sets
  `CFBundleIconFile=AppIcon` and `build.sh` bundles `Resources/`. Verify by
  extracting a rep (`sips -s format png AppIcon.icns ...`), NOT `qlmanage -t` on
  the `.app` (it hangs for 2+ min). Design source: `icon/icon-source.html`.
- **Verifying `web/`:** claude-in-chrome is often not connected; serve with
  `python3 -m http.server --directory web` (sandbox disabled) and delegate
  screenshots to a Playwright subagent. Transparent PNGs need
  `page.screenshot({omitBackground:true})` via `browser_run_code_unsafe` (the
  screenshot tool has no transparency option). `web/` reveals use
  IntersectionObserver + progressive enhancement (`html.js .reveal` hidden) so
  content survives a GSAP/JS failure; GSAP is vendored from raw.githubusercontent.com.

## Hard toolchain constraints (these will bite you)

- **Verify new Apple-SDK APIs by compiling a probe**, don't guess: CLT ships
  SwiftUI as a binary `.swiftmodule` (no `.swiftinterface` to grep). A tiny
  `swiftc -typecheck -target arm64-apple-macos26.0 probe.swift` confirmed the
  Liquid Glass shapes (`GlassEffectContainer`,
  `.glassEffect(.regular.tint(c).interactive(), in: .rect(cornerRadius:))`,
  `.buttonStyle(.glass/.glassProminent)`).
- **Observe a store/settings from a `@MainActor` AppKit controller** with
  `pub.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }`
  — compiles under strict concurrency, and the main-hop reads the post-change
  value (`objectWillChange`/`@Published` fire just BEFORE the property updates).
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

One-directional pipeline, all UI is `@MainActor`. The data layer feeds two
presentation surfaces (menu bar panel = primary, notch HUD = opt-in), both
observing the same `UsageStore` + `AppSettings`:

```
TokenProvider ─> UsageClient ─> UsageService ─> UsageStore ─┬─> MenuBarController (NSStatusItem + glass NSPanel)
(/usr/bin/security)  (GET /api/oauth/usage)  (ObservableObject) ├─> NotchWindowController (shown only when pinNotch)
                                              AppSettings  ─────┘    both render UsagePanelView / MascotGlyph / MascotView
```

- **`UsageModel.swift`** is the data layer (one file): `TokenProvider` reads the
  OAuth token by spawning `/usr/bin/security find-generic-password -s "Claude
  Code-credentials" -w` (NOT native Keychain APIs — that sidesteps the per-app
  ACL prompt). `UsageClient` GETs `https://api.anthropic.com/api/oauth/usage`
  with `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`, decodes into
  `UsageSnapshot`. `UsageService` combines them into a `ConnectionState`
  (`.ok` / `.needsAuth` / `.offline` / `.noBinary` / `.rateLimited`).
- **`UsageStore.swift`** polls `UsageService` every 60s, derives `MascotState`,
  and exposes render-ready values (strings + `sessionFraction`/`weeklyFraction`
  for the meters). Single source of truth the SwiftUI surfaces observe.
- **`AppSettings.swift`** — `UserDefaults`-backed `ObservableObject`: `pinNotch`
  (default false = notch hidden) and `menuBarStyle`. The "stay or hide" toggle.
- **`MenuBarController.swift`** owns the `NSStatusItem` (mood-tinted `MascotGlyph`
  rendered to `NSImage` via `ImageRenderer`, `isTemplate = false` so it keeps the
  coral instead of being template-tinted, + `%` title). Left-click toggles an anchored Liquid Glass
  `NSPanel` (a `NotchPanel`, so its toggles can become key) hosting
  `UsagePanelView`; it fades+drops in and dismisses on an outside click via a
  global `NSEvent` monitor (the status button is excluded so it can toggle).
  Right-click → AppKit menu (Pin to notch / Launch at Login / Quit).
- **`UsagePanelView.swift`** — the redesigned Liquid Glass content shared by the
  menu bar panel and the pinned-notch expanded state. `GlassEffectContainer` +
  `.glassEffect(.regular, in:)`; meters via `UsageBar`; one-tap Start
  (`.buttonStyle(.glassProminent)`); footer toggles bound to `AppSettings` /
  `LoginItem`.
- **`Theme.swift`** — glass layout constants + the `UsageBar` meter (faint track +
  accent fill, spring-animated). Colors live in `MascotView.swift`.
- **`MascotGlyph.swift`** — a crisp VECTOR sunburst (`Canvas`) for the menu bar,
  mood-tinted. NOT the WKWebView (too heavy/blurry at status-item size); the live
  GSAP mascot still plays in the panel + notch.
- **`NotchWindow.swift`** owns the notch `NSPanel` (pinned via `NSScreen`
  geometry). `AppEntry` shows/hides it by subscribing to `AppSettings.$pinNotch`.
- **`NotchRootView.swift`** is the (pinned) collapsed pill + hover-expanded panel,
  now Liquid Glass: `Color.clear.glassEffect(in: shape)` where shape is a rounded
  rect (pill) or the custom `NotchCarveShape` (expanded; flat top at notch width,
  concave flares to full width) — reads as carved out of the notch.
- **`MascotView.swift`** hosts the real Claude sunburst mascot
  (`Resources/mascot.html`, SVG + vendored GSAP) in a transparent WKWebView,
  driven by `window.NotchMascot.setMood(name, intensity)` (moods: idle / playing /
  frantic / wakeup / sleepy / offline). Transparency needs
  `webView.setValue(false, forKey: "drawsBackground")`. `Resources/` is copied
  into the bundle by `build.sh`. The motion logic is the 2nd `<script>` in
  `mascot.html` (after vendored GSAP) as `moods.{name}(intensity)`; `killAll()`
  resets `rayUses`/`sparks`/eyes-x AND body scale between moods, so each mood only
  re-asserts what it animates. The scale reset is load-bearing: a looping yoyo
  breathe to an absolute scale target decays to a frozen, squished mascot unless
  scale is re-baselined to 1 before each re-trigger (setMood re-fires every poll/
  hover). Moods are minimal ("calm & alive": subtle breathe + faint glow + blink).
- **`SessionStarter.swift`** spawns `claude -p "hi" --model haiku` (absolute path)
  to open a window. It augments the child `PATH` (a login item inherits launchd's
  sparse PATH, so an npm/Homebrew `claude` shebang can't find `node`), and the
  watchdog escalates SIGTERM→SIGKILL so a wedged ping never pins `isWaking` on
  "Starting…". **`LoginItem.swift`** wraps `SMAppService.mainApp`.

## Domain facts that are easy to get wrong

- **The usage % is server-side truth**, fetched live from `/api/oauth/usage`. Do
  not estimate it from local token logs (e.g. ccusage); that is a different,
  weaker number. `limit_dollars` is null on Max plans, so render **percent, not
  dollars**.
- **`severity` drives the mascot mood** (`normal` / escalated). Trust the field;
  a `sessionPercent >= 85` backstop exists only as a safety net.
- **`is_active` does NOT mean "5-hour window is open."** It means "currently the
  binding limit." Detect an open window via `sessionHasUsage` (any usage > 0), NOT
  the rounded percent. The Start button only shows when no window is open, and it's
  now **one tap** (`UsageStore.confirmStart()`); the old two-tap arm/confirm flow
  was removed once Start lived in a deliberate panel/HUD.
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
  All polling MUST go through `UsageStore.refresh()`, which owns the `isPolling`
  single-flight guard; never call `UsageService.currentState()` from a new path,
  or a manual poll + the loop can fire two concurrent requests and self-trip 429.

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
