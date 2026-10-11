#!/usr/bin/env bash
# Regression: after a picture arrives, the conversation list line must show
# "Photo" with the correct time and direction — not the previous text snippet.
#
# importProviderMms writes the message rows and bumps unread, but it never
# updated the conversation's snippet, timestamp, or last_is_me. The fix calls
# refreshConversationSnippetFor for each affected conversation after the loop.
#
# A real MMS download needs a carrier MMSC that is not present on the AVD, so
# this seeds a downloaded m_type=132 retrieve-conf directly into the provider
# and triggers the app's normal sync. That still runs importProviderMms and the
# new snippet refresh against the real conversation.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+1555771$(date +%s | tail -c 4)"
MARK="snip$(date +%s)"
TS=$(( $(date +%s) * 1000 ))

sql() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    sql "DELETE FROM participants WHERE normalized_destination='$NUM';" >/dev/null
}
trap cleanup EXIT

info "0. seed a conversation with a text snippet"
adb_ shell pm clear "$PKG" >/dev/null 2>&1
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1

sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$MARK','old text',$TS,0);" >/dev/null
CONV=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
if [ -z "$CONV" ]; then
    bad "could not seed the conversation"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
ok "seeded conversation $CONV at $NUM"

sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) VALUES($CONV,'old text',$((TS + 1000)),0,'received','text');" >/dev/null
ok "seeded a text message with snippet 'old text'"

info "1. seed a downloaded MMS in the provider and trigger a sync"
PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
STAMP=$(( TS + 60000 ))
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }

provider "BEGIN;
INSERT INTO canonical_addresses(address) VALUES('$NUM');
INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000);
INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(last_insert_rowid(),$STAMP,1,132,1,1,'$MARK');
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$NUM',137,106 FROM pdu WHERE tr_id='$MARK';
INSERT INTO part(mid,ct,cl,_data) SELECT _id,'image/jpeg','${MARK}-img','${STAMP}' FROM pdu WHERE tr_id='$MARK';
COMMIT;" >/dev/null

PDU_ID=$(provider "SELECT _id FROM pdu WHERE tr_id='$MARK';")
if [ -z "$PDU_ID" ]; then
    bad "could not seed the MMS fixture in the provider"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
ok "seeded downloaded MMS (pdu id=$PDU_ID) in the provider"

info "2. trigger a sync so the app imports the MMS"
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4

info "3. assert the snippet is now Photo"
SNIPPET=$(sql "SELECT snippet FROM conversations WHERE address='$NUM';")
if [ "${SNIPPET:-}" = "Photo" ]; then
    ok "snippet is 'Photo'"
else
    bad "expected snippet 'Photo', got '${SNIPPET:-}'"
fi

NEW_TS=$(sql "SELECT timestamp FROM conversations WHERE address='$NUM';")
if [ "${NEW_TS:-0}" -gt "$TS" ]; then
    ok "timestamp updated ($NEW_TS > $TS)"
else
    bad "expected timestamp > $TS, got ${NEW_TS:-0}"
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
