#!/usr/bin/env bash
# Run on an empty English-language test emulator. Refuse to mark existing chats read.
set -euo pipefail
source "$(dirname "$0")/env.sh"
fail() { echo "[FAIL] $*" >&2; exit 1; }
expect() { wait_for_text "$1" 4 || fail "missing $1"; echo "[PASS] $1"; }
db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }
launch() { adb_ shell am force-stop "$PKG"; adb_ shell am start -n "$ACT" >/dev/null; }
confirm_button() {
    local coords
    coords=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys, xml.etree.ElementTree as ET
nodes = ET.parse(sys.argv[1]).findall('.//node[@text="Mark all as read"]')
assert len(nodes) == 2
x1,y1,x2,y2 = map(int,re.findall(r'\d+',nodes[-1].get('bounds')))
print((x1+x2)//2,(y1+y2)//2)
PY
)
    adb_ shell input tap $coords
}
launch
expect 'Start chat'
[ "$(db 'SELECT COUNT(*) FROM conversations WHERE deleted_at=0 AND blocked=0;')" = 0 ] || fail 'requires empty test inbox and archive'
expect 'No conversations yet'
tap_text Archived
expect 'No archived conversations'
expect 'Conversations you archive appear here.'
adb_ shell input keyevent 4
tap_text 'General settings'
expect 'Choose theme'
adb_ shell input keyevent 4
tap_text 'Start chat'
expect 'Enter name or phone number'
type_text NoSuchRecipient
expect 'No contacts match'
adb_ shell input keyevent KEYCODE_MOVE_END
for ((i=0; i<15; i++)); do adb_ shell input keyevent KEYCODE_DEL; done
type_text 5550101
expect 'Send to'
launch
token="ux$(date +%s)$$"
cleanup() {
    adb_ shell am force-stop "$PKG"
    db "DELETE FROM conversations WHERE name='$token';" >/dev/null
}
trap cleanup EXIT
db "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES ('5550199','$token','unread',1000,2);" >/dev/null
launch
expect "$token"
tap_text 'More options'
tap_text 'Mark all as read'
expect 'Unread conversations in your inbox: 1'
tap_text Cancel
[ "$(db "SELECT unread_count FROM conversations WHERE name='$token';")" = 2 ] || fail 'cancel changed unread state'
tap_text 'More options'
tap_text 'Mark all as read'
expect 'Unread conversations in your inbox: 1'
confirm_button
sleep 1
[ "$(db "SELECT unread_count FROM conversations WHERE name='$token';")" = 0 ] || fail 'confirmed conversation still unread'
echo '[PASS] Confirmation clears only after consent'
