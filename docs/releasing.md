# Releasing

A release takes three machines and GitHub, and no single one of them can ship a build on its own:

- **The commit machine** holds the OpenPGP key that signs commits. It sets the version in a signed commit, the version
  commit, and pushes it to `main`.
- **GitHub** keeps the source and, from the version commit, makes one of the two builds (Actions, attested).
- **The signing machine** holds the Apple keys. It checks the signature, makes the second build itself (as you, or
  with `--build-as-user` as a macOS user that has no keys), signs only when both builds are the same app (or GitHub's
  alone, `--trust-ci`), and publishes: the GitHub release, whose publication creates the tag `X.Y.Z`, then the
  Homebrew cask.

Two commands: `scripts/release.sh X.Y.Z` on the commit machine pushes the version commit, then
`scripts/release-publish.sh X.Y.Z` on the signing machine, run there by hand, waits for GitHub's build and does the
rest. The commit machine has no way into the signing machine. No tag exists before its release does: a version that
fails on the way leaves a version commit on `main` and nothing else; fix the problem and run the same command again.

The iPhone app is released Ad Hoc, to registered devices only, by a third command on the signing machine,
`scripts/release/iphone.sh X.Y.Z` ([iPhone](#iphone)).

The maintainer's everyday Mac takes no part: it builds nothing that ships and holds no key. Anyone can check a
published release afterwards with `scripts/release/verify.sh`, and with `--reproduce` rebuild it byte for byte
([Checking a release](#checking-a-release)).

```
commit machine              GitHub                               signing machine
scripts/release.sh X.Y.Z
  checks, then commit -S,
  push main ─────────────▶  a version commit on main starts
                            release.yml: release/build.sh,
                            attested artifact              ──▶   scripts/release-publish.sh X.Y.Z (by hand)
                                                                   the version commit signed by the pinned key?
                                                                   GitHub's build attested?
                                                                   the same build here?
                                                                   ship X.Y.Z? [y/N]
                                                                   Developer ID, notarized DMG
                            release X.Y.Z with the DMG,    ◀──     a draft release, then published
                            which creates the tag X.Y.Z
                            homebrew-tap: a new commit     ◀──     the cask's version and sha256
```

What is Dispatch's own is in `scripts/release/app.json` and `scripts/release/app.sh`; every other release script is the
same for any app ([Another app](#another-app)). Its one variant is `pilot`, the Pilot account's app
(`yachts.dispatch.pilot.app`, [ios.md](ios.md), Bundle ids): the GitHub release and the Homebrew cask. The build
number, `CFBundleVersion`, is the commit's UTC time (`20261104.0002`), so both builders stamp the same one.

## Commit machine

`scripts/release.sh X.Y.Z [-m NOTES]`, from the commit you want to release (main, or ahead of it). First it checks, and lists
every problem at once: `git`, `gh` (logged in), `gpg`; X.Y.Z newer than the apps' version and not released (no tag
`X.Y.Z` on GitHub), the version files unchanged; main fast-forwarding to HEAD and every commit to push signed (main
accepts only signed commits); GitHub's checks on HEAD green, a rehearsal of the release build included. Once those pass, it signs a throwaway commit object (nothing points to it) to prove signing works
and shows the key's fingerprint: the one the signing machine pins. Then it shows the plan and asks `push X.Y.Z?`. On
yes:

1. `MARKETING_VERSION` of all four apps (the iPhone, watch and widget ones keep in step) set to X.Y.Z in the version
   files `release/app.json` lists: `project.yml`, `project-mobile.yml` and their projects' `project.pbxproj`;
2. the version commit: a signed commit `X.Y.Z` of those files only (other uncommitted changes stay out, and are
   listed), dated in UTC; `-m NOTES` is its body, signed with it: the summary at the top of the release notes
   (`-m "Stability improvements"`);
3. `git push origin HEAD:refs/heads/main`, which starts the release build, and its link;
4. the next step: `scripts/release-publish.sh X.Y.Z` on the signing machine ([Signing machine](#signing-machine)),
   run there by hand; it waits for GitHub's build.

The version commit is the one commit on `main` that sets the version files to X.Y.Z
(`scripts/release/config.py version-commit X.Y.Z origin/main`): the newest whose parent has another version. Run
`release.sh X.Y.Z` again after anything fails: a version commit made but not pushed is pushed; for one already on `main`,
it only prints the publish command again (only for `main`'s own version; an older one is refused). A step that fails
after something changed says what exists and how to go on.

Versions are `X.Y.Z`, no `v`. A version commit never changes once pushed: a broken one gets the next version. The
release's tag `X.Y.Z` is created on GitHub when its release is published, at the version commit, and never moves.
Before releasing a change to the release build, rehearse it (below).

## Two builders

`scripts/release/build.sh OUT --commit SHA --build-number N [--variant NAME]` is the whole build, the same on both
builders. It insists on a fresh tree (`git archive` of the commit, no `build/`) at `/private/tmp/release-build`,
because source paths end up in the binaries, and it restarts itself in a fixed environment: only `DEVELOPER_DIR` and
`RELEASE_BUILDER` kept, `PATH` the system's folders alone (so `python3` is Xcode's), `LANG=en_US.UTF-8` and a fresh
`HOME`, `/private/tmp/release-build-home`. GitHub's runner otherwise brings Homebrew's tools, rustup and its own
settings, which the signing machine's build lacks. Then `scripts/release/app.sh`, the app's own part, builds: for
Dispatch `./build.sh --release`, the Mac app, from `Dispatch.xcodeproj` alone: the iPhone app's package and
its Rust SSH engine are `DispatchMobile.xcodeproj`'s, so the Mac build neither fetches nor builds them. Then
`scripts/release/normalize.py` removes the one thing the app takes from the machine that built it: Xcode writes that
machine's macOS build, `BuildMachineOSBuild`, into every `Info.plist`, which the ad hoc signature seals, so it removes
the key and signs those bundles again, ad hoc, keeping their identifiers, entitlements and flags (the release's
Developer ID signature replaces it anyway). `scripts/release/zip.py` packs the app byte-reproducibly: entries sorted,
every date the build number's time, the files' permissions and nothing else of the file system, stored rather than
compressed. `OUT` gets `Dispatch-<variant>-unsigned.zip`, `Dispatch.app.dSYM.zip` and `build.json`: variant, version,
build number, commit, builder, the Xcode and macOS builds, the app's bundle id and minimum macOS, and the zips'
SHA-256. The same commit with the same Xcode build makes the same app zip on any Mac: its SHA-256 is the comparison.
The dSYM is not: its debug map records offsets in the intermediate object files, which vary between builds whose
linked app is the same; it is never shipped or signed.

- **GitHub.** `.github/workflows/release.yml` runs on every push to `main`. A first job on a small Linux runner
  checks whether the pushed commit is a version commit (`release/config.py changes-version`); other pushes build
  nothing. A version commit is built for the default variant, and by hand from `main` (while it is `main`'s head) or
  from its tag, for another variant if `app.json` has one: `-f variant=NAME`. It selects the Xcode whose
  build is `xcode_build` in `scripts/release/app.json` (by build, not folder name: the image may call a release candidate `Xcode_27.2.app`;
  only the `xcode-27` runner image, a public preview, has Xcode 27) and stops at once without it, builds,
  attests every file (`actions/attest-build-provenance`: GitHub signs that this workflow made it from this commit on
  a GitHub-hosted runner) and keeps them as the artifact `<cask>-<variant>-X.Y.Z` for 90 days. It uses no
  secret; its actions are pinned by commit. It runs Xcode's first launch if the image has not, and its log shows
  `xcodebuild -version` and `-showsdks`.
- **The signing machine.** `scripts/release/rebuild.sh`, shared by `release-publish.sh` and `release/verify.sh
  --reproduce`, runs `scripts/release/builder.sh` once GitHub's build is downloaded: it builds the verified tree with
  this Mac's Xcode whose build is `xcode_build`, copies the result out and removes the build's files. As you by
  default: the build (setup's downloads, the Rust and Xcode builds, the build's own scripts) then runs with access to
  your keys, and the checklist says so. `--build-as-user builder` builds as a standard macOS user (made by
  `release/signer-setup.sh builder`) that can read neither your login keychain nor the release settings, so nothing
  the build runs reaches a key. That is no virtual machine: a flaw in macOS itself that lets one user act as another
  would cross that line, which a VM would make harder.

Identical zips are the expected result. When the two differ, `scripts/release/compare.py A.app B.app` decides
whether they hold the same app, which is accepted with a warning (a build step stopped being deterministic: fix it),
and says how they differ: the same files and links with the
same executable bits and contents, Mach-O files compared without their signatures (but with the same entitlements),
`Info.plist` files without `BuildMachineOSBuild` (the runner's macOS differs from the signing machine's), and compiled asset
catalogs by their renditions and SHA-1s (`assetutil --info`: actool can store the same renditions in a varying
order). When the two Mac apps differ, nothing is signed. Expect that whenever a build step stops being deterministic:
fix the build, never the comparison. Two Xcode builds always differ: the SDK and Xcode builds in every `Info.plist`,
the asset catalog's `AssetStorageVersion` and the C compiler's version in the Linux helpers' `.comment` (the Mach-O
files matched between 27B48 and 27B52). Hence `xcode_build` in `release/app.json`: change it only once GitHub's image has that build,
and install it on the signing machine (`release/signer-setup.sh builder` again, with `xcodes`).

**Rehearsal.** Run the workflow by hand from a branch (Actions, Release build, Run workflow, "Use workflow from" the
branch, or `gh workflow run release.yml --ref BRANCH`): the same build of the branch's commit, kept for a week as
`<cask>-rehearsal-<variant>-<commit>`, not attested, so `release-publish.sh` never takes it for a release. On the
signing machine, `scripts/release/builder.sh` builds the same commit (a `git archive` of it as SOURCE, `--commit`,
`--build-number` from `build.json`, `--xcode-build` its `xcode.build`); the two zips' SHA-256 must match
(`release/compare.py` on the apps says what differs when they do not).
Do that before releasing a change to the build, the workflow or `release/app.json`.

## Signing machine

macOS on Apple Silicon with the Xcode `release/app.json` pins (`release/signer-setup.sh builder` installs it with
`xcodes`), GnuPG (`gpg`) and `gh`. Two clones side by side:
`dispatch` (this repository; its checkout only bootstraps the checks, see below) and `homebrew-tap`
(`RELEASE_TAP` in `~/.config/dispatch-release/release.env` moves it). `gh` is logged in with a fine-grained token for
`paulmillr/dispatch` with Contents: read+write (releases; publishing one creates its tag) and Actions/Attestations:
read (the build and its attestation); git may push to `homebrew-tap`, with a `user.name`
and `user.email` to commit with (`release-publish.sh` checks both before building). Run it in a login shell: over
SSH, `ssh -t signer zsh -lc '…'`, or `gpg` and `gh` from Homebrew are not on `PATH`. Each release works in
`~/.config/dispatch-release/work/<variant>/X.Y.Z/`, on this machine only. Per account:

| What | Where |
| --- | --- |
| The commit key: an OpenPGP public key and its pinned fingerprint | `~/.config/dispatch-release/gnupg`, `release.env` (`RELEASE_COMMIT_KEY`) |
| Developer ID Application and Apple Distribution certificates with their private key | Login keychain, from the account's `.p12` |
| Apple's intermediates (Developer ID G2, WWDR G3) | Login keychain |
| App Store Connect API key (Users and Access, Integrations, Team Keys; App Manager role), for notarization | `~/.config/dispatch-release/AuthKey_<KEY ID>.p8` |
| notarytool credentials from that key | Keychain, profile `dispatch-<variant>-notary` (`<cask>-<variant>-notary`) |
| Settings | `~/.config/dispatch-release/<variant>.env` |
| Optionally, a build user: a standard macOS user without keys, and running commands as it (`--build-as-user`) | `/etc/sudoers.d/release-builder-<user>` |

Once:

1. `scripts/release/signer-setup.sh trust`: pins the commit key, `scripts/release/commit-key.asc` of this clone (or a
   file given after `trust`, `gpg --export --armor KEYID` on the commit machine), exactly one key. It shows the
   fingerprint: compare it once with `gpg --fingerprint` on the commit machine, since the clone came from GitHub. The
   pin stays until `trust` runs again, whatever the repository says later. Only this key is in the keyring the checks
   use.
2. `scripts/release/signer-setup.sh pilot KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID`: KEYS_DIR is the unzipped keys folder,
   one `.p12` and the intermediates (macOS asks for the `.p12`'s password).
3. Optionally, `scripts/release/signer-setup.sh builder`: a build user and the pinned Xcode, re-runnable (without it,
   install the Xcode with `xcodes`, and the build runs as you). It creates `builder`,
   a hidden standard user nobody logs in as (a random password, never stored); installs one sudoers line letting you
   run commands as it without a password (checked by `visudo` first); installs the Xcode whose build `release/app.json`
   pins with `xcodes` (from Homebrew; your Apple ID) unless `/Applications` has it, then accepts its license and runs
   its first launch; checks that `builder` can read neither your login keychain nor `~/.config/dispatch-release`;
   and offers to make your home folder private (`chmod 700 ~`), since `builder` can read whatever it lets everyone
   read. Then publish with `--build-as-user builder`. `sudo` asks for your password.

Each release: `scripts/release-publish.sh X.Y.Z [--variant NAME] [--no-push] [--trust-ci] [--build-as-user USER]`, in the style of `release.sh`: a checklist,
every problem listed at once, one line per step with its time, each step's output in a log in the work folder (named
when the step fails, with how to go on).

1. **Checks.** `main` fetched, the version commit of X.Y.Z found on it and signed by the pinned key alone (a tag
   `X.Y.Z`, there once published, must be that commit). Then the commit's own copy of the scripts carries on (the tree is exported
   to the work folder's `source/`): what runs with the keys comes from a signed commit, whatever this clone has checked
   out, so only those checks run from the clone. It checks the rest before anything long starts: `gh` (logged in,
   reads Actions), the login keychain (unlocked now if it is locked: the one password prompt), the Developer ID
   identity, notarytool's credentials, the tap (clean, a git author, push access), the pinned Xcode and the build user.
2. **Builds.** GitHub's build of the version commit is waited for (up to 10 minutes for it to appear, then while it runs),
   downloaded and checked against its attestation; then the same build here (`release/rebuild.sh`, as `release/verify.sh
   --reproduce` does it). Both `build.json` must name this version, commit, build number, bundle id and Xcode build;
   identical zips pass, the same app in zips that differ is a warning, different apps stop it.
3. **Ship.** It shows the plan and asks `ship X.Y.Z? [y/N]`. Then `scripts/release/notarize.sh` re-signs every
   Mach-O and the app with the hardened runtime, a secure timestamp and the microphone entitlement, notarizes and
   staples the app, packs an LZMA DMG, signs, notarizes and staples that; the DMG is checked as `release/verify.sh`
   checks it. Pilot only: the GitHub release `X.Y.Z` with the DMG (its notes: the version commit's summary, then
   `---`, how to install, the commit and the GitHub run, and how to check it; GitHub shows the DMG's SHA-256),
   created as a draft targeting the version commit and published once the DMG is up, which creates the tag `X.Y.Z`
   there (checked); right after, a new commit "Dispatch X.Y.Z" in the `homebrew-tap` clone with the cask's `version`
   and `sha256`, pushed (never amended or forced).
4. **Record.** `published.json` in the work folder (team, time, the DMG's SHA-256, the release, the cask commit), next
   to both builders' `build.json`. Nothing reads it back: the attestation, the release notes and the cask are what
   anyone can check.

`--no-push` checks, builds and signs, but publishes nothing. `--trust-ci` builds nothing here: it skips the build
user, the Xcode check and the comparison, and signs GitHub's attested build as it is. That build is then the only one,
so a compromised GitHub build or runner would be signed; the release notes say the app was built once, and
`published.json` records `"signed_build": "github"` (`"local"` otherwise). After a failure, run it again: a finished step is skipped (markers in the work folder) and
notarization resumes from its saved submission ids; a release left a draft is published. The signer's own clone of
`dispatch` is updated only to signed commits (`git fetch && git verify-commit COMMIT && git checkout COMMIT`, a
version commit): the signature check runs from it.

### GitHub settings

The checks above hold even if GitHub or the token on the signing machine is misused; these make misuse harder and
visible. In `paulmillr/dispatch`, a ruleset for `main` (require signed commits, block force pushes and deletion) and one
for tags `*.*.*` (only the maintainer creates them, by publishing a release; block updates and deletion). `paulmillr/homebrew-tap`: block force
pushes on `main`. Two-factor authentication with a hardware key on the GitHub and Apple accounts. Watch for releases,
tags and tap commits you did not make.

## Checking a release

`scripts/release/verify.sh X.Y.Z [--team TEAMID] [--reproduce]`, on any Mac with `gh` logged in, downloads the GitHub
release's DMG and GitHub's attested build of the tag's commit, and checks that the DMG is an LZMA image of `Dispatch.app` and an
`Applications` link, both signed by `TEAMID`'s Developer ID (without `--team`, by the team that signed the DMG, which
it names), notarized, stapled and accepted by Gatekeeper, that its
app is GitHub's build with only signatures and the stapled ticket changed, and that the Homebrew cask names this DMG.
GitHub keeps the build for 90 days (its limit for artifacts), so a release can be checked this way for 90 days.

`--reproduce [--build-as-user USER]` also builds the release on your Mac, the way the signing machine does
(`release/rebuild.sh`, the same code), and needs `git`, `gpg`, Apple Silicon and the Xcode build the commit's
`release/app.json` pins in `/Applications` (`brew install xcodes; xcodes install 27.1`; found by build, whatever its folder
is called). First, with the other checks, the commit as the signing machine checks it: the tag's commit must be the
version commit of X.Y.Z on `main` (fetched from GitHub into `refs/release-verify/main`, removed afterwards), signed by
the commit key this checkout pins (`commit_key` in `scripts/release/app.json`, the public key in
`scripts/release/commit-key.asc`, imported into a keyring of its own). Last, after the DMG and
cask, the commit's tree built with its own scripts at `/private/tmp/release-build`, as you (or as USER), about five
minutes, and compared with GitHub's build: identical zips pass, the same app in zips that differ is a warning,
different apps fail. Its work, the zip made here included, stays in `tmp/release-verify/X.Y.Z`. With the DMG checks
(the DMG is GitHub's build, signed), that shows the published app came from the signed commit's source. Releases made
before `release/rebuild.sh` cannot be rebuilt this way: `--reproduce` says so and stops.
Test the download on a disposable Mac too ([vm_testing.md](vm_testing.md), Checking a release by hand in a clean VM).
The cask's `zap` (`brew uninstall --zap dispatch`) first runs `~/.dispatch/bin/dispatch-helper uninstall`, when
there is one ([security](security.md#removing-dispatch): hooks, Pi's extension and `~/.dispatch` go together, or stay
together while a helper runs, with a line saying so), then trashes the app's files, `yachts.dispatch.pilot.app` (and
those of the older `dev.dispatch.local` and `yachts.dispatch.app` builds), `~/.config/dispatch/themes` and the
updater's leftover `.Dispatch-update-*` folders beside the app. It never trashes `~/.dispatch` itself: hooks would
then run a helper that is gone. Keep it that way when the app changes what it stores. The cask has no
`auto_updates true` on purpose: with it, `brew upgrade` skips Dispatch, and users who left the app's updates off
would get none.

## Mac automatic updates

The Mac app has its own updater, using Foundation, CryptoKit, Security and macOS tools; there is no updater dependency.
The first-launch setup sheet (`LocalAgentsConsent`: Chat, Tabs, then the agents question on Prefs) offers **Keep
Dispatch up to date** checked; existing installations that have not answered get the sheet with that section alone.
Nothing is requested until Let's roll! (Continue on the updates-only sheet) saves the choice; Skip saves nothing.
The sheet shows once per Mac, answered or not: `settings.json` records it (`setupShown`), shared by Release and Debug
builds, which keep separate defaults. Settings › General › Updates can change the choice and
check manually without enabling it. Unanswered or off (also the default for older settings files), there are no
automatic requests. On, Dispatch checks once a day
while running and downloads newer versions, then offers **Restart and install** in a sheet on the main window.
**Check for updates** downloads a newer release it finds straight away, without opting in; Settings shows the
download's size and progress, then verification, with **Cancel**, and then **Restart and install** (no sheet: the
click came from Settings). The feed request goes out while the installed app's signature is checked, so a build that
cannot update itself still makes that one request when you click. Restart goes through the normal
running-process confirmation and session cleanup. An ordinary quit never installs a pending update.

The feed is `https://raw.githubusercontent.com/paulmillr/homebrew-tap/HEAD/Casks/dispatch.rb`: the cask's literal
`version`, `sha256` and GitHub DMG URL. No Ruby is executed. Publish the GitHub asset first, then update the cask's
version and checksum; the updater sees a release only after the cask changes. Keep those three fields literal and
unique. Versions are numeric dot-separated components; equal or older versions are not installed.

Downloads use ephemeral HTTPS sessions to `github.com` and `*.githubusercontent.com`, without cookies or stored
credentials. Release downloads redirect to an asset host GitHub has renamed before (`objects.`, then
`release-assets.githubusercontent.com`), so any of its content subdomains is accepted: a rename must not strand every
installed copy, and the feed's checksum and the signature checks vouch for the file, not the host. A refused redirect
names its host in the error. Each download is a plain download task: the async `URLSession.download(for:)` never
reports progress to the delegate, so the size limit (64 KB for the feed, 512 MB for the DMG) would apply only once the
whole file had arrived. A connection that drops or stalls for a minute is tried again after 2, 10 and 30 s, resuming
the partial file when the server allows; a slow one that keeps going may take up to six hours.

The daily check saves when it last ran only once a check completed: a network failure (offline, the Mac just woke, a
dropped connection, a server error) is tried again after 5 min, 30 min and 2 h, then daily, and a relaunch checks at
once. Failures show in Settings with what failed and when ("Could not download Dispatch 0.1.7 (14:05): …"). A check,
download or verification can be cancelled. Turning automatic updates off stops the daily check's work and discards an
update it staged; one started with **Check for updates** stays.
Dispatch checks the DMG's SHA-256, mounts it read-only, copies the app to a private staging folder beside the installed
app, and checks its version, minimum macOS, architecture, Developer ID signature (including nested code and all
architectures) and Gatekeeper assessment. It leaves quarantine intact. A development/ad hoc build, a read-only or
translocated app, or an app whose directory is not writable cannot update itself; it reports the reason in Settings.
The installed and staged apps exchange paths atomically after quit cleanup. A small system-shell launcher waits for
Dispatch to exit, opens the updated app and removes the previous bundle only if `open` succeeds. No elevated helper
or password prompt is used. If exchange fails, the installed app stays intact; if starting the launcher fails, the
exchange is reversed. An interrupted relaunch can leave a `.Dispatch-update-*` backup beside the app, as can a crash,
forced quit or power loss mid-download. Launch removes such folders once they are a day old (younger ones may be
another running copy's download), ejecting a disk image still mounted in one first.

### Changing the Apple signing account

Trust comes from the installed app, not the feed or the DMG's checksum. By default, an update must have the running
app's team ID **and** bundle ID and a valid Apple Developer ID Application signature. Renewing a certificate within
the same team needs no change. Before switching teams or bundle IDs, ship a bridge release signed by the old account
with an entry in `Dispatch/Info.plist`'s `DispatchUpdateTrustedIdentities` array:

```xml
<dict>
    <key>team</key><string>NEWTEAM123</string>
    <key>bundle</key><string>yachts.dispatch.pilot.app</string>
</dict>
```

Use the actual new team ID; the value above is only an example. Each entry trusts exactly that team/bundle pair.
Keep the old identity in the new release's list if a transition back is needed. Clients that skip the bridge release
cannot trust the new identity automatically and must install that release manually; allow time for adoption before
the switch. A bundle ID change also changes UserDefaults and OS permissions: migrate those separately when making
that transition. The updater does not silently broaden trust to any notarized app.

## Another app

The release scripts are the same for every app: copy `scripts/release.sh`, `scripts/release-publish.sh`, the folder
`scripts/release/` without the app's own three files (below) and `.github/workflows/release.yml` into its repository
(a copy, not a shared checkout or a submodule: the signing machine runs only what the app's own signed version commit
holds, and `git archive` leaves submodules out). The two at the top are the two steps: `release.sh` (the commit
machine) and `release-publish.sh` (the signing machine). In `scripts/release/`: `source.sh` (the signed version
commit, then its own scripts), `build.sh` (with `normalize.py` and `zip.py`), `builder.sh` and `rebuild.sh` (the second
build and the comparison, `compare.py`), `notarize.sh`, `verify.sh` (also `--reproduce`), `config.py` (reads
`app.json`), `ui.sh` (the checklist), `signer-setup.sh`, and for an iPhone app `iphone.sh` with `adhoc.py`. The app's own:

- **`scripts/release/app.json`**: `name` (the `.app`, the DMG `<name>-X.Y.Z.dmg`), `repository`, `tap` and `cask`
  (`Casks/<cask>.rb` there: one tap holds every app's cask), `version_files` (where `MARKETING_VERSION` is set),
  `build_log` (optional: shown when GitHub's build fails), `variants` (name to `bundle_id`; the first is the default, `"publish": false` signs without publishing), `entitlements` (the app's, signed in by the signing machine),
  `xcode` and `xcode_build`, and `commit_key`, the fingerprint of the key that signs version commits, with
  that public key in `scripts/release/commit-key.asc` (`gpg --armor --export --export-options export-minimal KEY`), for
  `release/verify.sh --reproduce`.
- **`scripts/release/app.sh`**: builds `<name>.app` and `<name>.app.dSYM` for `RELEASE_VARIANT` with
  `CFBundleVersion` `RELEASE_BUILD_NUMBER` and leaves them in `RELEASE_PRODUCTS`, from a fresh tree, without asking
  anything.

The signing machine keeps each app's settings apart, in `~/.config/<cask>-release` (`release/signer-setup.sh` from that
app's clone), with the tap's clone next to the app's. The cask's `url` must end in `<name>-#{version}.dmg`; an app
updating itself reads the cask the way Dispatch does ([Mac automatic updates](#mac-automatic-updates)).

## iPhone

The iPhone app is released Ad Hoc: signed with Apple Distribution for the iPhones (and Apple Watches) registered in
the developer portal, installed from Safari, with no App Store, TestFlight or Apple review. It is published nowhere
public: the `.ipa` lists every registered device's UDID (each app in it carries its profile,
`embedded.mobileprovision`, which anyone holding the file can read). Nobody can check it against GitHub's attested
build the way `release/verify.sh` checks the DMG, so GitHub builds no iPhone app; the signing machine builds it once,
from the signed version commit.

On the signing machine, after `release-publish.sh` or apart from it:
`scripts/release/iphone.sh X.Y.Z [--variant NAME] [--no-push] [--build-as-user USER]`, in the same checklist style.

1. **Checks.** The version commit of X.Y.Z signed by the pinned key, then the commit's own scripts (in the work
   folder's `iphone/source/`), as `release-publish.sh` does. Then: the team in `<variant>.env`, `<variant>-adhoc.env`
   (below), the login keychain, the Apple Distribution identity, the Ad Hoc profiles (`release/adhoc.py`: the three
   bundle ids, Ad Hoc, unexpired, the App Group on the two watch ones, made for this machine's certificate; it names
   what is wrong), the site's clone (clean, on a branch, not a public GitHub repository), the pinned Xcode and the
   build user.
2. **Build.** `release/builder.sh --platform ios`, as you or as the build user: an `.xcarchive` built unsigned and
   signed ad hoc with each target's entitlements (`release/app.sh`).
3. **Ship.** It shows the plan and asks `ship X.Y.Z for iPhone? [y/N]`. The archive is exported with Apple
   Distribution and the profiles (manual signing) into `Dispatch.ipa`, checked (signature, profile, bundle id,
   version, build), with `manifest.plist` and `index.html`, an install page whose `itms-services://` link installs it
   from Safari on a registered iPhone (and the watch app on a registered watch). Then published (below).

`--no-push` checks, builds and signs, but publishes nothing. After a failure, run it again: a finished step is skipped
(markers in `work/<variant>/X.Y.Z/iphone/`).

### Ad Hoc builds

Each iPhone, and each Apple Watch that should get the watch app, is registered by UDID (Finder: the phone, click the
line under its name; at most 100 iPhones per membership year, a removed one frees its slot only at renewal). Ad Hoc
profiles last a year or until the certificate expires; an installed build stops launching then, and does not update
itself.

Once, and again when the certificate expires, a capability changes or a device is added, in the developer portal
(Certificates, Identifiers & Profiles):

1. Identifiers: the App Group `group.yachts.dispatch.pilot.mobile`, and the App IDs `yachts.dispatch.pilot.mobile`,
   `….mobile.watchkitapp` and `….mobile.watchkitapp.widgets` (the two watch ones with App Groups, that group).
2. Profiles, +, Distribution: Ad Hoc, one per App ID, certificate Apple Distribution, all the devices. Download them
   into `~/.config/dispatch-release/<variant>-adhoc-profiles/` on the signing machine, replacing the old ones.

Signing is manual: automatic signing from the command line needs an Admin API key, and Xcode refuses its own profiles
("iOS Team …", Xcode-managed) for manual signing.

Where the build goes is in `~/.config/dispatch-release/<variant>-adhoc.env` on the signing machine only, never in a
repository: `RELEASE_ADHOC_URL`, the HTTPS address the files are served at (a valid certificate: an iPhone installs over
nothing else), and optionally `RELEASE_ADHOC_SITE`, the folder that address serves, and `RELEASE_ADHOC_DEPLOY`, a shell
command run after the copy (a host deployed from a folder). The three files go to the site's top, replacing the
previous build's: one build is online at a time, and the page names it by its version and the version commit's UTC date,
`0.1.7-20261110`. A git clone's branch is
rewritten to one commit and pushed with `--force-with-lease`, so no older `.ipa` stays in its history. Without either,
serve the work folder's `adhoc/` at that address yourself. Serve it only where nobody can list or browse it, and share
the link only with the testers. Testers open `RELEASE_ADHOC_URL` in Safari on their iPhone and tap Install.

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
