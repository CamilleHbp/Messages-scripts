#!/usr/bin/env bash
# Regression: a picture that arrives while its chat is open must not leave an
# unread badge on the conversation after navigating back to the list.
#
# The data layer counts an incoming MMS as unread the moment it writes the row
# (importProviderMms), which is a second, later step after the chat opened.
# The screen's markRead runs after that and does not reliably win. The fix is
# a viewedConversationId guard: messages arriving for the front conversation
# are never counted as unread in the first place.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+1555770$(date +%s | tail -c 4)"
MARK="unreadview$(date +%s)"
TS=$(( $(date +%s) * 1000 ))

sql() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    sql "DELETE FROM participants WHERE normalized_destination='$NUM';" >/dev/null
}
trap cleanup EXIT

info "0. seed a conversation and open its chat"
adb_ shell pm clear "$PKG" >/dev/null 2>&1
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1

sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$MARK','hello',$TS,0);" >/dev/null
CONV=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
if [ -z "$CONV" ]; then
    bad "could not seed the conversation"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
ok "seeded conversation $CONV at $NUM"

sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) VALUES($CONV,'hello there',$((TS + 1000)),0,'received','text');" >/dev/null
ok "seeded a text message"

info "1. open the chat so it is the front conversation"
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
adb_ shell am start -n "$ACT" -e "conversation_id" "$CONV" >/dev/null 2>&1; sleep 2

info "2. inject an MMS while the chat is open"
PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
STAMP=$(date +%s)
LOCATION="http://mmsc.local/unread_${MARK}"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }

provider "BEGIN;
INSERT INTO canonical_addresses(address) VALUES('$NUM');
INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000);
INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,ct_l,tr_id) VALUES(last_insert_rowid(),$STAMP,1,130,0,-1,'$LOCATION','unread_${MARK}');
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$NUM',137,106 FROM pdu WHERE tr_id='unread_${MARK}';
COMMIT;" >/dev/null

PDU_ID=$(provider "SELECT _id FROM pdu WHERE tr_id='unread_${MARK}';")
if [ -z "$PDU_ID" ]; then
    bad "could not seed the MMS fixture in the provider"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
ok "seeded pending MMS at $LOCATION"

info "3. wait for the app to download and import the MMS"
sleep 8

info "4. navigate back to the conversation list"
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1; sleep 2

info "5. assert no unread badge on the conversation"
UNREAD=$(sql "SELECT unread_count FROM conversations WHERE address='$NUM';")
if [ "${UNREAD:-0}" -eq 0 ]; then
    ok "no unread badge (unread_count=0)"
else
    bad "expected unread_count=0, got $UNREAD"
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
