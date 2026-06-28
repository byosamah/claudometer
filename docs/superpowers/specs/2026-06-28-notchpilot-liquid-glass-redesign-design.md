# NotchPilot redesign: menu-bar-first + Liquid Glass

Date: 2026-06-28
Status: approved (design), implementation pending

## Goal

Two user requirements:

1. Redesign the whole app to the newest Apple design language (macOS 26 "Tahoe"
   Liquid Glass): modern, clean, organized, better animation, better coloring.
2. Stop showing the always-on notch pill. Move the mascot to the **menu bar**
   (per the user's screenshot) and add a toggle to keep the notch HUD ("stay")
   or hide it.

## Decisions (locked with the user)

- **Primary surface:** menu bar item; left-click opens a Liquid Glass anchored panel.
- **Menu bar default content:** mood-tinted mascot glyph + session `%`.
- **Visual direction:** Liquid Glass, adaptive (light/dark). Coral as the single
  accent; severity ramp coral -> amber -> red.
- **Menu bar mascot:** crisp vector glyph (NOT the WKWebView). The live GSAP
  mascot plays in the panel (and the notch when pinned).
- **Settings:** inline footer toggles (no separate window) for v1.
- **Offline/signed-out menu bar:** dimmed glyph, no number.
- **Start Window:** single tap (drop the two-tap confirm).

## Non-goals (v1)

- No separate Settings window.
- No menu-bar live animation (static-but-mood-tinted glyph only).
- No change to the data pipeline (`TokenProvider`/`UsageClient`/`UsageService`).

## Architecture

The one-directional data pipeline is unchanged. We add presentation surfaces
that all observe the same `UsageStore` and a new `AppSettings`.

```
                         ┌─ MenuBarController (NSStatusItem + anchored glass NSPanel)
UsageStore ──observed by ─┤
AppSettings ─────────────┴─ NotchWindowController (shown only when pinNotch)
                              both render UsagePanelView / MascotGlyph
```

### New files

- **`AppSettings.swift`** — `UserDefaults`-backed `ObservableObject`.
  `@Published var pinNotch: Bool` (default `false`),
  `@Published var menuBarStyle: MenuBarStyle` (default `.glyphAndPercent`).
  Persists on set. Injected via `@EnvironmentObject`. No `@State`/`@Observable`.
- **`Theme.swift`** — semantic colors + Liquid Glass helpers. One home for the
  palette (coral `#CC785C`, amber `#E8A33E`, red `#D94A3F`, neutral glass tints),
  plus small view helpers so glass usage is consistent.
- **`MascotGlyph.swift`** — a SwiftUI vector sunburst (rays + body + eyes) drawn
  with `Shape`/`Canvas`, tinted by `MascotState`. Lightweight, crisp at 16-22px.
  Mood expression: calm (coral), busy (coral, eyes open), frantic (red, alarmed),
  sleepy (dim, slit eyes), offline (grey). For the menu bar status item.
- **`MenuBarController.swift`** — owns `NSStatusItem` (variable length) whose
  button hosts an `NSHostingView` of `MenuBarLabel` (`MascotGlyph` + `%`).
  Left-click toggles the anchored glass panel; right-click shows an AppKit menu
  (Pin to notch, Launch at Login, Quit). Owns the panel lifecycle + dismissal.
- **`UsagePanelView.swift`** — the redesigned Liquid Glass content, shared by the
  anchored panel and the pinned-notch expanded state: live `MascotView`, "Claude"
  title, big session metric, session + weekly progress bars with reset captions,
  one-tap Start Window (state-aware: Starting… / Window active), footer toggles.

### Modified files

- **`AppEntry.swift`** — create `AppSettings`; boot `MenuBarController`; create
  `NotchWindowController` but only `show()` it when `pinNotch` is true; observe
  `pinNotch` to show/hide live.
- **`NotchWindow.swift` / `NotchRootView.swift`** — restyle the carved panel in
  Liquid Glass; collapsed pill uses `MascotGlyph` + `%`; expanded reuses
  `UsagePanelView`. Gated on `pinNotch`.
- **`UsageStore.swift`** — expose render-ready fractions for progress bars
  (`sessionFraction`, `weeklyFraction` as `Double` 0...1) and keep existing
  strings. Drop reliance on the two-tap confirm in the panel (store keeps the
  method; the new panel calls `confirmStart()` directly on one tap).
- **`build.sh`** — add `-target arm64-apple-macos26.0` to `swiftc` so the Liquid
  Glass APIs resolve without availability fallbacks. (`LSMinimumSystemVersion`
  is already 26.0.)
- **`Resources/mascot.html`** — refine the coral palette and mood transitions
  ("better animation, better coloring"). No structural/API change
  (`window.NotchMascot.setMood` stays).

## The anchored glass panel (why not NSPopover)

`NSPopover` forces its own background material, which fights a real
`.glassEffect()` surface (double material, wrong vibrancy). Instead: a borderless
non-activating `NSPanel` (same float/level approach as the notch window),
positioned just under the status item's screen rect, content built with
`GlassEffectContainer` + `.glassEffect(.regular.tint(accent).interactive(), in:)`
and `.buttonStyle(.glass)`. Dismiss on outside-click / resign-key via a local
`NSEvent` monitor. This gives the authentic Tahoe look with full layout control.

## Visual system

- **Material:** real Liquid Glass, adaptive light/dark.
- **Color:** neutral glass base; Claude coral the only accent; severity ramp
  (coral -> amber -> red) drives mascot mood, the metric color, and bar fills.
- **Type:** SF Pro Rounded; tabular digits for all numbers; clear hierarchy
  (title / metric / caption).
- **Layout:** spacing + alignment grid; progress bars replace text-only readouts.

## Animation

- Panel open: glass scale + fade, staggered content, spring easing.
- Progress bars: spring-animated fills; metric count transitions, not snaps.
- Mascot: keep GSAP; refine mood transitions + palette in `mascot.html`.
- Menu bar glyph: state crossfades on mood change (no continuous animation).

## Incremental rollout (each step builds + is screenshotted)

1. `AppSettings` + `MenuBarController` with static `MascotGlyph` + `%` (notch
   still on). Verify menu bar item renders, left/right-click work.
2. Anchored glass panel (`UsagePanelView`) on click; Start Window wired (one tap).
3. `pinNotch` toggle; hide notch by default; toggle from panel + menu. Verify
   both states.
4. Liquid Glass restyle of the notch HUD (collapsed pill + expanded reuse).
5. Mascot color/motion polish in `mascot.html`; record motion.

## Constraints honored

- No `@State`/`@Observable` (CLT toolchain lacks the macro plugin): use
  `@StateObject`/`ObservableObject`/`@ObservedObject`/`@EnvironmentObject`.
- One `@main` in `AppEntry.swift`; `-parse-as-library`; unsandboxed.
- No third-party Swift deps. No runtime fallbacks (we target macOS 26 directly).
- Honest empty states; percent not dollars; severity drives mood.

## Verification

Per step: `./build.sh`, relaunch, `screencapture` the menu bar / panel / notch,
`cliclick` to drive hover/click, `screencapture -v` to record mascot motion.
Strict bar: `swiftc -parse-as-library -typecheck -swift-version 6
-strict-concurrency=complete Sources/NotchPilot/*.swift`.

## Open items (sensible defaults chosen, revisit if needed)

- Exact panel dimensions and corner radius (tune visually during step 2).
- Whether the pinned notch collapsed pill shows `%` text or glyph-only (decide
  visually in step 4; lean glyph + `%`).
