#!/usr/bin/env bash
#
# Archives the iOS app for the App Store and uploads it to App Store Connect,
# where it appears under TestFlight once Apple has processed it.
#
#   scripts/release-testflight.sh 1.0.0          build number = commit count
#   scripts/release-testflight.sh 1.0.0 42       explicit build number
#
# Every upload needs a build number higher than the last one for that version.
# The default is the number of commits on the current branch, which only ever
# grows; pass one explicitly to override.
#
# Needs, once:
#   1. An Apple ID signed into Xcode (Xcode → Settings → Accounts): automatic
#      signing fetches the App Store provisioning profile and the same session
#      performs the upload.
#   2. An app record in App Store Connect for com.andri.safekey.ios. Xcode
#      offers to create one on the first upload; if the name is taken, create
#      the record at https://appstoreconnect.apple.com under another name.
#   3. The CloudKit schema deployed to Production (CloudKit Console →
#      container → Deploy Schema Changes). TestFlight builds use the
#      production environment, so sync fails without it.
#
# The Mac app is not uploaded: the Mac App Store requires the App Sandbox,
# which the Mac app does not adopt. It ships as a notarized DMG instead
# (scripts/release-mac.sh).
#
set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-}"
SCHEME="SafeKeyiOS"
PRODUCT="SafeKey"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/testflight"
ARCHIVE="$OUT/$SCHEME.xcarchive"
EXPORT="$OUT/export"

# Uploads come from the release Xcode, not a beta, unless told otherwise.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$VERSION" ] || { sed -n '2,12p' "$0"; exit 1; }
case "$VERSION" in *[!0-9.]*|"") die "version must look like 1.2.3";; esac
[ -n "$BUILD" ] || BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
case "$BUILD" in *[!0-9]*|"") die "build number must be an integer";; esac

for tool in xcodegen xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

mkdir -p "$OUT"

say "Generating project"
(cd "$ROOT" && xcodegen generate >/dev/null)

say "Archiving $PRODUCT iOS $VERSION ($BUILD) with $(xcodebuild -version | head -1)"
rm -rf "$ARCHIVE"
xcodebuild -project "$ROOT/SafeKey.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
  || { grep -E "error:|ARCHIVE FAILED" "$OUT/archive.log" >&2 || true
       die "archive failed — full log: $OUT/archive.log"; }
[ -d "$ARCHIVE" ] || die "archive failed — full log: $OUT/archive.log"

say "Uploading to App Store Connect"
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions-AppStore.plist" \
  -allowProvisioningUpdates > "$OUT/upload.log" 2>&1 \
  || { grep -E "error:|EXPORT FAILED" "$OUT/upload.log" >&2 || true
       die "upload failed — full log: $OUT/upload.log"; }
grep -E "Upload succeeded|EXPORT SUCCEEDED" "$OUT/upload.log" >&2 || true

say "Done: $PRODUCT $VERSION ($BUILD) is processing in App Store Connect and shows under TestFlight once Apple finishes."
