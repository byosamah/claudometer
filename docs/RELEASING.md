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

The project is named **claudometer**. Because `claudometer.vercel.app` is owned by
an unrelated product, the live URL is the team-scoped
**https://claudometer-byosama.vercel.app**, which is what the app's `feedURL`
(`Sources/NotchPilot/UpdateChecker.swift`) points at. If you later add a custom
domain, update that `feedURL`, rebuild, and re-cut the release.

> Deployment protection is disabled on this project so the public can reach the
> page. Re-run `vercel --prod` from `web/` to redeploy after changes.

## 4. Shipping an update later

1. Bump the version in `Info.plist`: raise `CFBundleVersion` (the build number,
   e.g. 1 → 2) and usually `CFBundleShortVersionString` (e.g. 1.0 → 1.1).
2. Update `web/updates.json` to the **same** `version` + `build`.
3. `./package.sh`
4. `gh release create v1.1 Claudometer.dmg --title "Claudometer 1.1" --notes "..."`
5. Redeploy the site (`cd web && vercel --prod`) so the new `updates.json` is
   live. Installed apps then show "Update available · v1.1".

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
