#!/usr/bin/env bash
# Posts a successful Face ID match to a booted simulator, on a loop.
#
# The simulator's biometric sensor is driven from the *host*: a prompt raised
# inside the simulator waits for one of these notifications and never completes
# on its own. A UI test running on the device therefore cannot authenticate
# itself — run this alongside the test and every prompt it raises succeeds.
#
#   scripts/simulator_faceid_match.sh <udid> [seconds]
#
# Enrolment (once per simulator) is:
#   xcrun simctl spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
#   xcrun simctl spawn <udid> notifyutil -p com.apple.BiometricKit.enrollmentChanged
set -euo pipefail

UDID="${1:?usage: simulator_faceid_match.sh <udid> [seconds]}"
DURATION="${2:-180}"

xcrun simctl spawn "$UDID" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 >/dev/null 2>&1 || true
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit.enrollmentChanged >/dev/null 2>&1 || true

deadline=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    # pearl = Face ID, fingerTouch = Touch ID. Posting both covers either device.
    xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit_Sim.pearl.match >/dev/null 2>&1 || true
    xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit_Sim.fingerTouch.match >/dev/null 2>&1 || true
    sleep 1
done
