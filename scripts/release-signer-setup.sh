#!/bin/bash
# One-time setup of the signing machine for one account (README.md, a copy of docs/releasing.md):
#
#   bin/release-signer-setup.sh pilot|stable KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID
#
# KEYS_DIR is the unzipped dispatch-keys.zip: one .p12 (the private key with its Developer ID Application and Apple
# Distribution certificates; macOS asks for its password) and Apple's intermediate certificates (*CA*.cer). The .p8 is
# the account's App Store Connect API key (App Manager role); the issuer id is shown above the keys list.
#
# The iPhone app is signed manually, with App Store profiles made in the developer portal and kept in
# ~/.config/dispatch-release/<variant>-profiles (this creates the folder): the API key needs no Admin role.
#
# Imports the identities into the login keychain (codesign, productsign and xcodebuild may use them without asking),
# copies the API key to ~/.config/dispatch-release (0600), stores notarytool credentials from it under
# dispatch-<variant>-notary, writes ~/.config/dispatch-release/<variant>.env for bin/release-publish.sh, and checks Xcode.
# Running it again replaces the settings; certificates already in the keychain are kept.
set -euo pipefail
CONFIG="${DISPATCH_RELEASE_CONFIG:-$HOME/.config/dispatch-release}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

fail() { echo "error: $*" >&2; exit 1; }
usage="usage: bin/release-signer-setup.sh pilot|stable KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID"
[[ $# == 4 ]] || fail "expected 4 arguments, got $#: $*
$usage"
variant="$1" keys="$2" key="$3" issuer="$4"
[[ "$variant" == pilot || "$variant" == stable ]] || fail "the first argument is pilot or stable, not '$variant'
$usage"
[[ -d "$keys" ]] || fail "no folder '$keys': unzip dispatch-keys.zip and pass the dispatch-keys folder (it holds the .p12)
$usage"
[[ -f "$key" ]] || fail "no file '$key': pass the downloaded AuthKey_<KEY ID>.p8
$usage"
[[ "$issuer" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  fail "'$issuer' is not an Issuer ID (a UUID, shown above the Team Keys table)
$usage"
key_id="$(basename "$key" .p8)"; key_id="${key_id#AuthKey_}"
[[ "$key_id" =~ ^[A-Z0-9]{10}$ ]] || fail "$key: the API key keeps Apple's name, AuthKey_<KEY ID>.p8"

xcodebuild -version > /dev/null 2>&1 ||
  fail "xcodebuild does not run: install Xcode and select it (sudo xcode-select -s /Applications/Xcode.app)"

# Over SSH macOS cannot show its dialogs, so every password is asked here, in the terminal. A locked login keychain
# (an SSH session's usually is) is unlocked first.
security show-keychain-info "$KEYCHAIN" > /dev/null 2>&1 || {
  echo "Unlocking the login keychain (your macOS password)"
  security unlock-keychain "$KEYCHAIN"
}

# Apple's intermediates first: without them codesign cannot build the chain to Apple's root.
shopt -s nullglob
for certificate in "$keys"/*CA*.cer; do
  security import "$certificate" -k "$KEYCHAIN" > /dev/null 2>&1 || true
done
p12s=("$keys"/*.p12)
shopt -u nullglob
[[ ${#p12s[@]} == 1 ]] || fail "$keys must hold exactly one .p12"
read -r -s -p "Password of ${p12s[0]##*/}: " password; echo
# -P puts it in security's arguments for the moment the import takes; the only way without a dialog.
security import "${p12s[0]}" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign -T /usr/bin/productsign \
  -T /usr/bin/xcodebuild || echo "note: import failed or the items exist already; checking the identities"
unset password
# Apple's tools may use the signing keys without a dialog, which an SSH session could not answer.
echo "Allowing codesign and xcodebuild to use the signing keys (your macOS password)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" > /dev/null

# The account's team, from its certificates (Apple's intermediates have no ten-character OU): this machine may hold
# the other account's identities too.
team="$(for certificate in "$keys"/*.cer; do openssl x509 -inform der -in "$certificate" -noout -subject 2>/dev/null; done |
  sed -nE 's/.*OU ?= ?([A-Z0-9]{10})([,/].*)?$/\1/p' | sort -u)"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail "expected the certificates in $keys to name one team, found: ${team:-none}"
identities="$(security find-identity -v -p codesigning)"
mac_identity="$(sed -nE "s/^ *[0-9]+\\) [0-9A-F]{40} \"(Developer ID Application: .*\\($team\\))\"$/\\1/p" <<< "$identities" | head -1)"
[[ -n "$mac_identity" ]] || fail "no valid Developer ID Application identity of team $team (security find-identity -v -p codesigning)"
grep -q "\"Apple Distribution: .*($team)\"" <<< "$identities" ||
  fail "no valid Apple Distribution identity of team $team (security find-identity -v -p codesigning)"
echo "Team $team: $mac_identity, and Apple Distribution"

mkdir -p "$CONFIG"
chmod 700 "$CONFIG"
install -m 600 "$key" "$CONFIG/AuthKey_$key_id.p8"
profile="dispatch-$variant-notary"
echo "Storing notarytool credentials $profile"
xcrun notarytool store-credentials "$profile" --key "$CONFIG/AuthKey_$key_id.p8" --key-id "$key_id" --issuer "$issuer"

umask 077
cat > "$CONFIG/$variant.env" <<EOF
# bin/release-publish.sh's settings for the $variant account, written by bin/release-signer-setup.sh.
DISPATCH_TEAM=$team
DISPATCH_MAC_IDENTITY='$mac_identity'
DISPATCH_NOTARY_PROFILE=$profile
DISPATCH_ASC_KEY='$CONFIG/AuthKey_$key_id.p8'
DISPATCH_ASC_KEY_ID=$key_id
DISPATCH_ASC_ISSUER=$issuer
EOF
mkdir -p "$CONFIG/$variant-profiles" "$CONFIG/$variant-adhoc-profiles"
echo "Wrote $CONFIG/$variant.env."
case "$variant" in pilot) prefix=yachts.dispatch.pilot ;; *) prefix=yachts.dispatch ;; esac
echo "For TestFlight, put the App Store profiles of $prefix.mobile, $prefix.mobile.watchkitapp and"
echo "$prefix.mobile.watchkitapp.widgets in $CONFIG/$variant-profiles (README.md, Signing machine)."
echo "For Ad Hoc builds (--ad-hoc), put the Ad Hoc profiles of the same three in $CONFIG/$variant-adhoc-profiles and"
echo "DISPATCH_ADHOC_URL (and DISPATCH_ADHOC_SITE) in $CONFIG/$variant-adhoc.env."
echo "Publish with: bin/release-publish.sh"
