# Claudometer: shippable app + landing page

Date: 2026-06-28
Status: approved-by-directive (the session /goal directs delivery; alignment
gathered via AskUserQuestion). Implementation in progress.

## Goal

Two deliverables:

1. Turn the menu-bar usage app (formerly NotchPilot) into a **real, shareable
   macOS app**: anyone can download it, install it, connect it to their own
   Claude, see their own usage, and receive updates from the developer.
2. A **full landing page** in the same Liquid Glass theme, with a Download button.

## Decisions (locked via AskUserQuestion)

- **Name:** Claudometer (Claude + odometer). Domain: free `claudometer.vercel.app`
  for now (one-step swap to a custom domain later).
- **Install (now):** free, unsigned `.dmg` + a right-click -> Open guide.
- **Install (later):** the full Developer-ID codesign + notarize + staple
  pipeline is pre-built and env-gated, so flipping to signed is one step.
- **Updates:** a tiny built-in, zero-dependency updater. It reads a JSON feed the
  developer hosts, compares versions, and surfaces "Update available -> Download".
- **Connect flow:** a friendly first-run onboarding card with a "is Claude Code
  installed?" check, sign-in guidance, and a Recheck button.
- **Landing page:** dark glass, animated one-pager (live sunburst mascot, GSAP),
  hosted on Vercel.
- **News:** a Changelog driven live from GitHub Releases (client-side, no infra).

## Constraints honored

- No third-party Swift deps (the updater is hand-rolled). No `@State`/`@Observable`
  (CLT toolchain lacks the macro plugin): `@StateObject`/`ObservableObject`/
  `@ObservedObject`/`@EnvironmentObject` only. One `@main`; `-parse-as-library`;
  unsandboxed; macOS 26 target. Honest empty states; percent not dollars.
- The data pipeline (`TokenProvider`/`UsageClient`/`UsageService`/`UsageStore`)
  is unchanged. "Connect your Claude" already works: the app reads each user's own
  local Claude Code credential from their Keychain, so everyone sees their own data.

## Part A: the app (Swift)

### A1. Rename NotchPilot -> Claudometer
- `build.sh` `APP_NAME` -> `Claudometer`; executable renamed.
- `Info.plist`: `CFBundleExecutable`/`Name`/`DisplayName` -> `Claudometer`;
  `CFBundleIdentifier` -> `com.osama.claudometer`.
- User-facing + functional strings: Quit menu title, `NSLog` prefixes, `@main`
  type name, debug-log path. Repo *folder* stays `notchpilot` (avoid breaking git).
- The opt-in notch HUD feature is untouched.

### A2. Onboarding (`OnboardingView.swift`, new)
- Shown inside `UsagePanelView` when not connected (state `.needsAuth`/`.noBinary`).
- Three live-checked steps: (1) Install Claude Code [check = `SessionStarter.claudePath() != nil`],
  (2) Sign in [check = a token exists; `.needsAuth` means it does not], (3) You're set.
- A "Get Claude Code" button (opens the Claude Code page) when the CLI is missing,
  and a "Recheck" button that forces `store.poll()`. Never fabricates a percent.
- `UsageStore` exposes `needsOnboarding` and `claudeInstalled` for the view.

### A3. Updater (`UpdateChecker.swift`, new)
- `ObservableObject`. On launch + a "Check for Updates..." menu item, GETs
  `https://claudometer.vercel.app/updates.json`:
  `{ version, build, downloadURL, notes, minimumSystemVersion }`.
- Compares to `Bundle.main` version. If newer, publishes `available` + `downloadURL`.
- UI: a subtle "Update available" row in the panel + a menu item; clicking opens
  the `.dmg` download URL (no in-place install; that would need Sparkle, vetoed).
- Different host from Anthropic, so it cannot affect the 429 back-off logic.

### A4. Packaging (`package.sh`, new)
- Runs `build.sh`, then `hdiutil create` a drag-to-Applications `.dmg`
  (`Claudometer-<version>.dmg`).
- Signing is env-gated: if `SIGN_IDENTITY`/notary creds are set -> Developer-ID
  codesign + `xcrun notarytool submit --wait` + `xcrun stapler staple`; else
  ad-hoc sign and print the "unsigned: right-click -> Open" note.

### A5. Repo + release
- Public GitHub repo `claudometer`; `.dmg` uploaded as a Release asset via
  `gh release create`. `updates.json` `downloadURL` points at the release asset.
- The developer runs the auth + release commands (`gh auth refresh`, then a
  provided one-liner): the agent cannot log into the developer's accounts.

## Part B: the landing page (static, Vercel)

- `web/`: `index.html` + `styles.css` + `main.js` + vendored GSAP (reuse the
  project's, zero network) + `updates.json` + the reused sunburst mascot. Static
  deploy to Vercel.
- **Dark glass** theme: warm charcoal base, coral `#CC785C` accent (severity ramp
  coral -> amber `#E8A33E` -> red `#D94A3F`), frosted glass cards
  (`backdrop-filter`), SF Pro Rounded, tabular digits.
- **Sections:** sticky glass nav (with Download) · hero (live glowing mascot,
  headline, Download, "Requires macOS 26 + Apple Silicon", a floating menu-bar
  mock) · Features (4 glass cards) · How to connect (3 steps, mirrors the app) ·
  real Screenshots · Privacy/trust (token never leaves your Mac; talks only to
  Anthropic; open source) · Changelog (live from the GitHub Releases API) · FAQ ·
  footer.
- **Motion:** GSAP ScrollTrigger reveals, meters that fill in view, live mascot.

## Privacy claim (must stay accurate)

Claudometer sends nothing to the developer. It reads the user's local Claude Code
credential from their Keychain and talks only to Anthropic's usage API. Source is
public.

## Build order

Rename -> onboarding -> updater -> `package.sh` + first `.dmg` -> landing page ->
wire Download/changelog/`updates.json` to the release -> deploy Vercel + cut the
GitHub release (developer-run auth steps).

## Verification

App: `swiftc -parse-as-library -typecheck -swift-version 6
-strict-concurrency=complete Sources/NotchPilot/*.swift`, then `./build.sh`,
relaunch, screenshot the panel/onboarding/update states. Page: open in Chrome,
screenshot light path + scroll, confirm mascot + meters animate.

## Open items (defaults chosen; revisit if needed)

- Bundle id `com.osama.claudometer`.
- Updater opens the `.dmg` download (no in-place install).
- GitHub repo public, named `claudometer`.
