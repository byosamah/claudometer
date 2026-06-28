<div align="center">

# Claudometer

**Your Claude Max usage, live in the macOS menu bar.**

A tiny accessory app that reads your own Claude Code login and shows your
session + weekly limits as Liquid Glass meters, fronted by a coral sparkle
mascot that gets frantic before you do.

[Download](https://github.com/byosamah/claudometer/releases/latest/download/Claudometer.dmg) · [Website](https://claudometer.vercel.app)

</div>

---

## What it is

Claudometer lives in your menu bar (no Dock icon, no window). Click the sparkle
to open a Liquid Glass panel with:

- **Session** and **weekly** usage meters, with exact reset times.
- A **mascot** whose mood tracks your usage (calm → playing → frantic).
- **Start Window** in one tap (fires a tiny `haiku` ping to open a 5-hour clock).
- An opt-in **notch HUD** (off by default; toggle "Pin to notch").
- Built-in **update checking**.

The usage numbers are server-side truth, fetched live from Anthropic's own usage
API, not an estimate from local logs.

## Privacy

Claudometer has **no server and no telemetry**. It reads your local Claude Code
credential from your Keychain and uses it only to call Anthropic's usage API.
Nothing is ever sent to the developer.

## Requirements

- **macOS 26 (Tahoe) or newer** — the UI is built on Liquid Glass.
- **Apple Silicon.**
- **Claude Code** installed and signed in (this is how it reads *your* usage).

## Install

1. Download `Claudometer.dmg` from the [latest release](https://github.com/byosamah/claudometer/releases/latest).
2. Open the DMG and drag **Claudometer** to **Applications**.
3. Early-access builds are not notarized yet, so the first launch shows a
   Gatekeeper warning. **Right-click the app → Open**, then confirm. (Once signed
   builds ship, this step goes away.)

## Build from source

This project builds **without Xcode** (Command Line Tools only), compiling
directly with `swiftc` (SwiftPM is not used here).

```sh
./build.sh                 # compile + assemble + ad-hoc sign Claudometer.app
open Claudometer.app        # launch (look at the menu bar, top-right)
./package.sh                # build a distributable Claudometer.dmg

# fast typecheck of the whole module:
swiftc -parse-as-library -typecheck Sources/NotchPilot/*.swift
```

`build.sh` targets `arm64-apple-macos26.0` so the Liquid Glass APIs resolve with
no availability fallbacks.

### Signing (later)

`package.sh` is pre-wired for Developer-ID signing + notarization. Set
`SIGN_IDENTITY` (and a `notarytool` keychain profile `NOTARY_PROFILE`) and it
will codesign with a hardened runtime, notarize, and staple the `.dmg`. With no
env vars set it produces a free, ad-hoc-signed (unsigned-distribution) build.

## Project layout

- `Sources/NotchPilot/` — the Swift app (data pipeline → menu bar + opt-in notch).
- `Resources/mascot.html` — the live sunburst mascot (SVG + vendored GSAP).
- `web/` — the landing page (static, deploys to Vercel).
- `docs/superpowers/specs/` — design specs.
- `CLAUDE.md` — architecture + toolchain notes.

## License

MIT. See [LICENSE](LICENSE).

Not affiliated with Anthropic. Claude is a trademark of Anthropic.
