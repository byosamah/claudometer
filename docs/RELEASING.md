# Shipping Claudometer

These are the steps that need *your* accounts (I can't log into GitHub or Vercel
for you). Run them in the Claude Code prompt by prefixing each with `!`, or in a
normal terminal. Everything before this (build, package, the app, the site) is
already done in the repo.

## 0. One-time: re-auth GitHub

Your `gh` token expired. Refresh it:

```sh
gh auth refresh -h github.com -s repo
# or, if that fails:
gh auth login
```

## 1. Create the public repo and push

The local folder is `notchpilot`, but the repo (and all links) use `claudometer`:

```sh
cd /Users/osamakhalil/dev/notchpilot
gh repo create byosamah/claudometer --public --source=. --remote=origin --push
```

If the repo already exists, instead just: `git push -u origin main`.

## 2. Build the DMG and cut the first release

```sh
./package.sh                       # produces Claudometer.dmg (unsigned, free path)
gh release create v1.0 Claudometer.dmg \
  --title "Claudometer 1.0" \
  --notes "First public release: live session + weekly meters, the sparkle mascot, one-tap Start Window, opt-in notch HUD, built-in update checks."
```

The asset is named `Claudometer.dmg` (constant), so the download links on the
site and in `updates.json` (`.../releases/latest/download/Claudometer.dmg`) keep
working across every future release.

## 3. Deploy the landing page to Vercel

```sh
cd web
vercel login          # one-time
vercel --prod
```

The project is named **claudometer**. The canonical live URL is the custom
domain **https://claudometer.osama.me**, which is what the app's `feedURL`
(`Sources/NotchPilot/UpdateChecker.swift`) points at. The older team-scoped
**claudometer-byosama.vercel.app** stays aliased to the same deployment so
builds shipped before the domain switch (<= v1.3 first cut) keep updating;
never remove that alias. (`claudometer.vercel.app` is an unrelated product.)

> Deployment protection is disabled on this project so the public can reach the
> page. Re-run `vercel --prod` from `web/` to redeploy after changes.

## 4. Shipping an update later

1. Bump the version in `Info.plist`: raise `CFBundleVersion` (the build number,
   e.g. 1 → 2) and usually `CFBundleShortVersionString` (e.g. 1.0 → 1.1).
2. Update the `FEED` object in **`web/api/updates.js`** to the **same** `version` +
   `build` + notes. (This is the serverless feed; the old static `web/updates.json`
   was replaced by it so each check can be counted, see below.)
3. `./package.sh`
4. `gh release create v1.1 Claudometer.dmg --title "Claudometer 1.1" --notes "..."`
5. Redeploy the site (`cd web && vercel --prod`) so the new feed is live. Installed
   apps then show "Update available · v1.1".

## 5. Analytics: active-install counter + landing-page analytics

`/updates.json` is served by `web/api/updates.js`, which best-effort counts each
check (total, per app build, per day) in **Upstash Redis** via REST (no npm deps).
It is a no-op until you link a store, and counting never blocks the feed.

One-time provisioning (dashboard, free tier):
1. Vercel → the **claudometer** project → **Storage** → Create → **Upstash for
   Redis** → connect to the project. This injects `KV_REST_API_URL` +
   `KV_REST_API_TOKEN` (the function also accepts `UPSTASH_REDIS_REST_URL/TOKEN`).
2. Add a project env var **`STATS_KEY`** = a random secret (for the read endpoint).
3. Redeploy (`cd web && vercel --prod`) so the function sees the new env vars.

Then read the counts at
`https://claudometer.osama.me/api/stats?key=<STATS_KEY>`
(`{ totalChecks, byBuild, byDay }`). The app appends `?v=<build>&os=<ver>` so
`byBuild` fills in for 1.3+; 1.2 and earlier count as build `unknown`.

Landing-page analytics: enable **Web Analytics** on the same project (Analytics
tab) for pageviews + the `download` conversion event wired in `web/main.js`.

## Going from free to signed (when you're ready)

1. Enroll in the Apple Developer Program ($99/yr) and create a **Developer ID
   Application** certificate (it installs into your login Keychain).
2. Store a notary profile once:
   ```sh
   xcrun notarytool store-credentials claudometer-notary \
     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
   ```
3. Package signed:
   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="claudometer-notary" ./package.sh
   ```
   The DMG is now codesigned, notarized, and stapled: users get a clean
   double-click with no warning. Update the FAQ entry on the site that mentions
   the first-launch warning.

## Note: login-item path binding

The "Launch at Login" registration binds to the app's bundle path. Tell users to
keep `Claudometer.app` in `/Applications`; moving it breaks auto-launch until
they relaunch it from the new location.
