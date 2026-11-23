#!/usr/bin/env bash
source "$(dirname "$0")/env.sh"
set -eu -o pipefail

fail() { echo "[FAIL] $*" >&2; exit 1; }
[[ "$(adb_ shell getprop ro.kernel.qemu | tr -d '\r')" = 1 ]] || fail "requires an emulator"
assert_idle_alarms() {
    adb_ shell dumpsys alarm > "$TMP/scheduled-idle-alarms.txt"
    python3 - "$TMP/scheduled-idle-alarms.txt" "$PKG" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
pending = text.partition(" pending alarms:")[2].split("Temporary Quota", 1)[0]
alarms = re.split(r"(?m)^    [A-Z_]+ #\d+: ", pending)[1:]
matches = [a for a in alarms if "tag=*walarm*:" + sys.argv[2] + ".SCHEDULED_SEND" in a]
if not matches:
    sys.exit("[FAIL] scheduled SMS has no pending system alarm")
for alarm in matches:
    if "repeatInterval=0" not in alarm or "Alarm clock:" in alarm.split("operation=")[0]:
        sys.exit("[FAIL] scheduled SMS registers a repeating or alarm-clock wake-up")
print("[PASS] pending SMS uses a one-shot background alarm")
PY
}
if [[ "${1:-}" = --inspect-pending ]]; then assert_idle_alarms; exit; fi

NUM=5554
BODY="idleSms$(date +%s)$$"
db() { printf '.timeout 5000\n%s\n' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" | tr -d '\r'; }
deep=$(adb_ shell dumpsys deviceidle enabled deep | tr -d '\r')
existing=$(db "SELECT COUNT(*) FROM conversations WHERE address='$NUM';")
write_mode=$(adb_ shell cmd appops get com.android.shell WRITE_SMS | sed -nE 's/^WRITE_SMS: ([a-z_]+).*/\1/p')
cleanup() {
    adb_ shell dumpsys deviceidle unforce >/dev/null || true
    adb_ shell dumpsys battery reset >/dev/null || true
    [[ "$deep" != 0 ]] || adb_ shell dumpsys deviceidle disable deep >/dev/null || true
    adb_ shell input keyevent KEYCODE_WAKEUP
    adb_ shell wm dismiss-keyguard
    adb_ shell cmd appops set com.android.shell WRITE_SMS allow >/dev/null
    adb_ shell "content delete --uri content://sms --where \"body='$BODY'\"" >/dev/null || true
    adb_ shell cmd appops set com.android.shell WRITE_SMS "${write_mode:-default}" >/dev/null
    db "DELETE FROM scheduled_messages WHERE body='$BODY'; DELETE FROM messages WHERE body='$BODY';
        DELETE FROM conversations WHERE address='$NUM' AND $existing=0
        AND NOT EXISTS (SELECT 1 FROM messages WHERE conversation_id=conversations.id)
        AND NOT EXISTS (SELECT 1 FROM scheduled_messages WHERE conversation_id=conversations.id);" >/dev/null || true
}
trap cleanup EXIT
adb_ shell am force-stop "$PKG"
due=$(( ($(adb_ shell date +%s | tr -d '\r') + 45) * 1000 ))
db "INSERT OR IGNORE INTO conversations(address,name,snippet,timestamp) VALUES('$NUM','','',$due);
    INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id) SELECT '$NUM','$BODY',$due,id,-1 FROM conversations WHERE address='$NUM';"
adb_ shell am start -W -n "$ACT" >/dev/null
sleep 2
assert_idle_alarms
adb_ shell input keyevent KEYCODE_HOME
adb_ shell dumpsys battery unplug >/dev/null
adb_ shell input keyevent KEYCODE_SLEEP
adb_ shell dumpsys deviceidle enable deep >/dev/null
adb_ shell dumpsys deviceidle force-idle deep >/dev/null
[[ "$(adb_ shell dumpsys deviceidle get deep | tr -d '\r')" = IDLE ]] || fail "device did not enter deep idle"
for attempt in {1..100}; do
    status=$(db "SELECT status FROM messages WHERE body='$BODY' AND is_me=1 AND timestamp >= $due;")
    [[ "$status" = sent || "$status" = delivered ]] && break
    sleep 1
done
[[ "$status" = sent || "$status" = delivered ]] || fail "missing Android sent callback while idle: $status"
[[ "$(db "SELECT count(*) FROM scheduled_messages WHERE body='$BODY';")" = 0 ]] || fail "message remained queued"
[[ "$(adb_ shell dumpsys deviceidle get deep | tr -d '\r')" = IDLE ]] || fail "device left deep idle"
echo "[PASS] Android acknowledged the SMS with the screen off in deep idle"
