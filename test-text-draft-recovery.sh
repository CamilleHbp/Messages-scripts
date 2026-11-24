#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ "$ANDROID_SERIAL" == emulator-* ]]
number="+1555$(date +%s | tail -c 8)"
message="unsent$(date +%s)"
open_chat() { adb_ shell am start -n "$ACT" -a android.intent.action.SENDTO -d "smsto:$number" >/dev/null; }
initial=$(adb_ shell settings get system user_rotation | tr -d '\r')
auto=$(adb_ shell settings get system accelerometer_rotation | tr -d '\r')
cleanup() {
    adb_ shell settings put system user_rotation "$initial"
    adb_ shell settings put system accelerometer_rotation "$auto"
    adb_ shell am force-stop "$PKG"
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM conversations WHERE address='$number';\""
}
trap cleanup EXIT
open_chat
wait_for_text 'content-desc="Send"'
tap_edittext
type_text "$message"
wait_for_text "$message"
adb_ shell settings put system accelerometer_rotation 0
adb_ shell settings put system user_rotation 1
sleep 1
wait_for_text "$message" 3 || { echo '[FAIL] rotation lost fresh text'; exit 1; }
adb_ shell am force-stop "$PKG"
open_chat
wait_for_text "$message" 3 || { echo '[FAIL] reopening lost fresh text'; exit 1; }
echo '[PASS] Unsent text survives rotation and force-stop without leaving the conversation'
