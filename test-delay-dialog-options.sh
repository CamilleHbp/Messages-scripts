#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
prefs=shared_prefs/messages_settings.xml
backup=$(mktemp "$TMP/send-delay.XXXXXX")
adb_ shell am force-stop "$PKG"
had_prefs=false
if adb_ exec-out run-as "$PKG" cat "$prefs" > "$backup" 2>/dev/null; then had_prefs=true; fi
restore() {
    adb_ shell am force-stop "$PKG"
    if $had_prefs; then
        adb_ shell "run-as $PKG sh -c 'cat > $prefs'" < "$backup"
    else
        adb_ shell run-as "$PKG" rm -f "$prefs"
    fi
    rm -f "$backup"
}
trap restore EXIT
for layout in false true; do
    adb_ shell am force-stop "$PKG"
    adb_ shell "run-as $PKG sh -c 'cat > $prefs'" <<XML
<map><boolean name="use_new_ui" value="$layout"/><boolean name="first_import_done" value="true"/><boolean name="delayed_sending_enabled" value="true"/><int name="delay_seconds" value="5"/></map>
XML
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
    wait_for_text 'General settings'
    for ((i=0; i<12; i++)); do
        dump_ui
        grep -q 'text="Send delay"' "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1750 540 850 350
    done
    grep -q 'text="5s"' "$TMP/ui.xml" || { echo '[FAIL] prior delay missing'; exit 1; }
    tap_text 'Send delay' || { echo '[FAIL] Send delay missing in General settings'; exit 1; }
    wait_for_text 'Choose how long'
    for opt in Off 1s 3s 5s 10s 30s; do
        grep -q "text=\"$opt\"" "$TMP/ui.xml" || { echo "[FAIL] missing $opt"; exit 1; }
    done
    tap_text '10s'
    wait_for_text 'text="10s"'
    tap_text 'Send delay'
    tap_text Off
    wait_for_text 'text="Off"'
    echo "[PASS] General settings preserves the prior value and accepts a duration or Off (new layout $layout)"
done
