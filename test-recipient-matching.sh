#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
id=$(date +%s)
name="José$id"
permission=android.permission.READ_CONTACTS
prior=$(adb_ shell dumpsys package "$PKG" | grep -m1 "$permission: granted=" || true)
cleanup() {
    adb_ shell content delete --uri "content://com.android.contacts/raw_contacts/$id" >/dev/null
    if [[ "$prior" == *granted=true* ]]; then adb_ shell pm grant "$PKG" "$permission"; else adb_ shell pm revoke "$PKG" "$permission"; fi
    adb_ shell am force-stop "$PKG"
}
trap cleanup EXIT
adb_ shell content insert --uri content://com.android.contacts/raw_contacts --bind "_id:i:$id" --bind account_type:s:local --bind account_name:s:regression
adb_ shell content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:"$id" --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:"$name"
adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$id --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind 'data1:s:+1 (415) 555-0168'"
open_picker() {
    adb_ shell am force-stop "$PKG"
    adb_ shell am start -n "$ACT" >/dev/null
    if [[ ${1:-} == denied ]]; then
        for ((i=0; i<5; i++)); do
            dump_ui || continue
            if grep -q 'text="DON’T ALLOW"' "$TMP/ui.xml"; then tap_text 'DON’T ALLOW'; break; fi
            grep -q 'Start chat' "$TMP/ui.xml" && break
        done
    fi
    wait_for_text 'Start chat'
    tap_text 'Start chat'
    wait_for_text 'Enter name or phone number'
}
adb_ shell pm grant "$PKG" "$permission"
for query in "Jose$id" 415555; do
    open_picker
    type_text "$query"
    wait_for_text "$name" || { echo "[FAIL] missing contact for $query"; exit 1; }
done
adb_ shell pm revoke "$PKG" "$permission"
open_picker denied
wait_for_text 'Allow contacts access'
type_text 5550134
wait_for_text 'Send to'
echo '[PASS] Accents, formatted numbers, and manual entry without Contacts access'
