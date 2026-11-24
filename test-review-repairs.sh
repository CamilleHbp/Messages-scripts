#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ "$ANDROID_SERIAL" == emulator-* ]]
db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }
name="Repair fixture $$"
number="+1555$(date +%s | tail -c 8)"
adb_ shell am force-stop "$PKG"
id=$(db "INSERT INTO conversations(address,name,group_title,timestamp,snippet,composer) VALUES ('$number','$name','$name',9999999999999,'review',json_object('draft','Fixture caption','media',json_array('content://missing/one','content://missing/two'),'state','REVIEW','deadline',0,'sim',999)); SELECT last_insert_rowid();" | tail -1)
uri=''
cleanup() {
    adb_ shell am force-stop "$PKG"
    db "DELETE FROM conversation_recipients WHERE conversation_id=$id; DELETE FROM messages WHERE conversation_id=$id; DELETE FROM conversations WHERE id=$id;"
    if [[ -n "$uri" ]]; then adb_ shell content delete --uri "$uri" >/dev/null; fi
}
trap cleanup EXIT
db "INSERT INTO conversation_recipients(conversation_id,address) VALUES ($id,'$number'),($id,'+15555550102');"
adb_ shell am start -n "$ACT" --ez fake_dual_sim true >/dev/null
wait_for_text "$name"
tap_contains "$name"
tap_text 'Review message'
wait_for_text 'Photo 1 of 2 is unavailable' 3 || { echo '[FAIL] missing photo has no recovery controls'; exit 1; }
enabled() {
    dump_ui
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import sys,xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1])
parents={c:n for n in root.iter() for c in n}
n=next(n for n in root.iter() if n.get('text')=='Send now')
while n.get('clickable')!='true' and n.get('class')!='android.widget.Button' and n.get('enabled')!='false': n=parents[n]
assert n.get('enabled')==sys.argv[2], n.attrib
PY
}
enabled false
tap_text '2 recipients'
wait_for_text '0102'
tap_text '2 recipients'
wait_for_text 'The selected SIM is no longer active.'
adb_ shell content insert --uri content://media/external/images/media --bind "_display_name:s:repair-$id.png" --bind mime_type:s:image/png
media_id=$(adb_ shell "content query --uri content://media/external/images/media --projection _id --where \"_display_name='repair-$id.png'\"" | sed -nE 's/.*_id=([0-9]+).*/\1/p' | tr -d '\r')
uri="content://media/external/images/media/$media_id"
python3 -c 'import struct,zlib,sys; chunk=lambda t,d:struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)); sys.stdout.buffer.write(bytes.fromhex("89504e470d0a1a0a")+chunk(b"IHDR",struct.pack(">IIBBBBB",1,1,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(bytes([0,64,128,192])))+chunk(b"IEND",b""))' | adb_ shell -T content write --uri "$uri"
tap_text Replace
wait_for_text 'Photo taken'
tap_contains 'Photo taken'
wait_for_text 'content-desc="Photo 1 of 2"'
enabled false
tap_text Remove
wait_for_text 'content-desc="Photo 1 of 1"'
enabled false
tap_text 'Choose SIM'
tap_contains 'T-Mobile'
enabled true
tap_text 'Keep as draft'
[[ "$(db "SELECT json_extract(composer,'$.state') || ',' || json_extract(composer,'$.draft') || ',' || json_array_length(composer,'$.media') || ',' || json_extract(composer,'$.sim') FROM conversations WHERE id=$id;")" == 'DRAFT,Fixture caption,1,1' ]]
echo '[PASS] review expands the group, requires an active replacement SIM, and waits for each photo repair'
