#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

eval "$(declare -f dump_ui | sed '1s/dump_ui/dump_ui_uiautomator/')"
dump_ui() {
    if ! command -v "${ANDROID_CLI:-android}" >/dev/null 2>&1; then
        dump_ui_uiautomator
        return $?
    fi
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    if python3 - "${ANDROID_CLI:-android}" "$ANDROID_SERIAL" "$TMP/countdown-layout.json" "$TMP/ui.xml" <<'PYLAYOUT'
import json, subprocess, sys, xml.etree.ElementTree as E
try:
    result = subprocess.run([sys.argv[1], 'layout', '--full', '--device', sys.argv[2]],
                            capture_output=True, text=True, timeout=15, check=True)
    raw = result.stdout
    open(sys.argv[3], 'w').write(raw)
    start = raw.find('[{')
    if start < 0: raise ValueError('layout JSON missing or root unavailable')
    nodes, _ = json.JSONDecoder().raw_decode(raw[start:])
    root = E.Element('hierarchy')
    def add(n, parent):
        attrs = {key: str(n.get(key, '')) for key in ['class', 'text', 'content-desc', 'bounds']}
        attrs['clickable'] = str('CLICKABLE' in n.get('interactions', [])).lower()
        node = E.SubElement(parent, 'node', attrs)
        for child in n.get('children', []): add(child, node)
    for n in nodes: add(n, root)
    E.ElementTree(root).write(sys.argv[4], encoding='utf-8', xml_declaration=True)
except (subprocess.SubprocessError, ValueError, OSError) as exc:
    print(f'Layout capture failed: {exc}', file=sys.stderr)
    sys.exit(1)
PYLAYOUT
    then
        ui_decode
        return 0
    fi
    return 1
}

dump_ui_retry() {
    local attempt
    for attempt in 1 2 3; do
        if dump_ui; then return 0; fi
        sleep 0.5
    done
    return 1
}

tap_retry() {
    local attempt
    for attempt in 1 2 3; do
        if tap_text "$1"; then return 0; fi
        sleep 0.5
    done
    return 1
}

tap_edittext_retry() {
    local attempt
    for attempt in 1 2 3; do
        if tap_edittext; then return 0; fi
        sleep 0.5
    done
    return 1
}

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
TOKEN="countdown$(date +%s)$$"
NUM="+1555$(date +%s | tail -c 8)"
PREFS="shared_prefs/messages_settings.xml"
RUN_DIR=$(mktemp -d "$TMP/countdown.XXXXXX")
CONV=""
HAD_PREFS=false

db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -n "$CONV" ]; then
        db "DELETE FROM messages WHERE conversation_id=$CONV;" >/dev/null 2>&1 || true
        db "DELETE FROM conversations WHERE id=$CONV;" >/dev/null 2>&1 || true
    fi
    adb_ shell content delete --uri content://sms --where "\"body LIKE '$TOKEN%'\"" >/dev/null 2>&1 || true
    if $HAD_PREFS; then
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$RUN_DIR/settings.backup.xml" || true
    else
        adb_ shell "run-as $PKG rm -f $PREFS" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

adb_ shell am force-stop "$PKG"
if adb_ exec-out run-as "$PKG" cat "$PREFS" > "$RUN_DIR/settings.backup.xml" 2>/dev/null; then HAD_PREFS=true; fi
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null
bash "$(dirname "$0")/grant-permissions.sh" >/dev/null

set_delay() {
    adb_ shell am force-stop "$PKG"
    python3 - "$RUN_DIR/settings.backup.xml" "$RUN_DIR/settings.xml" "$1" "${TEST_NEW_UI:-true}" <<'PY'
import sys, xml.etree.ElementTree as E
try: root = E.parse(sys.argv[1]).getroot()
except (E.ParseError, OSError): root = E.Element('map')
for name, tag, value in [('first_import_done','boolean','true'),('delayed_sending_enabled','boolean','true'),('delay_seconds','int',sys.argv[3]),('use_new_ui','boolean',sys.argv[4])]:
    for old in list(root):
        if old.get('name') == name: root.remove(old)
    E.SubElement(root, tag, name=name, value=value)
E.ElementTree(root).write(sys.argv[2], encoding='utf-8', xml_declaration=True)
PY
    adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$RUN_DIR/settings.xml"
}

set_delay 30
NOW_MS=$(( $(date +%s) * 1000 ))
CONV=$(db "INSERT INTO conversations (address,name,snippet,timestamp,archived,deleted_at,pinned) VALUES ('$NUM','Countdown test','$TOKEN',$NOW_MS,0,0,0); SELECT last_insert_rowid();" | tail -1)
[ -n "$CONV" ] || { fail 'could not seed conversation'; exit 1; }
db "INSERT INTO messages (conversation_id,body,timestamp,is_me,status,media_type,media_uri,sub_id,transport,address) VALUES ($CONV,'$TOKEN received',$NOW_MS,0,'received','text','',-1,'sms','$NUM');" >/dev/null

open_chat() {
    if [ "${2:-}" = --saved ]; then
        adb_ shell am start -n "$ACT" -a android.intent.action.SENDTO -d "smsto:$NUM" >/dev/null
    else
        adb_ shell "am start -n $ACT -a android.intent.action.SENDTO -d smsto:$NUM --es sms_body '$1'" >/dev/null
    fi
    for attempt in 1 2 3 4 5; do
        if dump_ui && grep -q 'class="android.widget.EditText"' "$TMP/ui.xml" && grep -qF "$1" "$TMP/ui.xml"; then return 0; fi
        sleep 1
    done
    fail 'could not open seeded conversation'; return 1
}

assert_countdown_in_composer() {
    dump_ui_retry || return 1
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys, xml.etree.ElementTree as E
root=E.parse(sys.argv[1]).getroot()
nodes=list(root.iter('node'))
parents={child:parent for parent in root.iter() for child in parent}
def bounds(n): return list(map(int,re.findall(r'\d+',n.get('bounds',''))))
fields=[n for n in nodes if n.get('class')=='android.widget.EditText']
buttons=[]
for node in nodes:
    if 'Cancel' not in node.get('content-desc',''): continue
    while node.get('clickable')!='true' and node in parents: node=parents[node]
    if node.get('clickable')=='true': buttons.append(node)
assert fields and buttons, 'no accessible countdown cancel control'
f=bounds(fields[0]); b=bounds(buttons[0])
assert abs((f[1]+f[3])-(b[1]+b[3]))<320, 'countdown is not alongside composer'
assert b[2]-b[0]<=180, 'countdown control is not compact'
assert any(re.fullmatch(r'\d+',n.get('text','')) for n in nodes), 'remaining seconds missing'
assert not any(n.get('text','').startswith('Sending in ') for n in nodes), 'top banner remains'
PY
}

db "UPDATE conversations SET draft='$TOKEN cancel' WHERE id=$CONV;" >/dev/null
open_chat "$TOKEN cancel"
tap_retry Send
if assert_countdown_in_composer; then
    pass 'countdown and Cancel are inside send control'
else
    fail 'countdown must be inside send control'
    exit 1
fi
tap_retry Cancel
sleep 1
dump_ui_retry
if grep -q "$TOKEN cancel" "$TMP/ui.xml"; then pass 'cancel retains composed text'; else fail 'cancel lost draft'; fi
if [ "$(db "SELECT COUNT(*) FROM messages WHERE body='$TOKEN cancel';")" = 0 ]; then pass 'cancel did not send'; else fail 'cancel sent message'; fi

tap_retry Send
tap_edittext_retry
sleep 0.5
adb_ shell input keyevent KEYCODE_MOVE_END
type_text " edited"
sleep 1
dump_ui_retry
if grep -q "$TOKEN cancel edited" "$TMP/ui.xml" && ! grep -q 'content-desc="Cancel"' "$TMP/ui.xml"; then pass 'editing cancels countdown and retains edited draft'; else fail 'editing must cancel without losing text'; fi
sleep 31
if [ "$(db "SELECT COUNT(*) FROM messages WHERE body LIKE '$TOKEN cancel%';")" = 0 ]; then pass 'cancelled countdown never sends later'; else fail 'cancelled countdown sent after deadline'; fi

set_delay 3
db "UPDATE conversations SET draft='$TOKEN auto' WHERE id=$CONV;" >/dev/null
open_chat "$TOKEN auto"
tap_retry Send
sleep 5
if [ "$(db "SELECT COUNT(*) FROM messages WHERE body='$TOKEN auto';")" = 1 ]; then pass 'expiry sends exactly once'; else fail 'expiry must persist one outgoing message'; fi
dump_ui_retry
if python3 - "$TMP/ui.xml" <<'PY'
import sys, xml.etree.ElementTree as E
fields=[n for n in E.parse(sys.argv[1]).iter('node') if n.get('class')=='android.widget.EditText']
assert fields and not fields[0].get('text',''), 'sent draft remains in editor'
PY
then pass 'expiry clears only the sent draft'; else fail 'sent draft not cleared'; fi
sleep 3
if [ "$(db "SELECT COUNT(*) FROM messages WHERE body='$TOKEN auto';")" = 1 ]; then pass 'expiry cannot send twice'; else fail 'duplicate send after expiry'; fi
set_delay 30
db "UPDATE conversations SET draft='$TOKEN restored' WHERE id=$CONV;" >/dev/null
if open_chat "$TOKEN restored" --saved; then pass 'reopening restores the saved draft'; else fail 'saved draft was not restored'; fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
