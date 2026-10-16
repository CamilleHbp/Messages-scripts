#!/usr/bin/env bash
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
finish() { printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"; exit $((FAIL > 0)); }
fatal() { fail "$*"; finish; }

MARK="tray$(date +%s)$$"
NUM="+1555$(printf '%07d' "$(( ($$ * 101 + $(date +%s)) % 10000000 ))")"
OTHER="+1555$(printf '%07d' "$(( ($$ * 101 + $(date +%s) + 1) % 10000000 ))")"
FIRST="$MARK first"
SECOND="$MARK second"
THIRD="$MARK third"
CONTROL="$MARK control"
NOW_MS=$(( $(date +%s) * 1000 ))
FUTURE=$(( NOW_MS + 172800000 ))
SQLITE="${SQLITE:-sqlite3}"

case "$PKG" in *[!a-zA-Z0-9_.]*) fatal "invalid package name";; esac
case "$SQLITE" in *[!a-zA-Z0-9_/.-]*) fatal "invalid SQLite executable path";; esac
[ "$(adb_ shell getprop ro.kernel.qemu | tr -d '\r')" = "1" ] || fatal "this send test requires an Android emulator"

db() { printf '.timeout 5000\n%s\n' "$1" | adb_ shell "run-as $PKG $SQLITE databases/messages.db" | tr -d '\r'; }
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "content delete --uri content://sms --where \"body LIKE '$MARK%'\"" >/dev/null 2>&1 || true
    local optional_deletes="" table
    for table in conversation_recipients conversation_notifications; do
        if [ "$(db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null)" = "1" ]; then
            optional_deletes+="DELETE FROM $table WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$NUM','$OTHER'));"
        fi
    done
    db "BEGIN;
        DELETE FROM scheduled_messages WHERE body LIKE '$MARK%';
        DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$NUM','$OTHER'));
        $optional_deletes
        DELETE FROM conversations WHERE address IN ('$NUM','$OTHER');
        DELETE FROM participants WHERE normalized_destination IN ('$NUM','$OTHER');
        COMMIT;" >/dev/null 2>&1 || true
}

[ "$(db 'SELECT 1;')" = "1" ] || fatal "SQLite unavailable; set SQLITE to its device path and install/launch the debug app first"
[ "$(db "SELECT COUNT(*) FROM conversations WHERE address IN ('$NUM','$OTHER');")" = "0" ] || fatal "generated test addresses already exist; rerun with fresh addresses"
trap cleanup EXIT

layout_to_ui() {
    python3 - "$TMP/tray-layout.json" "$TMP/ui.xml" <<'PY_LAYOUT'
import json, re, sys, xml.etree.ElementTree as ET
raw = open(sys.argv[1], encoding='utf-8').read()
data = None
for match in re.finditer(r'(?m)^\s*[\[{]', raw):
    try:
        data, _ = json.JSONDecoder().raw_decode(raw[match.start():].lstrip())
        break
    except json.JSONDecodeError:
        continue
if data is None:
    sys.exit(1)
root = ET.Element('hierarchy')
def walk(value, parent):
    if isinstance(value, list):
        for item in value:
            walk(item, parent)
    elif isinstance(value, dict):
        if value.get('off-screen') is True or value.get('off-screen') == 'true':
            return
        current = parent
        if 'class' in value or 'bounds' in value:
            interactions = value.get('interactions') or []
            attrs = {key: str(value.get(key, '')) for key in ('class', 'text', 'bounds', 'resource-id')}
            attrs['content-desc'] = str(value.get('content-desc', value.get('contentDesc', '')))
            for attribute, interaction in [('clickable', 'CLICKABLE'), ('scrollable', 'SCROLLABLE'), ('long-clickable', 'LONG_CLICKABLE'), ('focusable', 'FOCUSABLE')]:
                attrs[attribute] = str(interaction in interactions).lower()
            attrs['enabled'] = str(value.get('enabled', True)).lower()
            current = ET.SubElement(parent, 'node', attrs)
        for key in ('content', 'children'):
            walk(value.get(key), current)
walk(data, root)
if not list(root):
    sys.exit(1)
ET.ElementTree(root).write(sys.argv[2], encoding='utf-8', xml_declaration=True)
PY_LAYOUT
}
fresh_ui() {
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml" "$TMP/tray-layout.json"
    if command -v "$ANDROID_CLI" >/dev/null 2>&1; then
        python3 - "$ANDROID_CLI" "$ANDROID_SERIAL" "$TMP/tray-layout.json" <<'PY_CAPTURE' || return 1
import subprocess, sys
try:
    with open(sys.argv[3], 'w', encoding='utf-8') as output:
        result = subprocess.run([sys.argv[1], 'layout', '--full', '--device', sys.argv[2]], stdout=output, stderr=subprocess.DEVNULL, timeout=15)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(1)
PY_CAPTURE
        layout_to_ui
        return $?
    fi
    dump_ui >/dev/null 2>&1
}
ui_query() {
    python3 - "$TMP/ui.xml" "$@" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
mode, value = sys.argv[2:4]
parents = {child: parent for parent in root.iter() for child in parent}
def strings(node):
    return [node.get(k, '').replace('\u2066', '').replace('\u2069', '') for k in ('text', 'content-desc')]
def bounds(node):
    return list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
def matches(node):
    if mode.endswith('_regex'):
        return any(re.fullmatch(value, text) for text in strings(node))
    return value in strings(node)
nodes = [n for n in root.iter('node') if matches(n)]
if mode in ('has', 'has_regex'):
    sys.exit(0 if nodes else 1)
if mode == 'count':
    print(len(nodes))
    sys.exit()
if mode == 'manage':
    candidates = []
    for node in nodes:
        while node is not None:
            icons = [n for n in node.iter('node') if n.get('content-desc') == 'Manage scheduled messages']
            if len(icons) == 1:
                candidates.append(icons[0])
                break
            node = parents.get(node)
    nodes = candidates
if not nodes:
    sys.exit(1)
node = nodes[0]
if mode in ('tap', 'tap_regex'):
    while node.get('clickable') != 'true' and node in parents:
        node = parents[node]
x1, y1, x2, y2 = bounds(node)
if x2 <= x1 or y2 <= y1:
    sys.exit(1)
print((x1+x2)//2, (y1+y2)//2)
PY
}
wait_text() {
    local i
    for i in 1 2 3 4 5; do
        if fresh_ui && ui_query has "$1"; then return 0; fi
        sleep 1
    done
    return 1
}
tap() {
    local xy
    fresh_ui || return 1
    xy=$(ui_query tap "$1") || return 1
    adb_ shell input tap $xy >/dev/null
}
manage() {
    local xy
    fresh_ui || return 1
    xy=$(ui_query manage "$1") || return 1
    adb_ shell input tap $xy >/dev/null
    wait_text "Cancel scheduled message"
}
assert_db() {
    local actual i
    for i in 1 2 3 4 5; do
        actual=$(db "$2")
        if [ "$actual" = "$3" ]; then pass "$1"; return 0; fi
        sleep 1
    done
    fail "$1 (expected $3; got $actual)"
    return 1
}

info "Seed two isolated conversations and deliberately unordered schedules"
adb_ shell am force-stop "$PKG" >/dev/null
CONV=$(db "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$NUM','$MARK target','$MARK history',$NOW_MS); SELECT last_insert_rowid();")
OTHER_CONV=$(db "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$OTHER','$MARK other','$MARK other history',$NOW_MS); SELECT last_insert_rowid();")
[[ "$CONV" =~ ^[0-9]+$ && "$OTHER_CONV" =~ ^[0-9]+$ ]] || fatal "conversation seeding failed"
db "BEGIN;
    INSERT INTO messages(conversation_id,body,timestamp,is_me,status,address) VALUES($CONV,'$MARK history',$NOW_MS,0,'received','$NUM');
    INSERT INTO messages(conversation_id,body,timestamp,is_me,status,address) VALUES($OTHER_CONV,'$MARK other history',$NOW_MS,0,'received','$OTHER');
    INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id) VALUES('$NUM','$THIRD',$(( FUTURE + 7200000 )),$CONV,-1);
    INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id) VALUES('$OTHER','$CONTROL',$FUTURE,$OTHER_CONV,-1);
    INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id) VALUES('$NUM','$FIRST',$FUTURE,$CONV,-1);
    INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id) VALUES('$NUM','$SECOND',$(( FUTURE + 3600000 )),$CONV,-1);
    COMMIT;" >/dev/null || fatal "schedule seeding failed"

adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null
wait_text "$FIRST" || fatal "first scheduled message missing from its conversation"
ui_query has "$SECOND" && pass "second schedule is visible" || fatal "second schedule missing"
if ui_query has "$THIRD" || ui_query has "$CONTROL"; then
    fatal "collapsed tray leaks a third schedule or another conversation"
fi
[ "$(ui_query count 'Manage scheduled messages')" = "2" ] && pass "collapsed tray has exactly two management icons" || fatal "collapsed tray does not expose two management icons"
ui_query has '+1 more' && pass "overflow reports one additional schedule" || fatal "overflow control missing"
if python3 - "$TMP/ui.xml" "$FIRST" "$SECOND" <<'PY'
import re, sys, xml.etree.ElementTree as ET
nodes = list(ET.parse(sys.argv[1]).getroot().iter('node'))
def box(n): return list(map(int, re.findall(r'\d+', n.get('bounds', ''))))
def find(t): return next(n for n in nodes if n.get('text') == t)
a, b = box(find(sys.argv[2])), box(find(sys.argv[3]))
inputs = [box(n) for n in nodes if n.get('class') == 'android.widget.EditText']
assert inputs and a[1] < b[1] and b[3] <= inputs[0][1]
PY
then pass "schedules are chronological and above the composer"; else fatal "tray order or placement is wrong"; fi

tap '+1 more' || fatal "cannot expand overflow"
wait_text "$THIRD" || fatal "overflow sheet does not show the third schedule"
ui_query has "$FIRST" && ui_query has "$SECOND" && pass "overflow sheet exposes all three schedules" || fatal "overflow sheet omits schedules"
ui_query has "$CONTROL" && fatal "overflow sheet exposes another conversation"
manage "$THIRD" || fatal "third schedule cannot be managed from overflow"
for label in 'Change send time' 'Send now' 'Cancel scheduled message' 'Close'; do
    ui_query has "$label" && pass "management offers $label" || fatal "management missing $label"
done

info "Reschedule from the conversation, preserving body and identity"
THIRD_ID=$(db "SELECT id FROM scheduled_messages WHERE body='$THIRD';")
tap 'Change send time' || fatal "reschedule action missing"
wait_text 'Schedule' || fatal "date picker did not open"
NEXT_MONTH=$(python3 - "$TMP/ui.xml" <<'PY_MONTH'
import calendar, re, sys, xml.etree.ElementTree as ET
months = list(calendar.month_name)
for node in ET.parse(sys.argv[1]).getroot().iter('node'):
    match = re.fullmatch(r'([A-Za-z]+) (\d{4})', node.get('text', ''))
    if match and match[1] in months:
        month, year = months.index(match[1]), int(match[2])
        month, year = (1, year + 1) if month == 12 else (month + 1, year)
        print(f'{months[month]} {year}')
        break
else:
    sys.exit(1)
PY_MONTH
) || fatal "cannot identify the reschedule calendar month"
tap 'Change to next month' || fatal "cannot advance the reschedule month"
wait_text "$NEXT_MONTH" || fatal "calendar did not advance to $NEXT_MONTH"
DAY_ONE_PATTERN="(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday), ${NEXT_MONTH% *} 1, ${NEXT_MONTH##* }"
DAY_ONE_CENTER=$(ui_query tap_regex "$DAY_ONE_PATTERN") || fatal "cannot find the first day of $NEXT_MONTH"
adb_ shell input tap $DAY_ONE_CENTER >/dev/null
tap 'Schedule' || fatal "cannot confirm reschedule date"
wait_text 'Select time' || fatal "time picker did not open"
tap 'Schedule' || fatal "cannot confirm reschedule time"
assert_db "reschedule changes timestamp on the existing row" "SELECT COUNT(*) FROM scheduled_messages WHERE id=$THIRD_ID AND body='$THIRD' AND conversation_id=$CONV AND timestamp>$((FUTURE + 7200000));" 1 || finish
wait_text "$FIRST" || fatal "tray did not return after rescheduling"

info "Send now consumes exactly one schedule in the same conversation"
manage "$FIRST" || fatal "first schedule cannot be managed"
tap 'Send now' || fatal "Send now action failed"
assert_db "sent schedule is consumed" "SELECT COUNT(*) FROM scheduled_messages WHERE body='$FIRST';" 0 || finish
assert_db "message is persisted once in its own conversation" "SELECT COUNT(*) FROM messages WHERE body='$FIRST' AND conversation_id=$CONV AND is_me=1;" 1 || finish
sleep 2
assert_db "send-now does not duplicate the message" "SELECT COUNT(*) FROM messages WHERE body='$FIRST';" 1 || finish
wait_text "$THIRD" || fatal "third schedule does not fill the freed tray slot"
ui_query has '+1 more' && fatal "overflow remains after only two schedules are left"

info "Cancel removes only the selected schedule"
manage "$SECOND" || fatal "second schedule cannot be managed"
tap 'Cancel scheduled message' || fatal "cancellation action failed"
assert_db "canceled schedule is removed" "SELECT COUNT(*) FROM scheduled_messages WHERE body='$SECOND';" 0 || finish
assert_db "cancel does not send the canceled text" "SELECT COUNT(*) FROM messages WHERE body='$SECOND';" 0 || finish
assert_db "rescheduled row and other conversation survive" "SELECT COUNT(*) FROM scheduled_messages WHERE body IN ('$THIRD','$CONTROL');" 2 || finish
wait_text "$THIRD" || fatal "remaining schedule disappeared"
ui_query has "$SECOND" && fatal "canceled text still appears in the tray"
[ "$(ui_query count 'Manage scheduled messages')" = "1" ] && pass "tray shrinks to its remaining schedule" || fatal "tray did not shrink after cancellation"
finish
