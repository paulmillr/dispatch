# Releasing

A release is built on the maintainer's Mac, which holds no signing key, and signed and published on a separate signing
machine, which holds every key and builds nothing. They meet in a private git repository,
[dispatch-release](https://github.com/paulmillr/dispatch-release), cloned next to this one as `../dispatch-release`.
This file is that repository's `README.md` too (`scripts/release-prepare.sh` copies it there with the signing
machine's scripts, `bin/`).

Each release is one folder, `<pilot|stable>/<build>`, with one UTC build number for every app (`20261030.1345`,
`CFBundleVersion`). The Pilot account's apps (`yachts.dispatch.pilot.*`) are the default and the published ones: the
GitHub release, the Homebrew cask and TestFlight. The stable account's (`yachts.dispatch.*`) take `--stable` and are
published nowhere yet ([ios.md](ios.md), Pilot and stable).

```
maintainer                                            signing machine
scripts/release-prepare.sh [--stable]
  builds the Mac app and the iPhone archive,
  keeps a reference copy in tmp/dispatch-release,
  commits <variant>/<build>/ and pushes        ──▶    git pull && bin/release-publish.sh
                                                        Mac: Developer ID, notarized DMG
                                                        iPhone: Apple Distribution, uploaded to TestFlight
git -C ../dispatch-release pull                ◀──      commits the DMG and published.json, pushes
scripts/release-prepare.sh --verify --team TEAMID
```

## Maintainer

`scripts/release-prepare.sh [--stable] [--no-push]` needs a committed checkout and a clean `../dispatch-release`
(`DISPATCH_RELEASE_REPO` overrides the path). It runs `./run.sh --prod --build-number N` for the Mac app and
`./run.sh --archive … --build-number N` for the iPhone app with its watch app. Xcode signs iOS code only with a team,
so the archive is built unsigned and then signed ad hoc with `codesign`, each bundle with its target's entitlements
(the watch's App Group, `group.<prefix>.mobile`), which the signing machine's export keeps. The release folder gets:

| File | What |
| --- | --- |
| `Dispatch-Pilot-unsigned.zip` (stable: `Dispatch-unsigned.zip`) | The Mac app, signed ad hoc |
| `DispatchMobile.xcarchive.zip` | The iPhone archive with its dSYMs |
| `release.json` | Variant, build, commit, and per app its version, bundle id, file and SHA-256 |

Files over 95 MB are refused (GitHub takes at most 100 MB). The reference copy, `tmp/dispatch-release/<variant>/<build>`,
holds `Dispatch.app`, its dSYM, the archive and `COMMIT`: keep it, `--verify` needs it and the dSYMs symbolicate crash
reports.

After the signing machine pushed, `git -C ../dispatch-release pull` and
`scripts/release-prepare.sh --verify [DMG] --team TEAMID` (default: the newest published DMG) checks that the DMG's app is
the reference build with only signatures and the stapled ticket changed, signed by `TEAMID`, notarized and accepted by
Gatekeeper. For a Pilot build it prints the publish steps: the GitHub release tagged `X.Y.Z` and the `homebrew-tap`
cask. Test the download on a disposable Mac before publishing.

## Signing machine

macOS with Xcode (export needs it, not just the Command Line Tools), and per account:

| What | Where |
| --- | --- |
| Developer ID Application and Apple Distribution certificates with their private key | Login keychain, from the account's `.p12` |
| Apple's intermediates (Developer ID G2, WWDR G3) | Login keychain |
| App Store Connect API key (Users and Access, Integrations, Team Keys; App Manager role) | `~/.config/dispatch-release/AuthKey_<KEY ID>.p8` |
| notarytool credentials from that key | Keychain, profile `dispatch-<variant>-notary` |
| Settings | `~/.config/dispatch-release/<variant>.env` |

Once: `git clone git@github.com:paulmillr/dispatch-release.git`, then
`bin/release-signer-setup.sh pilot|stable KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID` sets all of it up (KEYS_DIR: the
unzipped keys folder, one `.p12` and the intermediates; macOS asks for the `.p12`'s password). In App Store Connect the
app must exist first (My Apps, +, New App: iOS, bundle id `yachts.dispatch.pilot.mobile`, any SKU); uploads to a
missing app fail.

Each release: `git pull && bin/release-publish.sh [<variant>/<build>] [--mac-only | --ios-only] [--no-push]`. It takes
the newest folder without `published.json`, checks both zips against `release.json` and their bundle ids against the
variant (an account signs only its own apps), then:

- **Mac.** `bin/release-notarize.sh` re-signs every Mach-O and the app with the hardened runtime, a secure timestamp and
  the microphone entitlement, notarizes and staples the app, packs an LZMA DMG, signs, notarizes and staples that, and
  the DMG is copied into the release folder. It also runs on its own, for a zip from elsewhere
  (`bin/release-notarize.sh ZIP --identity '…' [--profile NAME] [--sha256 HASH]`; without `--sha256` it asks for the
  hash).
- **iPhone.** `xcodebuild -exportArchive` with `method app-store-connect`, `destination upload` and automatic signing
  through the API key: Xcode registers the bundle ids and the App Group and makes the App Store profiles as needed,
  signs the phone app, the watch app and its widgets with Apple Distribution and uploads them with their symbols. The
  build appears in TestFlight after Apple's processing, with no export compliance question: `Mobile/App/Info.plist`
  declares `ITSAppUsesNonExemptEncryption` false (its encryption, SSH, is exempt).

It writes `published.json` (team, time, the DMG and its SHA-256, the upload), commits it with the DMG and pushes. After
a failure, run it again: notarization resumes from its saved submission ids, and a finished part is skipped (markers in
the folder's `export/`, which git ignores with the signed work folders).
