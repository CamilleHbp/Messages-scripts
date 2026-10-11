#!/usr/bin/env bash
# test-notification-open-group-member.sh
# Verifies: a notification for someone who exists only inside a group opens the
# group that actually holds their message, and does not create a phantom thread.
#
# A group member with no 1:1 of their own has no conversation row addressed to
# them. receiveMessage stores their text in the group, but the notification used
# to resolve the address with the strict lookup, get null, and let the caller
# create a conversation -- so tapping the notification opened an empty thread
# and the incoming message was invisible. Mark-as-read and delete no-opped the
# same way.
set -euo pipefail
source "$(dirname "$0")/env.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# Unique per run. The app mirrors every inbound SMS into the system provider on
# startup sync, and those provider rows cannot be deleted from a shell (they are
# owned by the app), so a fixed address would be re-imported by every later run
# and a stale provider row would be imported into a fresh 1:1 -- reproducing the
# very phantom this test exists to catch. Fresh numbers keep each run isolated.
RUN_ID=$(( ($$ + RANDOM) % 9000 + 1000 ))
MEMBER="+1555999$RUN_ID"
GROUP_ADDR="+1555888$RUN_ID"
# Unique marker, distinct prefix from either address.
MARK="gogm$$x$RANDOM"

sq() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r\n'; }

info "Clean slate: remove any leftover rows from a previous run"
# A leftover 1:1 for the member would win the inbound lookup over the group we
# are about to seed, so the message would be stored there and the test would
# measure the wrong thing.
#
# Order matters: foreign keys are off on this connection (the schema declares
# ON DELETE CASCADE but SQLite only honours it with the pragma set), so deleting
# a conversation orphans its messages and recipients instead of removing them.
# An orphaned message left in a stale conversation still renders, and it is what
# made this script pass a stale screen on later runs. Children first.
sq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$MEMBER','$GROUP_ADDR'));"
sq "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$MEMBER','$GROUP_ADDR'));"
sq "DELETE FROM conversations WHERE address IN ('$MEMBER','$GROUP_ADDR');"
sq "DELETE FROM messages WHERE body LIKE 'gogm%';"

info "Seed a group containing $MEMBER (who has no 1:1 thread)"
sq "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,group_title) VALUES('$GROUP_ADDR','$GROUP_ADDR','',0,0,0,'$GROUP_ADDR');"
GID=$(sq "SELECT id FROM conversations WHERE group_title='$GROUP_ADDR' ORDER BY id DESC LIMIT 1;")
if [ -z "$GID" ]; then
  fail "could not seed the group"
  exit 1
fi
# Guard against matching a leftover group from an earlier run: the one just
# inserted must be the only row carrying this title and address.
SEEDED=$(sq "SELECT count(*) FROM conversations WHERE group_title='$GROUP_ADDR';")
if [ "$SEEDED" != "1" ]; then
  fail "found $SEEDED groups titled '$GROUP_ADDR', expected exactly 1"
  exit 1
fi
# last_insert_rowid() is not usable here: the second insert targets a different
# table, so it would return that table's rowid rather than the conversation id.
sq "INSERT INTO conversation_recipients(conversation_id,address) VALUES($GID,'$GROUP_ADDR');"
sq "INSERT INTO conversation_recipients(conversation_id,address) VALUES($GID,'$MEMBER');"

RCPT=$(sq "SELECT count(*) FROM conversation_recipients WHERE conversation_id=$GID;")
if [ "$RCPT" = "2" ]; then
  pass "seeded group $GID with 2 recipients"
else
  fail "group has $RCPT recipients, expected 2"
fi

if [ -n "$(sq "SELECT id FROM conversations WHERE address='$MEMBER';")" ]; then
  fail "$MEMBER must have no 1:1 for this test to be meaningful"
fi

info "Member texts the device from inside the group"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 1
adb_ emu sms send "$MEMBER" "$MARK" >/dev/null 2>&1

# emu sms send is asynchronous and the broadcast can land well after it returns;
# a fixed sleep reads the table before the row exists and the run flakes. Poll
# for the row the way the other notification scripts do.
STORED=""
for _ in $(seq 1 25); do
  STORED=$(sq "SELECT conversation_id FROM messages WHERE body='$MARK';")
  [ -n "$STORED" ] && break
  sleep 1
done
if [ "$STORED" = "$GID" ]; then
  pass "message stored in the group (conversation $GID)"
else
  fail "message stored in conversation '$STORED', expected the group $GID"
fi

info "Fire the notification tap intent"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 1
adb_ shell am start -n "$PKG/.MainActivity" --es open_conversation_address "$MEMBER" >/dev/null 2>&1

# Cold start: the activity resumes and the conversation query has to settle
# before the row is on screen. Poll rather than sleep a fixed amount.
SEEN=0
for _ in $(seq 1 20); do
  sleep 2
  if dump_ui >/dev/null 2>&1; then
    # dump_ui decodes numeric character references into ui.decoded.xml; matchers
    # read that copy, not the raw dump.
    if grep -q "$MARK" "$TMP/ui.decoded.xml" 2>/dev/null; then
      SEEN=1
      break
    fi
  fi
done
if [ "$SEEN" = "1" ]; then
  pass "the opened thread shows the incoming message"
else
  fail "the opened thread does not show the message"
fi

PHANTOM=$(sq "SELECT count(*) FROM conversations WHERE address='$MEMBER' AND id NOT IN (SELECT conversation_id FROM messages);")
if [ "$PHANTOM" = "0" ]; then
  pass "no phantom empty conversation was created"
else
  fail "a phantom conversation with no messages was created for $MEMBER"
fi

info "Clean up"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$MEMBER','$GROUP_ADDR'));"
sq "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$MEMBER','$GROUP_ADDR'));"
sq "DELETE FROM conversations WHERE address IN ('$MEMBER','$GROUP_ADDR');"
sq "DELETE FROM messages WHERE body LIKE 'gogm%';"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL check(s)"
  exit 1
fi
echo "ALL CHECKS PASSED"
exit 0