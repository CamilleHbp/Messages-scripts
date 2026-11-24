#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
[[ "$ANDROID_SERIAL" == emulator-* ]]
db() { adb_ shell "run-as $PKG sqlite3 -cmd '.timeout 5000' databases/messages.db \"$1\"" | tr -d '\r'; }
number="+1555$(date +%s | tail -c 8)"
other="+15555550102"
blocked="+1666${number:5}"
name="Outcome fixture $$"
adb_ shell am force-stop "$PKG"
id=$(db "INSERT INTO conversations(address,name,group_title,snippet,timestamp) VALUES ('$number','$name','$name','Status fixture',9999999999999); SELECT last_insert_rowid();" | tail -1)
cleanup() {
    adb_ shell am force-stop "$PKG"
    local sys
    for sys in $(db "SELECT p.sys_id FROM message_provider_ids p JOIN messages m ON p.message_id=m.id WHERE m.conversation_id=$id AND p.transport='sms';"); do
        adb_ shell content delete --uri "content://sms/$sys" >/dev/null
    done
    db "DELETE FROM blocked_numbers WHERE number='$blocked'; DELETE FROM message_provider_ids WHERE message_id IN (SELECT id FROM messages WHERE conversation_id=$id); DELETE FROM conversation_recipients WHERE conversation_id=$id; DELETE FROM messages WHERE conversation_id=$id; DELETE FROM conversations WHERE id=$id;"
}
trap cleanup EXIT
db "INSERT INTO conversation_recipients(conversation_id,address) VALUES ($id,'$number'),($id,'$other');"
db "INSERT INTO blocked_numbers(number,timestamp) VALUES ('$blocked',1000);"
ledger="json_array(json_object('address','$number','attempt',1,'parts',1,'sent',json_array(0),'delivered',json_array(),'failed',json('false')),json_object('address','$other','attempt',1,'parts',1,'sent',json_array(),'delivered',json_array(),'failed',json('true'),'reason','no_service'),json_object('address','$blocked','attempt',1,'parts',1,'sent',json_array(),'delivered',json_array(),'failed',json('true')))"
mid=$(db "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,recipient_sends) VALUES ($id,'Status fixture',1000,1,'partial',$ledger); SELECT last_insert_rowid();" | tail -1)
db "UPDATE conversations SET composer=json_object('draft','Fresh group send','media',json_array(),'state','DRAFT','deadline',0,'sim',1) WHERE id=$id;"
adb_ shell am start -n "$ACT" >/dev/null
wait_for_text "$name"
tap_contains "$name"
wait_for_text 'Retry failed' 3 || { echo '[FAIL] group bubble has no selective retry'; exit 1; }
python3 - "$TMP/ui.xml" <<'CHECK'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1])
assert any(
    node.get("long-clickable") == "true" and
    {"Status fixture", "Retry failed"}.issubset({child.get("text") for child in node.iter()})
    for node in root.iter()
), "Retry failed must be inside the message bubble"
CHECK
wait_for_text '1 Blocked' 2 || { echo '[FAIL] the bubble omits the blocked destination'; exit 1; }
tap_contains '1 Sent'
wait_for_text 'No mobile service'
python3 - "$TMP/ui.xml" <<'CHECK'
import sys,xml.etree.ElementTree as ET
labels = [n.get("text","") for n in ET.parse(sys.argv[1]).iter()]
failed = next(i for i,s in enumerate(labels) if '0102' in s and 'No mobile service' in s)
sent = next(i for i,s in enumerate(labels) if s.endswith(' · Sent'))
assert failed < sent
CHECK
tap_text 'Retry failed'
for attempt in {1..10}; do
    generations=$(db "SELECT json_extract(recipient_sends,'\$[0].attempt') || ',' || json_extract(recipient_sends,'\$[1].attempt') FROM messages WHERE id=$mid;")
    [[ "$generations" == 1,2 ]] && break
    sleep 1
done
[[ "$generations" == 1,2 ]]
[[ "$(db "SELECT json_extract(recipient_sends,'\$[2].attempt') FROM messages WHERE id=$mid;")" == 1 ]]
[[ "$(db "SELECT count(*) FROM messages WHERE conversation_id=$id AND body='Status fixture';")" == 1 ]]
tap_text Send
for attempt in {1..45}; do
    recipients=$(db "SELECT json_array_length(recipient_sends) FROM messages WHERE conversation_id=$id AND body='Fresh group send' AND recipient_sends!='';")
    [[ "$recipients" == 2 ]] && break
    sleep 1
done
[[ "$recipients" == 2 ]]
echo '[PASS] group bubble shows mixed results and retries only the failed destination'
