#!/usr/bin/env bash
# tools/prepare_footage.sh <raw-dir> — turns the recordings into what the film
# uses, in public/footage/. Expects in <raw-dir>:
#   iphone-tour.mp4      tools/record_ios.sh … testTour
#   iphone-faceid.mp4    tools/record_ios.sh … testFaceIDShot (lock screen at 8.1 s)
#   iphone-protected.xcresult   … testProtectedScreenshot
#   ipad-tour.mp4, ipad-tour.xcresult   … testTouriPad (landscape, sideways)
#   mac/                 tools/film_mac.sh
# Simulator recordings are variable-rate; everything becomes constant 60 fps
# with short keyframe intervals so every frame seeks exactly. The source
# times the scenes use (src= in src/scenes) belong to one particular
# recording: after re-recording, find the taps again (frame differences) and
# update them.
set -euo pipefail
RAW="$1"
OUT="$(cd "$(dirname "$0")/.." && pwd)/public/footage"; mkdir -p "$OUT"
cfr() { ffmpeg -v error -y -i "$1" "${@:3}" -r 60 -fps_mode cfr -c:v libx264 -preset slow -crf 14 -g 30 -pix_fmt yuv420p -movflags +faststart -an "$2"; }
cfr "$RAW/iphone-tour.mp4" "$OUT/iphone-tour.mp4"
ffmpeg -v error -y -i "$RAW/iphone-faceid.mp4" -ss 7.4 -t 3.2 -r 60 -fps_mode cfr -c:v libx264 -preset slow -crf 14 -g 30 -pix_fmt yuv420p -an "$OUT/iphone-unlock.mp4"
ffmpeg -v error -y -ss 8.1 -i "$RAW/iphone-faceid.mp4" -frames:v 1 "$OUT/iphone-lock.png"
cfr "$RAW/mac/mac-tour.mov" "$OUT/mac-tour.mp4"
cfr "$RAW/ipad-tour.mp4" "$OUT/ipad-tour.mp4" -vf transpose=2
for f in mac-main mac-detail-revealed mac-seed-revealed mac-chain mac-lock; do cp "$RAW/mac/$f.png" "$OUT/"; done
ffmpeg -v error -y -ss 14.5 -i "$OUT/iphone-tour.mp4" -frames:v 1 "$OUT/iphone-home.png"
ffmpeg -v error -y -ss 35.0 -i "$OUT/iphone-tour.mp4" -frames:v 1 "$OUT/iphone-revealed.png"
ffmpeg -v error -y -ss 51.8 -i "$OUT/ipad-tour.mp4" -frames:v 1 "$OUT/ipad-list.png"
for bundle in iphone-protected; do
  tmp=$(mktemp -d); xcrun xcresulttool export attachments --path "$RAW/$bundle.xcresult" --output-path "$tmp" >/dev/null
  python3 - "$tmp" "$OUT/iphone-screenshot-protected.png" <<'PY'
import json, shutil, sys, pathlib
d = pathlib.Path(sys.argv[1])
for e in json.load(open(d / "manifest.json")):
    for a in e.get("attachments", []):
        if (a.get("suggestedHumanReadableName") or "").startswith("promo-protected-screenshot"):
            shutil.copy(d / a["exportedFileName"], sys.argv[2])
PY
done
cp "$(dirname "$0")/../../../Sources/SafeKeyiOS/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png" "$OUT/app-icon.png"
echo "footage ready in $OUT"
