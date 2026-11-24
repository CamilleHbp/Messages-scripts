#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ "$ANDROID_SERIAL" == emulator-* ]]
stamp=$(date +%s)
prefs=shared_prefs/messages_settings.xml
backup=$(mktemp "$TMP/draft-visibility.XXXXXX")
adb_ shell am force-stop "$PKG"
had_prefs=false
if adb_ exec-out run-as "$PKG" cat "$prefs" > "$backup" 2>/dev/null; then had_prefs=true; fi
db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }
cleanup() {
    adb_ shell am force-stop "$PKG"
    db "DELETE FROM conversations WHERE name IN ('Text $stamp','Photo $stamp');" >/dev/null
    if $had_prefs; then adb_ shell "run-as $PKG sh -c 'cat > $prefs'" < "$backup"; else adb_ shell run-as "$PKG" rm -f "$prefs"; fi
    rm -f "$backup"
}
trap cleanup EXIT
db "INSERT INTO conversations(address,name,snippet,timestamp,draft) VALUES ('+15551$stamp','Text $stamp','Previous text',$stamp*1000,'privateText$stamp');" >/dev/null
db "INSERT INTO conversations(address,name,snippet,timestamp,draft,composer) VALUES ('+15552$stamp','Photo $stamp','Previous photo',$stamp*1000,'privateCaption$stamp',json_object('draft','privateCaption$stamp','media',json_array('content://fixture/photo'),'sim',1,'state','DRAFT','deadline',0));" >/dev/null
for modern in true false; do
    for enabled in false true; do
        adb_ shell am force-stop "$PKG"
        adb_ shell "run-as $PKG sh -c 'cat > $prefs'" <<XML
<map><boolean name="first_import_done" value="true"/><boolean name="use_new_ui" value="$modern"/><boolean name="drafts_enabled" value="$enabled"/></map>
XML
        adb_ shell am start -n "$ACT" >/dev/null
        wait_for_text "Text $stamp"
        wait_for_text "Photo $stamp"
        if [[ "$enabled" == true ]]; then
            wait_for_text "privateText$stamp"
            wait_for_text "1 photo · privateCaption$stamp"
        else
            if grep -Eq "private(Text|Caption)$stamp" "$TMP/ui.xml"; then
                echo "[FAIL] Draft content visible with previews disabled (modern=$modern)"; exit 1
            fi
            wait_for_text "Previous text"
            wait_for_text "Previous photo"
        fi
    done
done
echo '[PASS] Both layouts honor draft previews for text and photo captions'
