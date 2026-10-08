# Signed macOS downloads

Local builds use ad-hoc signing. A Release build alone is not a notarized download.
For distribution outside the Mac App Store, use a **Developer ID Application**
certificate with its private key, and an Apple Developer Program account with
notarization access. Apple Development certificates do not qualify.

Build on a Mac with Xcode 26 or later:

```sh
./run.sh --prod --just-build
security find-identity -v -p codesigning
```

The app currently builds for the host architecture. Build separately on Apple
silicon and Intel if both app architectures are needed; the universal SSH helper
does not make the app universal.

Store notarization credentials interactively in Keychain once (follow the prompts;
never put passwords, private keys or account-specific settings in the repository):

```sh
xcrun notarytool store-credentials dispatch-notary
```

Package with the exact full identity name or SHA-1 reported above:

```sh
python3 scripts/distribute.py \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --keychain-profile dispatch-notary \
  --output build/distribution/release-1
```

The script requires a new output directory. It copies the Release app, signs all
Mach-O files (including both copies of the macOS helper in Resources), then signs
enclosing bundles with hardened runtime and secure timestamps. Linux helpers and
other resources remain sealed as data. It verifies the signature, submits a ZIP
once, saves the submission ID, waits for acceptance, staples and validates the
ticket, checks Gatekeeper, and creates `Dispatch.zip` plus `SHA256SUMS`. Only this
final ZIP contains the stapled app. The source build remains unchanged. No extra
entitlements or library-validation exceptions are added.

If waiting is interrupted, resume the same submission:

```sh
python3 scripts/distribute.py --resume \
  --keychain-profile dispatch-notary --output build/distribution/release-1
```

If the upload itself was interrupted before `notarization.json` was written,
check `xcrun notarytool history --keychain-profile dispatch-notary` first. Do not
blindly upload again. Save the matching `notarytool info ID --output-format json`
response as `notarization.json` in that output directory before resuming. Rejected
submissions can be diagnosed with `xcrun notarytool log ID --keychain-profile
dispatch-notary`. Keep receipts with the release artifacts; do not commit them.

Release maintainers should test the final app on a disposable Mac, including a
local PTY and an SSH session, before publishing `Dispatch.zip` and `SHA256SUMS`.
The script never launches the app or publishes a GitHub release.

See Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [Developer ID guide](https://developer.apple.com/developer-id/).
