# Signed macOS downloads

A release is the maintainer's own `./run.sh --prod` build, re-signed and notarized by whoever holds
the **Developer ID Application** certificate (the signer). Re-signing replaces only signatures, so
the maintainer can prove the download is their build: with signatures removed, every executable is
byte-identical. The download is an LZMA-compressed DMG (`Dispatch-<version>.dmg`).

Two scripts, one per role:

| Step | Who | Command |
| --- | --- | --- |
| 1. Build | maintainer | `scripts/release-prepare.sh` |
| 2. Sign and notarize | signer | `scripts/release-notarize.sh Dispatch-unsigned.zip --identity '…'` |
| 3. Verify and publish | maintainer | `scripts/release-prepare.sh --verify Dispatch-<version>.dmg --team TEAMID` |

## 1. Build

```sh
scripts/release-prepare.sh
```

It refuses uncommitted changes to tracked files, runs `./run.sh --prod --just-build`, and keeps a
reference copy in `tmp/dispatch-release/<version>` (git-ignored), so a later `./run.sh` can't replace
it:

- `Dispatch.app`: the reference for step 3.
- `Dispatch.app.dSYM`: the app's symbols; the shipped app is stripped. Keep it to symbolicate crash
  reports from this version (`.ips` files carry the same UUID as `dwarfdump --uuid`).
- `Dispatch-unsigned.zip` and `COMMIT`.

It refuses to overwrite an existing version: bump `MARKETING_VERSION` in `project.yml` first. Send
the zip and `scripts/release-notarize.sh` to the signer, and send the printed SHA-256 over a separate
channel.

## 2. Sign and notarize (signer)

One-time setup: store notarization credentials in the keychain (never in a script or the repo):

```sh
xcrun notarytool store-credentials dispatch-notary --apple-id APPLE_ID --team-id TEAMID
```

Each release:

```sh
scripts/release-notarize.sh Dispatch-unsigned.zip --identity 'Developer ID Application: NAME (TEAMID)'
```

The script needs nothing else from the repository. It:

1. checks the identity (one valid Developer ID Application, by full name or SHA-1), shows the zip's
   SHA-256 and continues only after the signer types `yes` because it matches the hash received
   separately, and checks the `dispatch-notary` credentials, all before signing anything;
2. signs every Mach-O file, deepest first, then the app, with the hardened runtime, a secure
   timestamp and no entitlements (`helper/darwin-universal` is a link to `dispatch-helper`, signed
   once);
3. notarizes and staples the app, so it also passes Gatekeeper offline after leaving the DMG;
4. puts it in an LZMA (`ULMO`) DMG with an `Applications` link, signs, notarizes and staples the DMG,
   and checks it with `spctl`.

Every upload is made once and its submission ID saved (`app-notarization.json`,
`dmg-notarization.json`) before waiting. If anything is interrupted or Apple is slow, run the same
command again: it resumes and never uploads twice. A rejected submission is explained by
`xcrun notarytool log ID --keychain-profile dispatch-notary`.

Everything goes to `Dispatch-signed/` next to the zip. The signer sends back
`Dispatch-signed/Dispatch-<version>.dmg` as is, not repacked: it is the published file,
and its notarization ticket is stapled to it.

## 3. Verify and publish

```sh
scripts/release-prepare.sh --verify ~/Downloads/Dispatch-0.1.0.dmg --team TEAMID
```

It fails unless:

- the DMG is LZMA-compressed, signed by Developer ID `TEAMID`, stapled and accepted by Gatekeeper;
- the app in it differs from the reference copy only in the signatures of its Mach-O files, its
  `_CodeSignature/CodeResources` and the stapled ticket (`Contents/CodeResources`), and its links are
  unchanged;
- each Mach-O file is byte-identical to the reference once both signatures are removed;
- the app is signed by the same team, stapled and accepted by Gatekeeper.

It then prints the SHA-256 and the publishing steps: a GitHub release tagged `X.Y.Z` (no `v`) with
the DMG as its asset, and the new `version` and `sha256` in the tap's `Casks/dispatch.rb`, whose
`url` ends in `Dispatch-#{version}.dmg`.

Test the download on a disposable Mac (a local terminal and an SSH session) before publishing.

## Notes

- The app builds for the host architecture only (`ARCHS: $(NATIVE_ARCH_ACTUAL)`); the cask requires
  Apple silicon. The macOS SSH helper is universal for remote Intel Macs.
- Release builds carry no `com.apple.security.get-task-allow` (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS:
  NO`), which notarization rejects; re-signing drops entitlements anyway.
- A build the signer makes from source can't be verified this way: different Xcode versions, SDKs
  and paths produce different binaries.

See Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [Developer ID guide](https://developer.apple.com/developer-id/).
