#!/usr/bin/env bash
#
# Builds, signs, notarizes and publishes the Mac app.
#
#   scripts/release-mac.sh build 1.0.0            full pipeline, Developer ID
#   scripts/release-mac.sh package 1.0.0 <.app>   DMG + checksum + GitHub Release
#                                                  from an app exported by Xcode
#   scripts/release-mac.sh preview 1.0.0          development-signed DMG, marked
#                                                  pre-release: runs on this Mac,
#                                                  warns on any other
#
# What a proper release needs on this machine, once:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application; only the account holder can create one).
#   2. Notarization credentials stored under the keychain profile name below:
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --apple-id you@example.com --team-id RR9A8973M8 \
#          --password <app-specific password from appleid.apple.com>
#   3. For `build`, an Apple ID signed into Xcode, so the export step can fetch
#      the Developer ID provisioning profile the iCloud entitlement requires.
#      The first time, Xcode's own Organizer (Product → Archive → Distribute
#      App → Developer ID) is the surest route; hand its exported app to
#      `package` afterwards.
#
set -euo pipefail

MODE="${1:-}"
VERSION="${2:-}"
APP_INPUT="${3:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SafeKey}"
TEAM_ID="RR9A8973M8"
SCHEME="SafeKey"
PRODUCT="SafeKey"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/$PRODUCT.xcarchive"
EXPORT="$OUT/export"

usage() { sed -n '2,25p' "$0"; exit 1; }
# Status goes to stderr: several functions hand their result back on stdout
# for `$(...)`, and a stray status line inside that would corrupt the value.
say()   { printf '\n\033[1m%s\033[0m\n' "$*" >&2; }
die()   { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$MODE" ] && [ -n "$VERSION" ] || usage
case "$VERSION" in *[!0-9.]*|"") die "version must look like 1.2.3";; esac

# --- preflight ---------------------------------------------------------------

have_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"
}

developer_id_identity() {
  security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)".*/\1/'
}

have_notary_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1
}

require_tools() {
  for tool in xcodegen xcodebuild xcrun hdiutil codesign shasum gh; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
}

# --- build stages -----------------------------------------------------------

generate() {
  say "Generating project"
  (cd "$ROOT" && xcodegen generate >/dev/null)
}

archive() {
  say "Archiving $PRODUCT $VERSION (Release, hardened runtime)"
  rm -rf "$ARCHIVE"
  xcodebuild -project "$ROOT/SafeKey.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" MARKETING_VERSION="$VERSION" archive \
    | grep -E "error:|warning: .*(sign|entitle)|ARCHIVE (SUCCEEDED|FAILED)" >&2 || true
  [ -d "$ARCHIVE" ] || die "archive failed"
}

export_developer_id() {
  say "Exporting with Developer ID"
  rm -rf "$EXPORT"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" -allowProvisioningUpdates \
    | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" >&2 || true
  [ -d "$EXPORT/$PRODUCT.app" ] || die "export failed — see the note about Xcode's Organizer at the top of this script"
  echo "$EXPORT/$PRODUCT.app"
}

# The archive's own app is signed with the development identity Xcode used to
# build it. Good enough for the Mac that built it; not for anyone else's.
development_app() {
  local app="$ARCHIVE/Products/Applications/$PRODUCT.app"
  [ -d "$app" ] || die "no app in archive"
  echo "$app"
}

notarize() {
  local path="$1"
  say "Notarizing $(basename "$path")"
  local zip="$OUT/notarize-upload.zip"
  rm -f "$zip"
  if [[ "$path" == *.dmg ]]; then
    xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    ditto -c -k --keepParent "$path" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
  xcrun stapler staple "$path" >&2
}

make_dmg() {
  local app="$1" label="$2"
  local name="$PRODUCT-$VERSION$label"
  local staging="$OUT/dmg-staging"
  local dmg="$OUT/$name.dmg"
  say "Packaging $name.dmg"
  rm -rf "$staging" "$dmg"
  mkdir -p "$staging"
  ditto "$app" "$staging/$PRODUCT.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "$PRODUCT $VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$staging"
  [ -f "$dmg" ] || die "DMG was not created"
  echo "$dmg"
}

sign_dmg() {
  local dmg="$1"
  if have_developer_id; then
    codesign --sign "$(developer_id_identity)" --timestamp "$dmg"
  fi
}

checksum() {
  local dmg="$1"
  [ -f "$dmg" ] || die "checksum: no such file $dmg"
  (cd "$(dirname "$dmg")" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
  echo "$dmg.sha256"
}

publish() {
  local dmg="$1" prerelease="$2" notes="$3"
  local tag="v$VERSION"
  [ "$prerelease" = "yes" ] && tag="v$VERSION-preview"
  say "Publishing GitHub release $tag"
  local flags=()
  [ "$prerelease" = "yes" ] && flags+=(--prerelease)
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$dmg" "$dmg.sha256" --clobber >&2
    gh release edit "$tag" --notes-file "$notes" >&2
  else
    gh release create "$tag" "$dmg" "$dmg.sha256" --title "$PRODUCT $VERSION$([ "$prerelease" = "yes" ] && echo " (preview)")" \
      --notes-file "$notes" "${flags[@]}" >&2
  fi
  gh release view "$tag" --json url -q .url
}

release_notes() {
  local prerelease="$1"
  local file="$OUT/notes.md"
  {
    if [ "$prerelease" = "yes" ]; then
      cat <<'EOF'
**Preview build.** Signed for development, not notarized: macOS will warn that it cannot verify the developer on any Mac other than the one that built it. To open it anyway: right-click → Open, then confirm — or allow it under System Settings → Privacy & Security. The notarized release will replace this.

EOF
    fi
    cat <<EOF
## Install

1. Open the DMG and drag **SafeKey** to **Applications**.
2. Verify the download, if you like: \`shasum -a 256 -c $PRODUCT-$VERSION$([ "$prerelease" = "yes" ] && echo "-preview").dmg.sha256\`

Requires macOS 26 or later.

## What it is

A local, fully encrypted vault for wallet seed phrases and private keys, in the shape of Apple's Passwords app. AES-256-GCM over the vault, a master password run through PBKDF2 at a calibrated cost, optional Touch ID, an optional USB security key as a cryptographic second factor, optional self-destruct after repeated wrong passwords, and optional iCloud sync between your own Apple devices — off until you switch it on, and only ever moving ciphertext.

Nothing phones home. There are no accounts and no servers of ours.
EOF
  } > "$file"
  echo "$file"
}

# --- modes -------------------------------------------------------------------

require_tools
mkdir -p "$OUT"

case "$MODE" in
  build)
    have_developer_id || die "no Developer ID Application certificate in the keychain — see the notes at the top of this script, or use: $0 preview $VERSION"
    have_notary_profile || die "no notarization credentials under keychain profile '$NOTARY_PROFILE' — see the notes at the top of this script"
    generate
    archive
    app="$(export_developer_id)"
    notarize "$app"
    dmg="$(make_dmg "$app" "")"
    sign_dmg "$dmg"
    notarize "$dmg"
    checksum "$dmg" >/dev/null
    publish "$dmg" no "$(release_notes no)"
    ;;
  package)
    [ -d "$APP_INPUT" ] || die "package needs the path to an exported $PRODUCT.app"
    codesign --verify --deep --strict "$APP_INPUT" || die "the app's signature does not verify"
    spctl --assess --type execute "$APP_INPUT" >/dev/null 2>&1 || die "Gatekeeper does not accept this app — was it notarized?"
    dmg="$(make_dmg "$APP_INPUT" "")"
    sign_dmg "$dmg"
    if have_notary_profile; then notarize "$dmg"; else say "Skipping DMG notarization (no credentials); the app inside is what Gatekeeper checks"; fi
    checksum "$dmg" >/dev/null
    publish "$dmg" no "$(release_notes no)"
    ;;
  preview)
    generate
    archive
    app="$(development_app)"
    dmg="$(make_dmg "$app" "-preview")"
    checksum "$dmg" >/dev/null
    publish "$dmg" yes "$(release_notes yes)"
    ;;
  *)
    usage
    ;;
esac

say "Done"
