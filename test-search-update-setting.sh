#!/usr/bin/env bash
source "$(dirname "$0")/env.sh"
set -eu -o pipefail

fail() { echo "[FAIL] $*" >&2; exit 1; }
adb_ shell am force-stop "$PKG"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
wait_for_text "General settings" || fail "open the legacy English settings screen"
tap_text "Search" || fail "settings search was unavailable"
type_text "updates"
wait_for_text "Check for updates" 3 || fail "search omitted the update setting"
tap_text "Check for updates" || fail "could not select the result"
wait_for_text "Installed version" 3 || fail "search did not scroll to the update control"
echo "[PASS] search opens the card containing the installed version and update control"
