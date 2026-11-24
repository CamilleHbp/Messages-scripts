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
cleanup() {
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
wait_for_text 'content-desc="Close"' || { echo '[FAIL] shared image did not reach composer'; exit 1; }
[[ "$(count_images)" == 0 ]]
tap_text Send
wait_for_text 'content-desc="Cancel"'
tap_text Back
wait_for_text 'Sending in '
tap_contains "$token"
tap_text Cancel
wait_for_text 'content-desc="Close"'
wait_for_text "$token"
[[ "$(count_images)" == 0 ]] || { echo '[FAIL] canceled picture was sent'; exit 1; }
tap_text Send
tap_text Back
wait_for_text 'Sending in '
sleep 31
[[ "$(count_images)" == 1 ]] || { echo '[FAIL] picture did not dispatch exactly once'; exit 1; }
[[ "$(db "SELECT body FROM messages WHERE conversation_id=$id AND media_type='image';")" == "$token" ]]
echo '[PASS] Attachment countdown survives Back, restores the caption and image on Cancel, and dispatches once on expiry'
