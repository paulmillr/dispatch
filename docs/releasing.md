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
| App Store profiles of the phone app, the watch app and its widgets | `~/.config/dispatch-release/<variant>-profiles/*.mobileprovision` |
| notarytool credentials from that key | Keychain, profile `dispatch-<variant>-notary` |
| Settings | `~/.config/dispatch-release/<variant>.env` |

Once: `git clone git@github.com:paulmillr/dispatch-release.git`, then
`bin/release-signer-setup.sh pilot|stable KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID` sets all of it up (KEYS_DIR: the
unzipped keys folder, one `.p12` and the intermediates; macOS asks for the `.p12`'s password). In App Store Connect the
app must exist first (My Apps, +, New App: iOS, bundle id `yachts.dispatch.pilot.mobile`, any SKU); uploads to a
missing app fail.

The iPhone app is signed manually, because automatic signing from the command line needs an Admin API key (Apple's
cloud-managed certificates; an App Manager key gets "Cloud signing permission error" and no profiles). In the developer
portal (Certificates, Identifiers & Profiles), once and again when the certificate expires or a capability changes:

1. Identifiers: the App Group `group.yachts.dispatch.pilot.mobile`, and the App IDs `yachts.dispatch.pilot.mobile` (no
   capabilities), `….mobile.watchkitapp` and `….mobile.watchkitapp.widgets` (App Groups, with that group).
2. Profiles, +, Distribution: App Store Connect, one per App ID, certificate Apple Distribution. Download the three
   into `~/.config/dispatch-release/pilot-profiles/`.

`release-publish.sh` checks them (team, App Store kind, not expired, the App Group on the two watch ones, made for this
Mac's Apple Distribution certificate; it names what is wrong), installs them where Xcode looks and names them in the
export options.

Or let Xcode do steps 1 and 2 once: create a Team Key with the Admin role and run
`bin/release-publish.sh [<variant>/<build>] --ios-only --admin-key AuthKey_<ID>.p8`. It signs automatically with this
Mac's Apple Distribution certificate (Xcode registers the App IDs and the App Group and makes the profiles), uploads,
then copies the profiles Xcode made into `<variant>-profiles/`, checked as above; one made for Apple's cloud-managed
certificate instead is reported, to be edited in the portal. Then revoke the Admin key: later runs sign manually with
the App Manager key.

Each release: `git pull && bin/release-publish.sh [<variant>/<build>] [--mac-only | --ios-only] [--no-push]`. It takes
the newest folder without `published.json`, checks both zips against `release.json` and their bundle ids against the
variant (an account signs only its own apps), then:

- **Mac.** `bin/release-notarize.sh` re-signs every Mach-O and the app with the hardened runtime, a secure timestamp and
  the microphone entitlement, notarizes and staples the app, packs an LZMA DMG, signs, notarizes and staples that, and
  the DMG is copied into the release folder. It also runs on its own, for a zip from elsewhere
  (`bin/release-notarize.sh ZIP --identity '…' [--profile NAME] [--sha256 HASH]`; without `--sha256` it asks for the
  hash).
- **iPhone.** `xcodebuild -exportArchive` with `method app-store-connect`, `destination upload` and manual signing:
  the phone app, the watch app and its widgets with Apple Distribution and their App Store profiles, then the upload
  with their symbols through the API key. The
  build appears in TestFlight after Apple's processing, with no export compliance question: `Mobile/App/Info.plist`
  declares `ITSAppUsesNonExemptEncryption` false (its encryption, SSH, is exempt).

- **Ad Hoc** (`--ad-hoc`, on its own; default: the newest release folder, published or not). The same archive signed with
  Apple Distribution and Ad Hoc profiles, for the devices they list: no Apple review, nothing sent to Apple, no
  TestFlight. The release folder's `adhoc/` gets `Dispatch.ipa`, `manifest.plist` and `index.html`, an install page
  whose `itms-services://` link installs it from Safari on a listed iPhone (and the watch app on a listed watch).

It writes `published.json` (team, time, the DMG and its SHA-256, the upload, the Ad Hoc build and its install page),
merged with what it already records (a part done in another run stays), commits it with the DMG or `adhoc/` and pushes. After
a failure, run it again: notarization resumes from its saved submission ids, and a finished part is skipped (markers in
the folder's `export/`, which git ignores with the signed work folders).

## Ad Hoc builds

For people who should not join App Store Connect (internal TestFlight testers accept Apple's developer terms) or wait
for Beta App Review (external testers). Each iPhone, and each Apple Watch that should get the watch app, is registered
by UDID (Finder: the phone, click the line under its name; at most 100 iPhones per membership year, a removed one
frees its slot only at renewal). Ad Hoc profiles last a year or until the certificate expires; an installed build stops
launching then, and does not update itself.

Once, and again after registering a device: in the developer portal, Devices, + for each UDID, then Profiles, +,
Distribution: Ad Hoc, one per App ID (`yachts.dispatch.pilot.mobile`, `….watchkitapp`, `….watchkitapp.widgets`),
certificate Apple Distribution, all the devices; download the three into
`~/.config/dispatch-release/pilot-adhoc-profiles/` on the signing machine (replacing the old ones). The script checks
them as it does the App Store ones (Distribution: Ad Hoc, unexpired, the App Group, this Mac's certificate) and prints
how many devices each lists.

The `.ipa` lists every registered device's UDID: each app in it carries its profile (`embedded.mobileprovision`), which
anyone holding the file can read. Serve it only from HTTPS that nobody can list or browse (a valid certificate: an
iPhone installs over nothing else), and share the link only with the testers; `--ad-hoc` refuses to publish into a
public GitHub repository.

The install page and the manifest name their addresses, `DISPATCH_ADHOC_URL/<variant>/<build>/`, from
`~/.config/dispatch-release/pilot-adhoc.env` on the signing machine (bin/release-signer-setup.sh leaves it alone).
With `DISPATCH_ADHOC_SITE` there too, the folder of a git clone that the host serves at `DISPATCH_ADHOC_URL`, each
`bin/release-publish.sh --ad-hoc` copies the three files to `<variant>/<build>/` in it as the variant's only build,
makes `<variant>/index.html` the newest build's install page, and rewrites the clone's branch to one commit, pushed
with `--force-with-lease`, so no older `.ipa` stays in its history. Without it, serve `adhoc/` at that address
yourself. Each run signs again (offline, quick): the files name their addresses, which may have changed. Testers open
`DISPATCH_ADHOC_URL/pilot/` in Safari on their iPhone and tap Install.
