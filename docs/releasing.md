# Releasing

A release takes three machines and GitHub, and no single one of them can ship a build on its own:

- **The commit machine** holds the OpenPGP key that signs commits and tags. It sets the version, signs, and pushes.
- **GitHub** keeps the source and, from the signed tag, makes one of the two builds (Actions, attested).
- **The signing machine** holds the Apple keys. It checks the signatures, makes the second build itself in a
  throwaway VM, signs only when both builds match, and publishes: the GitHub release, the Homebrew cask, the Ad Hoc
  iPhone build and, on request, TestFlight.

The maintainer's everyday Mac takes no part: it builds nothing that ships and holds no key. Anyone can check a
published release afterwards with `scripts/release-verify.sh`.

```
commit machine              GitHub                               signing machine
scripts/set-version.sh
git commit -S, git tag -s
git push main X.Y.Z   ──▶   tag X.Y.Z starts release.yml:
                            scripts/release-build.sh, attested
                            artifact                       ──▶   scripts/release-publish.sh X.Y.Z
                                                                   the tag and commit signed by the pinned key?
                                                                   GitHub's build attested?
                                                                   the same build in a throwaway VM?
                                                                   type X.Y.Z to confirm
                                                                   Developer ID, notarized DMG
                            release X.Y.Z with the DMG     ◀──     gh release create
                            homebrew-tap: a new commit     ◀──     the cask's version and sha256
                                                                   Ad Hoc to its private host; TestFlight
                                                                   dispatch-release: the record
```

The Pilot account's apps (`yachts.dispatch.pilot.*`) are the default and the published ones: the GitHub release, the
Homebrew cask, Ad Hoc and TestFlight. The stable account's (`yachts.dispatch.*`) take `--stable` and are published
nowhere yet ([ios.md](ios.md), Pilot and stable). Every app of a release has one build number, `CFBundleVersion`: the
commit's UTC time (`20261104.0002`), so both builders stamp the same one.

## Commit machine

`scripts/set-version.sh X.Y.Z` sets `MARKETING_VERSION` of all four apps in `project.yml` and
`Dispatch.xcodeproj/project.pbxproj` (refusing a version that is not newer) and prints the rest:

```sh
git commit -S -m 'X.Y.Z' project.yml Dispatch.xcodeproj/project.pbxproj
git tag -s X.Y.Z -m 'Dispatch X.Y.Z'      # annotated and signed: the signing machine refuses anything else
git push origin HEAD:main X.Y.Z
```

Tags are `X.Y.Z`, no `v`. A tag never moves once pushed: a broken release gets the next version.

## Two builders

`scripts/release-build.sh OUT --commit SHA --build-number N [--stable]` is the whole build, the same on both builders:
`./run.sh --prod --just-build` for the Mac app and `./run.sh --archive` for the iPhone app with its watch app, built
unsigned and then signed ad hoc with each target's entitlements (Xcode signs iOS code only with a team; the watch's App
Group, `group.<prefix>.mobile`, has to survive the signing machine's export). It insists on a fresh tree (`git
archive` of the commit, no `build/`) at `/private/tmp/dispatch-build`, because source paths end up in the binaries.
`OUT` gets `Dispatch-Pilot-unsigned.zip` (stable: `Dispatch-unsigned.zip`), `Dispatch.app.dSYM.zip`,
`DispatchMobile.xcarchive.zip` and `build.json`: variant, version, build number, commit, builder, the Xcode and macOS
builds, and each zip's bundle id and SHA-256.

- **GitHub.** `.github/workflows/release.yml` runs on every pushed `X.Y.Z` tag (and by hand, from the tag, for
  `--stable`'s apps). It checks the tag matches `project.yml`, selects the Xcode named in `scripts/release.lock.json`
  (`/Applications/Xcode_<version>.app`; only the `xcode-27` runner image, a public preview, has Xcode 27), builds,
  attests every file (`actions/attest-build-provenance`: GitHub signs that this workflow made it from this tag and
  commit on a GitHub-hosted runner) and keeps them as the artifact `dispatch-<variant>-X.Y.Z` for 90 days. It uses no
  secret; its actions are pinned by commit.
- **The VM.** `scripts/release-vm-build.sh`, run by `release-publish.sh`, clones a Tart VM from the image pinned in
  `scripts/release.lock.json` (`vm_image`, by digest; `DISPATCH_BUILD_IMAGE` overrides it), copies the verified tree in,
  builds with the guest's Xcode whose build is the one GitHub's `build.json` names, copies the result out and deletes
  the VM. Nothing of the signing machine (keys, keychain, settings) enters it.

`scripts/release-compare.py A.app B.app` decides whether two builds are the same: the same files and links with the
same executable bits and contents, Mach-O files compared without their signatures (but with the same entitlements),
`Info.plist` files without `BuildMachineOSBuild` (the runner's macOS differs from the VM's), and compiled asset
catalogs by their renditions and SHA-1s (`assetutil --info`: actool stores the same renditions in a varying order).
It compares both Mac apps and both iPhone apps. When they differ, nothing is signed. Expect that when the two used different Xcode builds (GitHub
moves its image to a newer Xcode build about weekly: give the VM image that build too, or wait) and whenever a build
step stops being deterministic: fix the build, never the comparison.

## Signing machine

macOS on Apple Silicon with Xcode (export needs it, not just the Command Line Tools), [Tart](vm_testing.md) for the VM
build (the image is about 60 GB, downloaded on the first build), GnuPG (`gpg`) and `gh`. Three clones side by side:
`dispatch` (this repository; its checkout only bootstraps the checks, see below), `dispatch-release` (private: the
record and the work folders) and `homebrew-tap`; `DISPATCH_RELEASE_REPO` and `DISPATCH_TAP` in
`~/.config/dispatch-release/release.env` move the last two. `gh` is logged in with a token that may create releases in
`paulmillr/dispatch` and read its Actions artifacts; git may push to `dispatch-release` and `homebrew-tap`. Per account:

| What | Where |
| --- | --- |
| The commit key: an OpenPGP public key and its pinned fingerprint | `~/.config/dispatch-release/gnupg`, `release.env` (`DISPATCH_COMMIT_KEY`) |
| Developer ID Application and Apple Distribution certificates with their private key | Login keychain, from the account's `.p12` |
| Apple's intermediates (Developer ID G2, WWDR G3) | Login keychain |
| App Store Connect API key (Users and Access, Integrations, Team Keys; App Manager role) | `~/.config/dispatch-release/AuthKey_<KEY ID>.p8` |
| notarytool credentials from that key | Keychain, profile `dispatch-<variant>-notary` |
| Ad Hoc profiles of the phone app, the watch app and its widgets | `~/.config/dispatch-release/<variant>-adhoc-profiles/*.mobileprovision` |
| App Store profiles of the same three (TestFlight only) | `~/.config/dispatch-release/<variant>-profiles/*.mobileprovision` |
| Settings | `~/.config/dispatch-release/<variant>.env`, `<variant>-adhoc.env` |

Once:

1. `scripts/release-signer-setup.sh trust COMMIT_KEY.asc FINGERPRINT`: the commit machine's public key
   (`gpg --export --armor KEYID`) and the fingerprint as that machine shows it (`gpg --fingerprint KEYID`), read off
   its screen rather than copied with the file. Only this key is in the keyring the checks use.
2. `scripts/release-signer-setup.sh pilot KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID`: KEYS_DIR is the unzipped keys folder,
   one `.p12` and the intermediates (macOS asks for the `.p12`'s password). In App Store Connect the app must exist
   first for TestFlight (My Apps, +, New App: iOS, bundle id `yachts.dispatch.pilot.mobile`, any SKU).
3. The profiles, made in the developer portal (Certificates, Identifiers & Profiles), once and again when the
   certificate expires, a capability changes or (Ad Hoc) a device is added:
   1. Identifiers: the App Group `group.yachts.dispatch.pilot.mobile`, and the App IDs `yachts.dispatch.pilot.mobile`
      (no capabilities), `….mobile.watchkitapp` and `….mobile.watchkitapp.widgets` (App Groups, with that group).
   2. Profiles, +, Distribution: Ad Hoc (and for TestFlight: App Store Connect), one per App ID, certificate Apple
      Distribution. Download them into the folders above.

   `release-publish.sh` checks them (team, kind, not expired, the App Group on the two watch ones, made for this
   machine's Apple Distribution certificate; it names what is wrong), installs them where Xcode looks and names them
   in the export options. Signing is manual because automatic signing from the command line needs an Admin API key
   (Apple's cloud-managed certificates; an App Manager key gets "Cloud signing permission error"). Xcode's own profiles
   ("iOS Team Store Provisioning Profile: …") do not serve: Xcode refuses an Xcode-managed profile for manual signing.

Each release: `scripts/release-publish.sh X.Y.Z [--stable] [--no-push] [--yes] [--no-ad-hoc] [--testflight]`.

1. **Source.** It fetches `main` and the tag, and checks with the pinned key alone that the tag is annotated and signed,
   that its commit is signed, that the commit is on `main` and that its apps are `X.Y.Z`. Then the commit's own copy of
   the scripts carries on (the tree is exported to `dispatch-release/work/<variant>/X.Y.Z/source`): what runs with the
   keys comes from a signed commit, whatever this clone has checked out, so only the check above runs from the clone.
2. **Builds.** GitHub's build of that tag, downloaded and checked against its attestation; the VM build; the comparison.
   Then it shows the version, commit, builds and identities and asks for `X.Y.Z` to be typed (`--yes` skips that).
3. **Mac.** `scripts/release-notarize.sh` re-signs every Mach-O and the app with the hardened runtime, a secure
   timestamp and the microphone entitlement, notarizes and staples the app, packs an LZMA DMG, signs, notarizes and
   staples that; the DMG is then checked as `release-verify.sh` checks it. Pilot only: the GitHub release `X.Y.Z` with
   the DMG (its notes give the SHA-256 and the GitHub run), then a new commit "Dispatch X.Y.Z" in the `homebrew-tap`
   clone with the cask's `version` and `sha256`, pushed (never amended or forced).
4. **iPhone.** The Ad Hoc build (below) unless `--no-ad-hoc` or without `<variant>-adhoc.env`. With `--testflight`:
   `xcodebuild -exportArchive` with `method app-store-connect`, `destination upload` and the App Store profiles, then the
   upload with its symbols through the API key; the build appears in TestFlight after Apple's processing, with no
   export compliance question (`Mobile/App/Info.plist` declares `ITSAppUsesNonExemptEncryption` false: SSH is exempt).
   Once, `--testflight --admin-key AuthKey_<ID>.p8` with an Admin key signs automatically instead; revoke the key after.
5. **Record.** `dispatch-release/<variant>/X.Y.Z/`: both builders' `build.json`, `published.json` (team, time, the DMG's
   SHA-256, the release, the cask commit, the upload, the Ad Hoc build and its install page) and `adhoc/`; committed and
   pushed.

`--no-push` does every check and signs, but publishes nothing (no GitHub release, no push, no Ad Hoc deploy, no
upload). After a failure, run it again: notarization resumes from its saved submission ids and a finished part is
skipped (markers in `dispatch-release/work/<variant>/X.Y.Z/`, git-ignored; delete `adhoc.done` there to sign the Ad Hoc
build again, for instance after its address changed). The signer's own clone of `dispatch` is updated only to signed
tags (`git fetch --tags && git verify-tag X.Y.Z && git checkout X.Y.Z`): the signature check runs from it.

### GitHub settings

The checks above hold even if GitHub or the token on the signing machine is misused; these make misuse harder and
visible. In `paulmillr/dispatch`, a ruleset for `main` (require signed commits, block force pushes and deletion) and one
for tags `*.*.*` (only the maintainer creates them; block updates and deletion). `paulmillr/homebrew-tap`: block force
pushes on `main`. Two-factor authentication with a hardware key on the GitHub and Apple accounts. Watch for releases,
tags and tap commits you did not make.

## Checking a release

`scripts/release-verify.sh X.Y.Z --team TEAMID`, on any Mac with `gh` logged in, downloads the GitHub release's DMG
and GitHub's attested build of the tag, and checks that the DMG is an LZMA image of `Dispatch.app` and an
`Applications` link, both signed by `TEAMID`'s Developer ID, notarized, stapled and accepted by Gatekeeper, that its
app is GitHub's build with only signatures and the stapled ticket changed, and that the Homebrew cask names this DMG.
Test the download on a disposable Mac too ([vm_testing.md](vm_testing.md), Checking a release by hand in a clean VM).
The cask's `zap` lists the files of both apps, `yachts.dispatch.app` and `yachts.dispatch.pilot.app` (and the old
`dev.dispatch.local`): keep it that way when either changes what it stores.

## Mac automatic updates

The Mac app has its own updater, using Foundation, CryptoKit, Security and macOS tools; there is no updater dependency.
The first-launch setup sheet (`LocalAgentsConsent`, with the agents question) offers **Keep Dispatch up to date**
checked; existing installations that have not answered get the sheet with that section alone. Nothing is requested
until Continue saves the choice; Ask later saves nothing. Settings › General › Terminal can change the choice and
check manually without enabling it. Unanswered or off (also the default for older settings files), there are no
automatic requests. On, Dispatch checks once a day
while running and downloads newer versions, then offers **Restart and install**. Restart goes through the normal
running-process confirmation and session cleanup. An ordinary quit never installs a pending update.

The feed is `https://raw.githubusercontent.com/paulmillr/homebrew-tap/HEAD/Casks/dispatch.rb`: the cask's literal
`version`, `sha256` and GitHub DMG URL. No Ruby is executed. Publish the GitHub asset first, then update the cask's
version and checksum; the updater sees a release only after the cask changes. Keep those three fields literal and
unique. Versions are numeric dot-separated components; equal or older versions are not installed.

Downloads use ephemeral HTTPS sessions to GitHub and its asset hosts, without cookies or stored credentials.
Dispatch checks the DMG's SHA-256, mounts it read-only, copies the app to a private staging folder beside the installed
app, and checks its version, minimum macOS, architecture, Developer ID signature (including nested code and all
architectures) and Gatekeeper assessment. It leaves quarantine intact. A development/ad hoc build, a read-only or
translocated app, or an app whose directory is not writable cannot update itself; it reports the reason in Settings.
The installed and staged apps exchange paths atomically after quit cleanup. A small system-shell launcher waits for
Dispatch to exit, opens the updated app and removes the previous bundle only if `open` succeeds. No elevated helper
or password prompt is used. If exchange fails, the installed app stays intact; if starting the launcher fails, the
exchange is reversed. An interrupted relaunch can leave a `.Dispatch-update-*` backup beside the app.

### Changing the Apple signing account

Trust comes from the installed app, not the feed or the DMG's checksum. By default, an update must have the running
app's team ID **and** bundle ID and a valid Apple Developer ID Application signature. Renewing a certificate within
the same team needs no change. Before switching teams or bundle IDs, ship a bridge release signed by the old account
with an entry in `Dispatch/Info.plist`'s `DispatchUpdateTrustedIdentities` array:

```xml
<dict>
    <key>team</key><string>NEWTEAM123</string>
    <key>bundle</key><string>yachts.dispatch.app</string>
</dict>
```

Use the actual new team ID; the value above is only an example. Each entry trusts exactly that team/bundle pair.
Keep the old identity in the new release's list if a transition back is needed. Clients that skip the bridge release
cannot trust the new identity automatically and must install that release manually; allow time for adoption before
the switch. A bundle ID change also changes UserDefaults and OS permissions: migrate those separately when making
that transition. The updater does not silently broaden trust to any notarized app.

## Ad Hoc builds

For people who should not join App Store Connect (internal TestFlight testers accept Apple's developer terms) or wait
for Beta App Review (external testers). Each iPhone, and each Apple Watch that should get the watch app, is registered
by UDID (Finder: the phone, click the line under its name; at most 100 iPhones per membership year, a removed one
frees its slot only at renewal). Ad Hoc profiles last a year or until the certificate expires; an installed build stops
launching then, and does not update itself.

After registering a device (developer portal, Devices, +), make the three Ad Hoc profiles again with all the devices and
replace the old ones in `~/.config/dispatch-release/pilot-adhoc-profiles/`. The script prints how many devices each
lists. The export signs the VM's archive with Apple Distribution and those profiles: no Apple review, nothing sent to
Apple, no TestFlight. `dispatch-release/<variant>/X.Y.Z/adhoc/` gets `Dispatch.ipa`, `manifest.plist` and
`index.html`, an install page whose `itms-services://` link installs it from Safari on a listed iPhone (and the watch
app on a listed watch).

The `.ipa` lists every registered device's UDID: each app in it carries its profile (`embedded.mobileprovision`), which
anyone holding the file can read. Serve it only from HTTPS that nobody can list or browse (a valid certificate: an
iPhone installs over nothing else), and share the link only with the testers; the script refuses to publish into a
public GitHub repository.

The install page and the manifest name their addresses, `DISPATCH_ADHOC_URL/<variant>/X.Y.Z/`, from
`~/.config/dispatch-release/pilot-adhoc.env` on the signing machine (`release-signer-setup.sh` leaves it alone).
With `DISPATCH_ADHOC_SITE` there too, the folder of a git clone that the host serves at `DISPATCH_ADHOC_URL`, the
three files go to `<variant>/X.Y.Z/` in it as the variant's only build, `<variant>/index.html` becomes the newest
build's install page, and the clone's branch is rewritten to one commit, pushed with `--force-with-lease`, so no older
`.ipa` stays in its history. A plain folder works too (no commit); then `DISPATCH_ADHOC_DEPLOY`, a shell command run
after the copy, puts it online, for a host that deploys from a folder. Without either, serve `adhoc/` at that address
yourself. Testers open `DISPATCH_ADHOC_URL/pilot/` in Safari on their iPhone and tap Install.

## Builds that are not notarized

A Mac build handed to a tester outside the notarized DMG or the cask (a Debug or development build sent as a file) is
quarantined. "Open Anyway" in System Settings clears the app's launch, not the helper inside it: every tab execs
`dispatch-helper` through `login`, where Gatekeeper judges that unsigned binary on its own and may refuse or hold it, so
new tabs hang after "Last login" (or never get that far). Testers run `xattr -dr com.apple.quarantine
/Applications/Dispatch.app` after "Open Anyway"; users get a notarized release. There is deliberately no code
workaround (such as running an unquarantined copy of the helper).

Diagnosing a tab stuck there on someone else's Mac: ask for the process tree under the app (`ps -ax -o
pid,ppid,stat,command`) while it is stuck and `xattr -l` of the app's helper. A wait of about 10 s before the first
prompt instead is zsh waiting for a stale `~/.zhistory.LOCK` ([integrations](integrations.md), Quit and local shells):
`ls -la ~/.zhistory.LOCK` shows it, and `setopt HIST_FCNTL_LOCK` avoids it.
