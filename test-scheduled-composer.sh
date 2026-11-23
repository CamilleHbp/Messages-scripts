#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
[ "$(adb_ shell getprop ro.kernel.qemu | tr -d '\r')" = 1 ] || fail "requires an emulator"
PORT=${ANDROID_SERIAL#emulator-}
[[ "$PORT" =~ ^[0-9]{4}$ ]] || fail "invalid emulator console port"
NUM="+1555521$PORT"
MARK="composerSchedule$(date +%s)$$"
SQLITE=${SQLITE:-sqlite3}
case "$PKG$SQLITE" in *[!a-zA-Z0-9_/.-]*) fail "invalid package name or SQLite path";; esac
db() { printf '.timeout 5000\n%s\n' "$1" | adb_ shell "run-as $PKG $SQLITE databases/messages.db" | tr -d '\r'; }
[ "$(db "SELECT count(*) FROM conversations WHERE address='$NUM';")" = 0 ] || fail "loopback number already has a conversation; use a clean test emulator"
ORIGINAL_PARTICIPANTS=$(db "SELECT count(*) FROM participants WHERE normalized_destination='$NUM';")
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null || true
    adb_ shell "content delete --uri content://sms --where \"body IN ('$MARK-clock','$MARK-longpress')\"" >/dev/null || true
    db "PRAGMA foreign_keys=ON; BEGIN; DELETE FROM scheduled_messages WHERE body IN ('$MARK-clock','$MARK-longpress'); DELETE FROM messages WHERE body IN ('$MARK-clock','$MARK-longpress');
        DELETE FROM conversations WHERE address='$NUM' AND NOT EXISTS (SELECT 1 FROM messages WHERE conversation_id=conversations.id) AND NOT EXISTS (SELECT 1 FROM scheduled_messages WHERE conversation_id=conversations.id);
        DELETE FROM participants WHERE normalized_destination='$NUM' AND $ORIGINAL_PARTICIPANTS=0 AND NOT EXISTS (SELECT 1 FROM conversation_recipients WHERE address='$NUM'); COMMIT;" >/dev/null || true
}
trap cleanup EXIT

adb_ shell am start -n "$ACT" -a android.intent.action.SENDTO -d "smsto:$NUM" >/dev/null
type_draft() {
    local attempt
    for attempt in 1 2 3; do
        if tap_edittext; then type_text "$1"; wait_for_text "$1" 3; return; fi
        sleep 1
    done
    fail "draft field missing from composer"
}
BODY="$MARK-longpress"
type_draft "$BODY" || fail "draft missing"
tap_text Schedule || fail "clock action missing beside Send"
tap_text Cancel || fail "could not dismiss date picker"
wait_for_text "$BODY" 3 || fail "canceling the picker discarded the draft"
[ "$(db "SELECT count(*) FROM scheduled_messages WHERE body='$BODY';")" = 0 ] || fail "canceling queued the draft"
pass "clock action opens the picker and Cancel preserves the draft"
XY=$(center_of Send) || fail "Send button unavailable"
read -r X Y <<< "$XY"
adb_ shell input swipe "$X" "$Y" "$X" "$Y" 850
confirm_schedule() {
    tap_text Next || fail "$1 did not open the date picker"
    tap_text Schedule || fail "could not confirm the time picker"
    for attempt in 1 2 3 4 5; do
        DUE=$(db "SELECT timestamp FROM scheduled_messages WHERE body='$BODY' AND address='$NUM';")
        [ -n "$DUE" ] && break
        sleep 1
    done
    [[ "$DUE" =~ ^[0-9]+$ ]] || fail "composer did not queue exactly one SMS"
    NOW=$(adb_ shell date +%s | tr -d '\r')
    LEFT=$(( DUE / 1000 - NOW ))
    (( LEFT > 0 && LEFT <= 300 )) || fail "default send time is $LEFT seconds away (expected within five minutes)"
    pass "$1 and picker confirmation queued a near-future SMS"
}
confirm_schedule "long press"
FIRST_DUE=$DUE
BODY="$MARK-clock"
type_draft "$BODY" || fail "second draft missing"
tap_text Schedule || fail "clock action unavailable for second draft"
confirm_schedule "clock action"
LAST_DUE=$DUE
adb_ shell input keyevent KEYCODE_HOME
sleep "$LEFT"
assert_sent() {
    local BODY=$1 DUE=$2 STATUS SYSTEM_SENT attempt
    for attempt in $(seq 1 35); do
        STATUS=$(db "SELECT m.status FROM messages AS m JOIN conversations AS c ON c.id=m.conversation_id WHERE m.is_me=1 AND c.address='$NUM' AND m.body='$BODY' AND m.timestamp >= $DUE;")
        case "$STATUS" in
            sent|delivered) break;;
            failed) fail "Android reported SMS send failure";;
        esac
        sleep 1
    done
    [[ "$STATUS" = sent || "$STATUS" = delivered ]] || fail "SMS send callback missing (status: $STATUS)"
    [ "$(db "SELECT count(*) FROM scheduled_messages WHERE body='$BODY';")" = 0 ] || fail "sent message is still queued"
    for attempt in 1 2 3 4 5; do
        SYSTEM_SENT=$(adb_ shell "content query --uri content://sms/sent --projection _id --where \"body='$BODY'\"" | tr -d '\r')
        [[ "$SYSTEM_SENT" = *"_id="* ]] && break
        sleep 1
    done
    [[ "$SYSTEM_SENT" = *"_id="* ]] || fail "scheduled SMS missing from Android's sent box"
    pass "Android acknowledged the scheduled SMS through $3 after its due time with the composer in the background"
}
assert_sent "$MARK-longpress" "$FIRST_DUE" "long press"
assert_sent "$MARK-clock" "$LAST_DUE" "the clock action"
