#!/usr/bin/env bash
# marketing/capture/film_mac.sh <out-dir> — captures the debug Mac build under PromoDirector.
# Runs a copy with its own bundle identifier: macOS will not give a second
# instance of the installed app's identifier a window, and an identifier used
# by an earlier, killed run can stay marked as running. The copy is ad-hoc
# signed without the iCloud entitlement, which demo mode never uses.
# Build first:  xcodebuild … -scheme SafeKey -derivedDataPath build/mac build
set -u
OUT="$1"; STAMP=$(date +%s)
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO/build/mac/Build/Products/Debug/SafeKey.app"
DST="$HERE/build/SafeKeyPromo-$STAMP.app"
mkdir -p "$HERE/build"; ditto "$SRC" "$DST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.andri.safekey.mac.promo$STAMP" "$DST/Contents/Info.plist"
codesign --force --deep --sign - "$DST" >/dev/null 2>&1
rm -rf "$OUT"; mkdir -p "$OUT"
SAFEKEY_DEMO=1 SAFEKEY_ALLOW_CAPTURE=1 SAFEKEY_PROMO_DIR="$OUT" "$DST/Contents/MacOS/SafeKey" > "$OUT/run.log" 2>&1 &
PID=$!
for _ in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill -0 $PID 2>/dev/null && { echo "still running after 60 s; stopping"; kill $PID; }
grep -E "PROMO_MARK" "$OUT/run.log" | awk '{print $2}' | tr '\n' ' '; echo
