#!/bin/bash
# One-time setup of the signing machine for this app (docs/releasing.md, Signing machine), from its clone of the app's
# repository. Its settings go to ~/.config/<cask>-release (the cask in scripts/release/app.json):
#
#   scripts/release/signer-setup.sh trust COMMIT_KEY.asc FINGERPRINT
#   scripts/release/signer-setup.sh builder [USER]
#   scripts/release/signer-setup.sh VARIANT KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID
#
# trust: the OpenPGP public key that signs release commits (gpg --export --armor KEYID on the machine that
# signs commits), and its primary key's fingerprint as that machine shows it (gpg --fingerprint KEYID), compared here,
# not taken from the file. Imports it into gnupg/ there, a keyring holding only that key, and pins the fingerprint as
# RELEASE_COMMIT_KEY in release.env there: scripts/release-publish.sh signs nothing whose version commit another key
# signed. Run it again after the key changes.
#
# builder: a user for the second build and the Xcode it needs (scripts/release/builder.sh). USER (default builder) becomes a hidden
# standard macOS user nobody logs in as (a random password, never stored); one sudoers line lets you run commands as it
# without a password, checked by visudo before it is installed; the Xcode whose build release/app.json pins is installed
# with xcodes (Homebrew; it asks for your Apple ID) unless /Applications has it, its license accepted and first launch
# run; then it checks that the user cannot read your login keychain or this app's release settings, offers to make
# your home folder private. Then `scripts/release-publish.sh X.Y.Z --build-as-user USER` builds as it (without the
# flag, the build runs as you, with access to your keys). Asks for your password (sudo). Running it again changes only
# what is missing.
#
# VARIANT (one of scripts/release/app.json's, each an Apple account): KEYS_DIR holds one .p12 (the private key with its
# Developer ID Application certificate; macOS asks for its password) and Apple's intermediate certificates (*CA*.cer).
# The .p8 is the account's App Store Connect API key (App Manager role); the issuer id is shown above the keys list.
# Imports the identity into the login keychain (codesign and productsign may use it without asking), copies the API key
# there (0600), stores notarytool credentials from it as <cask>-<variant>-notary, writes <variant>.env there for
# scripts/release-publish.sh, and checks Xcode. Running it again replaces the settings; certificates already in the
# keychain are kept.
set -euo pipefail
config() { python3 -I "$(dirname "${BASH_SOURCE[0]}")/config.py" "$@"; }
CASK="$(config get cask)"
CONFIG="${RELEASE_CONFIG:-$HOME/.config/$CASK-release}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

fail() { echo "error: $*" >&2; exit 1; }

if [[ "${1:-}" == trust ]]; then
  [[ $# == 3 && -f "$2" ]] || fail "usage: scripts/release/signer-setup.sh trust COMMIT_KEY.asc FINGERPRINT"
  fingerprint="$(tr -d ' ' <<< "$3" | tr a-f A-F)"
  [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || fail "'$3' is not a 40-digit OpenPGP fingerprint (gpg --fingerprint KEYID)"
  command -v gpg > /dev/null || fail "no gpg: brew install gnupg"
  rm -rf "$CONFIG/gnupg.next"
  mkdir -p "$CONFIG"
  chmod 700 "$CONFIG"
  mkdir -m 700 "$CONFIG/gnupg.next"
  GNUPGHOME="$CONFIG/gnupg.next" gpg --batch --quiet --import "$2"
  keys="$(GNUPGHOME="$CONFIG/gnupg.next" gpg --batch --with-colons --fingerprint 2> /dev/null | awk -F: '$1 == "pub" { primary = 1; next } $1 == "fpr" && primary { print $10; primary = 0 }')"
  [[ "$keys" == "$fingerprint" ]] || fail "$2 holds ${keys:-no key}${keys:+ (primary fingerprints)}, not exactly $fingerprint"
  echo "$fingerprint:6:" | GNUPGHOME="$CONFIG/gnupg.next" gpg --batch --quiet --import-ownertrust
  rm -rf "$CONFIG/gnupg"
  mv "$CONFIG/gnupg.next" "$CONFIG/gnupg"
  touch "$CONFIG/release.env"
  grep -v '^RELEASE_COMMIT_KEY=' "$CONFIG/release.env" > "$CONFIG/release.env.next" || true
  echo "RELEASE_COMMIT_KEY=$fingerprint" >> "$CONFIG/release.env.next"
  chmod 600 "$CONFIG/release.env.next"
  mv "$CONFIG/release.env.next" "$CONFIG/release.env"
  GNUPGHOME="$CONFIG/gnupg" gpg --batch --fingerprint "$fingerprint"
  echo "Pinned the commit key $fingerprint in $CONFIG/release.env."
  for tool in gh; do
    command -v "$tool" > /dev/null || echo "note: $tool is not installed (docs/releasing.md, Signing machine)"
  done
  exit 0
fi
if [[ "${1:-}" == builder ]]; then
  [[ $# -le 2 ]] || fail "usage: scripts/release/signer-setup.sh builder [USER]"
  user="${2:-builder}" me="$(id -un)"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$user" != "$me" && "$user" != root ]] ||
    fail "'$user' cannot be the build user: a new lowercase name, not yours"
  xcode_build="$(config get xcode_build)" xcode_version="$(config get xcode)"
  find_xcode() {
    local app
    for app in /Applications/Xcode*.app; do
      [[ ! -L "$app" && "$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2> /dev/null | sed -n 's/^Build version //p')" == "$xcode_build" ]] &&
        { echo "$app"; return; }
    done
  }
  echo "The build user $user and Xcode $xcode_version ($xcode_build); sudo asks for your password."
  sudo -v

  # 1. The user: standard, hidden, never logged in as.
  if id "$user" > /dev/null 2>&1; then
    ! dseditgroup -o checkmember -m "$user" admin > /dev/null 2>&1 || fail "$user is an administrator: the build user must not be one"
    echo "User $user: exists"
  else
    sudo sysadminctl -addUser "$user" -fullName "Release builder" -shell /bin/bash -home "/Users/$user" \
      -password "$(openssl rand -base64 30)" 2>&1 | grep -v '^$' || true
    id "$user" > /dev/null 2>&1 || fail "sysadminctl did not create $user"
    sudo createhomedir -c -u "$user" > /dev/null 2>&1 || true
    sudo dscl . -create "/Users/$user" IsHidden 1
    echo "User $user: created (hidden, standard)"
  fi

  # 2. Running commands as it, without a password: one sudoers line, checked before it is installed.
  sudoers="/etc/sudoers.d/release-builder-$user"
  rule="$me ALL=($user) NOPASSWD: ALL"
  if sudo test -f "$sudoers" && sudo grep -qxF "$rule" "$sudoers"; then
    echo "sudoers: $sudoers"
  else
    draft="$(mktemp)"
    printf '# Release builds as %s (scripts/release/signer-setup.sh builder)\n%s\n' "$user" "$rule" > "$draft"
    /usr/sbin/visudo -cqf "$draft" || { rm -f "$draft"; fail "visudo refused the rule '$rule'"; }
    sudo install -m 0440 -o root -g wheel "$draft" "$sudoers"
    rm -f "$draft"
    echo "sudoers: $sudoers installed"
  fi
  sudo -n -u "$user" /usr/bin/true || fail "still cannot run commands as $user without a password"

  # 3. The pinned Xcode, from xcodes when /Applications lacks it.
  app="$(find_xcode)"
  if [[ -z "$app" ]]; then
    command -v xcodes > /dev/null || { echo "Installing xcodes (Homebrew)"; brew install xcodes; }
    echo "Installing Xcode $xcode_version with xcodes (your Apple ID; several GB)"
    xcodes install "$xcode_version" --directory /Applications --experimental-unxip
    app="$(find_xcode)"
    [[ -n "$app" ]] || fail "xcodes installed Xcode $xcode_version, but not build $xcode_build, which release/app.json pins: \
pin the build GitHub's runner has (docs/releasing.md, Two builders)"
  fi
  developer="$app/Contents/Developer"
  sudo env DEVELOPER_DIR="$developer" xcodebuild -license accept
  DEVELOPER_DIR="$developer" xcodebuild -checkFirstLaunchStatus > /dev/null 2>&1 || sudo env DEVELOPER_DIR="$developer" xcodebuild -runFirstLaunch
  echo "Xcode $xcode_build: $app"

  # 4. What the user must not reach.
  mkdir -p "$CONFIG"
  chmod 700 "$CONFIG"
  for secret in "$KEYCHAIN" "$CONFIG/release.env"; do
    [[ -e "$secret" ]] || continue
    ! sudo -n -u "$user" /bin/test -r "$secret" || fail "$user can read $secret: make it readable only by you"
  done
  ! sudo -n -u "$user" /bin/ls "$CONFIG" > /dev/null 2>&1 || fail "$user can list $CONFIG"
  if [[ "$(stat -f %Lp "$HOME")" != 700 ]]; then
    read -r -p "Your home folder is readable by other users ($user too). Make it private (chmod 700 ~)? [y/N] " answer
    if [[ "$answer" == y || "$answer" == Y ]]; then chmod 700 "$HOME"; echo "Home folder: private"
    else echo "note: $user can read what your home folder lets everyone read"; fi
  fi
  echo "$user cannot read your login keychain or $CONFIG."

  echo "Build as it: scripts/release-publish.sh X.Y.Z --build-as-user $user"
  exit 0
fi
usage="usage: scripts/release/signer-setup.sh trust COMMIT_KEY.asc FINGERPRINT | builder [USER] | VARIANT KEYS_DIR AuthKey_KEYID.p8 ISSUER_ID"
[[ $# == 4 ]] || fail "expected 4 arguments, got $#: $*
$usage"
variant="$1" keys="$2" key="$3" issuer="$4"
[[ "$(config variant "$variant" 2> /dev/null)" == "$variant" ]] ||
  fail "the first argument is trust or a variant ($(config get variants | python3 -I -c 'import json,sys; print(", ".join(json.load(sys.stdin)))')), not '$variant'
$usage"
[[ -d "$keys" ]] || fail "no folder '$keys': pass the unzipped keys folder (it holds the .p12)
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
echo "Team $team: $mac_identity"

mkdir -p "$CONFIG"
chmod 700 "$CONFIG"
install -m 600 "$key" "$CONFIG/AuthKey_$key_id.p8"
profile="$CASK-$variant-notary"
echo "Storing notarytool credentials $profile"
xcrun notarytool store-credentials "$profile" --key "$CONFIG/AuthKey_$key_id.p8" --key-id "$key_id" --issuer "$issuer"

umask 077
cat > "$CONFIG/$variant.env" <<EOF
# scripts/release-publish.sh's settings for the $variant account, written by scripts/release/signer-setup.sh.
RELEASE_TEAM=$team
RELEASE_MAC_IDENTITY='$mac_identity'
RELEASE_NOTARY_PROFILE=$profile
RELEASE_ASC_KEY='$CONFIG/AuthKey_$key_id.p8'
RELEASE_ASC_KEY_ID=$key_id
RELEASE_ASC_ISSUER=$issuer
EOF
echo "Wrote $CONFIG/$variant.env."
echo "Publish with: scripts/release-publish.sh X.Y.Z$([[ "$variant" == "$(config variant)" ]] || echo " --variant $variant")"
