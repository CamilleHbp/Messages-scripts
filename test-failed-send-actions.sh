#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ "$ANDROID_SERIAL" == emulator-* ]]
number="+1555$(date +%s | tail -c 8)"
db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }
id=$(db "INSERT INTO conversations(address,name,snippet,timestamp) VALUES ('$number','Retry fixture','photo',1000); SELECT last_insert_rowid();" | tail -1)
asset="retry-$id.png"
provider_id=0
cleanup() {
    adb_ shell am force-stop "$PKG"
    adb_ shell run-as "$PKG" rm -f "files/composer-media/$asset"
    if [[ "$provider_id" =~ ^[1-9][0-9]*$ ]]; then adb_ shell content delete --uri "content://mms/$provider_id" >/dev/null; fi
    db "DELETE FROM messages WHERE conversation_id=$id; DELETE FROM conversations WHERE id=$id;" >/dev/null
}
trap cleanup EXIT
mid=$(db "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri,sub_id) VALUES ($id,'Original caption',1000,1,'failed','image','content://unavailable/photo',7); SELECT last_insert_rowid();" | tail -1)
open_chat() {
    adb_ shell am force-stop "$PKG"
    adb_ shell am start -n "$ACT" --ez fake_dual_sim true -a android.intent.action.SENDTO -d "smsto:$number" >/dev/null
}
open_chat
wait_for_text 'Choose SIM' 3 || { echo '[FAIL] optional SIM action missing beside Retry'; exit 1; }
density=$(adb_ shell wm density | tail -1 | tr -cd '0-9')
python3 - "$TMP/ui.xml" "$density" <<'CHECK'
import re, sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
parents = {child: parent for parent in tree.iter() for child in parent}
for label in ("Retry", "Choose SIM"):
    node = next(n for n in tree.iter() if n.get("text") == label)
    while node.get("clickable") != "true":
        node = parents[node]
    x1, y1, x2, y2 = map(int, re.findall(r"-?\d+", node.get("bounds")))
    assert min(x2 - x1, y2 - y1) >= round(48 * int(sys.argv[2]) / 160), (label, node.get("bounds"))
CHECK
adb_ logcat -c
tap_text Retry
wait_for_text 'Choose SIM'
[[ "$(db "SELECT sub_id FROM messages WHERE id=$mid;")" == 7 ]]
adb_ logcat -d -s MmsSender:I | grep -F "sendMms start id=$mid sub=7 " >/dev/null
adb_ shell run-as "$PKG" mkdir -p files/composer-media
python3 -c 'import struct,zlib,sys; chunk=lambda t,d:struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)); sys.stdout.buffer.write(bytes.fromhex("89504e470d0a1a0a")+chunk(b"IHDR",struct.pack(">IIBBBBB",1,1,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(bytes([0,64,128,192])))+chunk(b"IEND",b""))' | adb_ shell -T "run-as $PKG sh -c 'cat > files/composer-media/$asset'"
db "UPDATE messages SET media_uri='content://$PKG.fileprovider/composer-media/$asset' WHERE id=$mid;" >/dev/null
tap_text 'Choose SIM'
wait_for_text 'Vodafone'
tap_contains 'T-Mobile'
tap_text Retry
sleep 1
[[ "$(db "SELECT sub_id FROM messages WHERE id=$mid;")" == 1 ]]
[[ "$(db "SELECT body FROM messages WHERE id=$mid;")" == 'Original caption' ]]
for attempt in {1..15}; do
    provider_id=$(db "SELECT sys_id FROM messages WHERE id=$mid;")
    [[ "$provider_id" =~ ^[1-9][0-9]*$ ]] && break
    sleep 1
done
[[ "$provider_id" =~ ^[1-9][0-9]*$ ]]
adb_ shell content query --uri "content://mms/$provider_id/part" --projection ct:text | grep -F 'text=Original caption' >/dev/null
echo '[PASS] Retry keeps the saved SIM and caption, and the chooser changes only the selected message'
