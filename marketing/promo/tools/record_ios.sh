#!/usr/bin/env bash
# tools/record_ios.sh <simulator-udid> <out-basename> <test> [max-seconds]
# Records the simulator while one PromoTourUITests test runs. Writes
# <out>.mp4 and <out>.times: the moment recording started plus every
# PROMO_MARK the test printed, so shots can be found in the footage.
# Build first:  xcodebuild … -scheme SafeKeyiOS -derivedDataPath build/ios-tests build-for-testing
set -u
SIM="$1"; OUT="$2"; ONLY="$3"; MAX="${4:-300}"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
rm -f "$OUT.mp4" "$OUT.rec.log"
xcrun simctl io "$SIM" recordVideo --codec=h264 --force "$OUT.mp4" > "$OUT.rec.log" 2>&1 &
REC=$!
for _ in $(seq 1 100); do grep -q "Recording started" "$OUT.rec.log" 2>/dev/null && break; sleep 0.1; done
python3 -c "import time; print('REC_START %.3f' % time.time())" > "$OUT.times"
cd "$REPO"
TEST_RUNNER_SAFEKEY_PROMO=1 xcodebuild -project SafeKey.xcodeproj -scheme SafeKeyiOS -destination "id=$SIM" \
  -derivedDataPath build/ios-tests -resultBundlePath "$OUT.xcresult" -only-testing:"$ONLY" \
  test-without-building > "$OUT.test.log" 2>&1 &
XB=$!
for _ in $(seq 1 "$MAX"); do
  kill -0 $XB 2>/dev/null || break
  # xcodebuild can linger after the test itself has finished.
  if grep -qE "Test Suite 'Selected tests' (passed|failed)" "$OUT.test.log" 2>/dev/null; then sleep 3; break; fi
  sleep 1
done
kill $XB 2>/dev/null; sleep 0.5; kill -INT $REC
for _ in $(seq 1 150); do grep -q "Wrote video" "$OUT.rec.log" 2>/dev/null && break; sleep 0.2; done
grep -E "PROMO_MARK" "$OUT.test.log" | sed 's/^.*PROMO_MARK/PROMO_MARK/' | awk '!seen[$2]++' >> "$OUT.times"
grep -E "Test Case .*(passed|failed|skipped)" "$OUT.test.log" | sed 's/^[[:space:]]*//'
