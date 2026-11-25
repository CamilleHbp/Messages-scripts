#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
[[ "$(adb_ shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || fail "requires an emulator"

tag="recovery$(date +%s)$$"
number="+1555$(printf '%07d' "$(( ($(date +%s) + $$) % 10000000 ))")"
db() { printf '.timeout 5000\n%s\n' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" | tr -d '\r'; }
[[ "$(db "SELECT count(*) FROM conversations WHERE address='$number';")" == 0 ]] || fail "test address in use"
airplane=$(adb_ shell settings get global airplane_mode_on | tr -d '\r')
now=$(( $(date +%s)*1000 ))
id=$(db "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$number','Recovery test','Scheduled message',$now); SELECT last_insert_rowid();")
[[ "$id" =~ ^[0-9]+$ ]] || fail "could not create test chat"
cleanup() {
    adb_ shell cmd connectivity airplane-mode "$([[ "$airplane" == 1 ]] && echo enable || echo disable)" >/dev/null
    adb_ shell am force-stop "$PKG"
    adb_ shell "content delete --uri content://sms --where \"body='$tag'\"" >/dev/null
    db "DROP TRIGGER IF EXISTS ${tag}_reject;
        DELETE FROM blocked_numbers WHERE number='$number'; DELETE FROM scheduled_messages WHERE conversation_id=$id;
        DELETE FROM message_provider_ids WHERE message_id IN (SELECT id FROM messages WHERE conversation_id=$id);
        DELETE FROM messages WHERE conversation_id=$id; DELETE FROM conversations WHERE id=$id;
        DELETE FROM participants WHERE normalized_destination='$number';" >/dev/null
}
trap cleanup EXIT
seed() {
    db "INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id)
        VALUES('$number','$tag',$((now+86400000)),$id,-1); SELECT last_insert_rowid();"
}
open_chat() {
    adb_ shell am force-stop "$PKG"
    adb_ shell am start -n "$ACT" --es open_conversation_address "$number" >/dev/null
}
open_schedule() {
    open_chat
    wait_for_text "$tag" && tap_text "$tag" && wait_for_text 'Send now' || fail "cannot open scheduled message"
}
schedule=$(seed)
open_schedule
db "DELETE FROM scheduled_messages WHERE id=$schedule;"
tap_text 'Send now'
wait_for_text 'This message is no longer scheduled. Check the conversation for its status.' 3 || fail "missing explanation for a schedule consumed elsewhere"
if center_of 'Send now' >/dev/null; then fail "stale schedule still offers Send now"; fi
pass "a missing schedule explains where to check and cannot be sent again"

schedule=$(seed)
open_schedule
db "CREATE TRIGGER ${tag}_reject BEFORE INSERT ON messages WHEN NEW.body='$tag' BEGIN SELECT RAISE(ABORT,'fixture'); END;"
tap_text 'Send now'
wait_for_text 'Could not start sending. Try Send now again or change the send time.' || fail "queue failure has no recovery action"
[[ "$(db "SELECT count(*) FROM scheduled_messages WHERE id=$schedule;")" == 1 ]] || fail "failed handoff lost the schedule"
db "DROP TRIGGER ${tag}_reject; INSERT INTO blocked_numbers(number,timestamp) VALUES('$number',$now);"
open_schedule
tap_text 'Send now'
wait_for_text 'This number is blocked. Unblock it before sending.' || fail "blocked recipient lacks guidance"
[[ "$(db "SELECT count(*) FROM messages WHERE conversation_id=$id;")" == 0 ]] || fail "a blocked send created a duplicate"
pass "queue and blocked-number errors keep the same schedule available"
db "DELETE FROM blocked_numbers WHERE number='$number';"
adb_ shell cmd connectivity airplane-mode enable
sleep 3
open_schedule
tap_text 'Send now'
wait_for_text 'Mobile radio off. Check airplane mode before retrying.' || fail "carrier failure lacks an actionable reason"
open_chat
wait_for_text 'Mobile radio off. Check airplane mode before retrying.' || fail "reason lost after relaunch"
pass "Android's radio-off failure survives a restart beside the original SMS"
adb_ shell cmd connectivity airplane-mode disable
for attempt in {1..30}; do
    registration=$(adb_ shell dumpsys telephony.registry)
    [[ "$registration" == *"mVoiceRegState=0(IN_SERVICE)"* ]] && break
    sleep 1
done
[[ "$registration" == *"mVoiceRegState=0(IN_SERVICE)"* ]] || fail "emulator did not regain mobile service"
tap_text 'Retry' || fail "cannot retry the failed SMS"
for attempt in {1..30}; do
    state=$(db "SELECT status FROM messages WHERE conversation_id=$id AND body='$tag';")
    [[ "$state" == sent || "$state" == delivered ]] && break
    sleep 1
done
[[ "$state" == sent || "$state" == delivered ]] || fail "retry was not acknowledged"
[[ "$(db "SELECT count(*) FROM scheduled_messages WHERE id=$schedule;")" == 0 ]] || fail "consumed schedule remained queued"
[[ "$(db "SELECT count(*) FROM messages WHERE conversation_id=$id AND body='$tag' AND sms_error=0;")" == 1 ]] || fail "retry duplicated the SMS or kept the old error"
for attempt in {1..10}; do
    sent=$(adb_ shell "content query --uri content://sms/sent --projection _id --where \"body='$tag'\"")
    [[ "$(grep -c '_id=' <<< "$sent")" == 1 ]] && break
    sleep 1
done
[[ "$(grep -c '_id=' <<< "$sent")" == 1 ]] || fail "expected exactly one Android Sent entry"
pass "radio recovery resends the same row exactly once and clears its error"
