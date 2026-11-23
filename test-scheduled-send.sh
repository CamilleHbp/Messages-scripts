#!/usr/bin/env bash
set -eu -o pipefail
source "$(dirname "$0")/env.sh"

fail() { echo "[FAIL] $*"; exit 1; }
pass() { echo "[PASS] $*"; }
[ "$(adb_ shell getprop ro.kernel.qemu | tr -d '\r')" = 1 ] || fail "Android emulator required"
SQLITE=${SQLITE:-sqlite3}
case "$PKG$SQLITE" in *[!a-zA-Z0-9_/.-]*) fail "invalid SQLite path or package";; esac
db() { printf '.timeout 5000\n%s\n' "$1" | adb_ shell "run-as $PKG $SQLITE databases/messages.db" | tr -d '\r'; }

# Use the emulator SMS destination and a unique row. Simulate the state left
# by a reboot: the database still has the schedule, but AlarmManager does not.
BODY="schedule-recovery-$(date +%s)-$$"
NUM=5556
CONV=""
CREATED=""
cleanup() {
    db "DELETE FROM scheduled_messages WHERE body='$BODY'; DELETE FROM messages WHERE body='$BODY';" >/dev/null || true
    if [ -n "$CREATED" ]; then
        db "DELETE FROM conversations WHERE id=$CONV AND NOT EXISTS (SELECT 1 FROM messages WHERE conversation_id=$CONV) AND NOT EXISTS (SELECT 1 FROM scheduled_messages WHERE conversation_id=$CONV);" >/dev/null || true
    fi
    adb_ shell "content delete --uri content://sms --where \"body='$BODY'\"" >/dev/null || true
}
[ "$(db 'SELECT 1;')" = 1 ] || fail "SQLite unavailable; set SQLITE to the device executable path"
adb_ shell am force-stop "$PKG"
NOW=$(adb_ shell date +%s | tr -d '\r')
# Allocate an isolated conversation. Never change an existing thread.
CONV=$(db "SELECT id FROM conversations WHERE address='$NUM' LIMIT 1;")
[ -z "$CONV" ] || fail "emulator test destination $NUM already has a conversation"
CONV=$(db "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$NUM','$BODY','',$((NOW * 1000))); SELECT last_insert_rowid();")
[[ "$CONV" =~ ^[0-9]+$ ]] || fail "conversation setup failed"
CREATED=1
trap cleanup EXIT
DUE=$(( (NOW + 15) * 1000 ))
db "INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id) VALUES('$NUM','$BODY',$DUE,$CONV,-1);"
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null
for _ in {1..45}; do
    COUNT=$(db "SELECT COUNT(*) FROM messages WHERE body='$BODY' AND conversation_id=$CONV AND is_me=1 AND timestamp >= $DUE;")
    [ "$COUNT" = 1 ] && break
    sleep 1
done
[ "$COUNT" = 1 ] || fail "persisted schedule did not fire at or after its due time"
[ "$(db "SELECT COUNT(*) FROM scheduled_messages WHERE body='$BODY';")" = 0 ] || fail "delivered schedule remains queued"
pass "real AlarmManager delivery after reopening the app consumed the schedule once"
wait_for_text "$BODY" 4 || fail "delivered text missing from the conversation"
pass "scheduled text appears in its original conversation"
