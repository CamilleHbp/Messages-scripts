#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ "$ANDROID_SERIAL" == emulator-* ]] || exit 1
token="delayphoto$(date +%s)$$"
number="+1555$(date +%s | tail -c 8)"
prefs=shared_prefs/messages_settings.xml
backup=$(mktemp "$TMP/attachment-delay.XXXXXX")
adb_ shell am force-stop "$PKG"
had_prefs=false
if adb_ exec-out run-as "$PKG" cat "$prefs" > "$backup" 2>/dev/null; then had_prefs=true; fi
db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }
uri=''
id=''
rotation=$(adb_ shell settings get system user_rotation | tr -d '\r')
auto_rotate=$(adb_ shell settings get system accelerometer_rotation | tr -d '\r')
cleanup() {
    adb_ shell settings put system user_rotation "$rotation"
    adb_ shell settings put system accelerometer_rotation "$auto_rotate"
    adb_ shell am force-stop "$PKG"
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        db "DELETE FROM messages WHERE conversation_id=$id; DELETE FROM conversations WHERE id=$id;" >/dev/null
    fi
    if [[ -n "$uri" ]]; then adb_ shell content delete --uri "$uri" >/dev/null; fi
    if $had_prefs; then adb_ shell "run-as $PKG sh -c 'cat > $prefs'" < "$backup"; else adb_ shell run-as "$PKG" rm -f "$prefs"; fi
    rm -f "$backup"
}
trap cleanup EXIT
adb_ shell "run-as $PKG sh -c 'cat > $prefs'" <<XML
<map><boolean name="first_import_done" value="true"/><boolean name="delayed_sending_enabled" value="true"/><int name="delay_seconds" value="30"/></map>
XML
adb_ shell content insert --uri content://media/external/images/media --bind "_display_name:s:$token.png" --bind mime_type:s:image/png
media_id=$(adb_ shell "content query --uri content://media/external/images/media --projection _id --where \"_display_name='$token.png'\"" | sed -nE 's/.*_id=([0-9]+).*/\1/p' | tr -d '\r')
[[ "$media_id" =~ ^[0-9]+$ ]]
uri="content://media/external/images/media/$media_id"
python3 -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8V8AAAAASUVORK5CYII="))' | adb_ shell -T content write --uri "$uri"
id=$(db "INSERT INTO conversations(address,name,snippet,timestamp) VALUES ('$number','$token','attachment',1000); SELECT last_insert_rowid();" | tail -1)
[[ "$id" =~ ^[0-9]+$ ]]
count_images() { db "SELECT count(*) FROM messages WHERE conversation_id=$id AND media_type='image' AND is_me=1;"; }
adb_ shell am start -n "$ACT" -a android.intent.action.SEND -d "smsto:$number" -t image/png --eu android.intent.extra.STREAM "$uri" --es sms_body "$token" --grant-read-uri-permission >/dev/null
wait_for_text 'content-desc="Remove photo 1 of 1"'
adb_ shell am start -n "$ACT" -a android.intent.action.SEND -d "smsto:$number" -t image/png --eu android.intent.extra.STREAM "$uri" --grant-read-uri-permission >/dev/null
wait_for_text 'content-desc="Remove photo 2 of 2"'
media_order() { db "SELECT json_extract(composer,'$.media') FROM conversations WHERE id=$id;"; }
ordered=$(media_order)
adb_ shell settings put system accelerometer_rotation 0
adb_ shell settings put system user_rotation 1
sleep 1
wait_for_text 'content-desc="Remove photo 2 of 2"'
[[ "$(media_order)" == "$ordered" ]]
adb_ shell settings put system user_rotation 0
sleep 1
wait_for_text 'content-desc="Remove photo 1 of 2"'
[[ "$(media_order)" == "$ordered" ]]
tap_text 'Remove photo 2 of 2'
wait_for_text 'content-desc="Photo 1 of 1"'
wait_for_text "$token"
tap_text Back
wait_for_text "Draft: Photo"
adb_ shell am force-stop "$PKG"
open_thread() {
    adb_ shell am start -n "$ACT" -a android.intent.action.SENDTO -d "smsto:$number" >/dev/null
}
open_thread
wait_for_text 'content-desc="Remove photo 1 of 1"' 3 || { echo '[FAIL] photo draft missing after restart'; exit 1; }
wait_for_text "$token"
tap_text Send
adb_ shell am force-stop "$PKG"
open_thread
wait_for_text 'content-desc="Cancel"' || { echo '[FAIL] active countdown did not resume'; exit 1; }
tap_text Cancel
[[ "$(count_images)" == 0 ]]
wait_for_text 'content-desc="Remove photo 1 of 1"'
wait_for_text "$token"
tap_text Send
adb_ shell am force-stop "$PKG"
sleep 31
[[ "$(count_images)" == 0 ]]
open_thread
wait_for_text 'Review your message before sending'
[[ "$(count_images)" == 0 ]]
tap_text Send
wait_for_text 'Send interrupted'
tap_text Cancel
[[ "$(count_images)" == 0 ]]
tap_text Send
tap_text 'Send now'
[[ "$(count_images)" == 1 ]] || { echo '[FAIL] explicit confirmation did not create exactly one message'; exit 1; }
[[ "$(db "SELECT body FROM messages WHERE conversation_id=$id AND media_type='image';")" == "$token" ]]
adb_ shell am force-stop "$PKG"
open_thread
wait_for_text "$token"
[[ "$(count_images)" == 1 ]]
adb_ shell am start -n "$ACT" -a android.intent.action.SENDTO -d "smsto:$number" --es sms_body "$token-text" >/dev/null
wait_for_text "$token-text"
tap_text Send
adb_ shell am force-stop "$PKG"
open_thread
wait_for_text 'content-desc="Cancel"'
sleep 31
[[ "$(db "SELECT COUNT(*) FROM messages WHERE conversation_id=$id AND body='$token-text' AND is_me=1;")" == 1 ]]
echo '[PASS] Photo and caption survive restart, a live timer resumes, and an expired timer waits for confirmation'
