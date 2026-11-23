#!/usr/bin/env bash
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
stamp="$(printf '%s%s' "$(date +%s)" "$$" | tr '0-9' 'a-j')"
address="GroupSearch$stamp"
title="Café $stamp"
sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$address');
         DELETE FROM conversations WHERE address='$address';" >/dev/null
}
trap cleanup EXIT

adb_ shell am start -n "$ACT" >/dev/null
wait_for_text "Search" 5 || { bad "inbox did not open"; exit 1; }
adb_ shell am force-stop "$PKG"
sql "INSERT INTO conversations(address,name,snippet,timestamp,group_title,group_title_custom) VALUES('$address','Alice','Latest message',$(date +%s)000,'$title',1);
     INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type)
     SELECT id,snippet,timestamp,0,'received','text' FROM conversations WHERE address='$address';" || { bad "could not seed group"; exit 1; }
adb_ shell am start -n "$ACT" >/dev/null
wait_for_text "$title" 5 || { bad "group fixture missing from inbox"; exit 1; }
tap_text "Search" || { bad "search control unavailable"; exit 1; }
type_text "cafe $stamp"
sleep 1
if wait_for_text "$title" 3; then ok "unaccented query finds the named group"; else bad "named group missing from results"; fi
type_text "missing"
if wait_for_text "No matching conversations" 3; then ok "empty search has feedback"; else bad "empty search has no feedback"; fi
if tap_text "Clear search" && wait_for_text "$title" 3 && ui_has "Close search"; then
    ok "clearing the query restores the inbox in search mode"
else
    bad "clear search did not restore the list"
fi

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
