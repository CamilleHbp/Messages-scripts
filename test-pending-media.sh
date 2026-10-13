#!/usr/bin/env bash
# Regression for #326: picking a picture from '+' -> Gallery sent it the moment
# the picker closed, so it could never be captioned or dropped. It must now wait
# in the composer until Send.
#
# The picture is seeded into MediaStore so the system Photo Picker has a tile to
# tap. The assertion is the outgoing-image row in the DB: 0 while the picture
# waits, 1 after Send — which is exactly the bug the report described.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PRIMARY="+1555771030"
DB="/data/data/$PKG/databases/messages.db"
STAMP=$(date +%s)
IMGNAME="pending-media-$STAMP.png"

sq() { adb_ shell "run-as $PKG sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }
outgoing_images() {
    sq "select count(*) from messages where is_me=1 and media_type='image'
        and conversation_id=(select id from conversations where address='$PRIMARY' limit 1);"
}
cleanup() {
    sq "delete from messages where conversation_id in
        (select id from conversations where address='$PRIMARY');" >/dev/null
    adb_ shell rm -f "/sdcard/Pictures/$IMGNAME" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS SEND_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done

# A real picture for the picker to show, newest first so the first tile is ours.
make_png() {
    python3 - "$1" <<'PY'
import struct, sys, zlib
w = h = 240
raw = (bytes([0]) + bytes([220, 40, 40]) * w) * h
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw, 9))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
}
make_png "$TMP/$IMGNAME"
adb_ shell mkdir -p /sdcard/Pictures >/dev/null 2>&1
adb_ push "$TMP/$IMGNAME" "/sdcard/Pictures/$IMGNAME" >/dev/null 2>&1
adb_ shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d "file:///sdcard/Pictures/$IMGNAME" >/dev/null 2>&1
sleep 2

info "Open a clean 1:1"
adb_ shell am force-stop "$PKG"; sleep 1
sq "delete from messages where conversation_id in
    (select id from conversations where address='$PRIMARY');" >/dev/null
OPENED=0
for i in 1 2 3; do
    adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
    if wait_for_text "More options" 15; then OPENED=1; break; fi
    adb_ shell am force-stop "$PKG"; sleep 2
done
if [ "$OPENED" = "1" ]; then
    ok "chat opened"
else
    bad "chat did not open"
    echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
if [ "$(outgoing_images)" = "0" ]; then
    ok "no outgoing image to start from"
else
    bad "conversation already had an outgoing image"
fi

info "Pick a picture through '+' -> Gallery"
tap_layout "Attach" >/dev/null || { bad "attach control not found"; }
sleep 1.5
tap_layout "Gallery" >/dev/null || { bad "Gallery row not found"; }
sleep 3

info "The system picker must open"
PICKED=0
for i in 1 2 3 4 5 6; do
    if layout_has "Photo taken"; then
        c=$(layout_center "Photo taken") && adb_ shell input tap $c && PICKED=1 && break
    fi
    if layout_has "Cancel" && layout_has "Photos"; then
        # picker is up but its grid is still settling
        sleep 2
        continue
    fi
    sleep 2
done
if [ "$PICKED" = "1" ]; then
    ok "tapped a photo in the picker"
else
    bad "could not reach the photo picker"
fi
if wait_for_text "More options" 10; then
    ok "returned to the chat"
else
    bad "did not return to the chat after picking"
fi

info "The picture must wait in the composer, not be sent"
if [ "$(outgoing_images)" = "0" ]; then
    ok "picking the picture did not send it"
else
    bad "the picture was sent the moment it was picked (#326 regressed)"
fi
if layout_has "Close"; then
    ok "the composer shows a removable attachment"
else
    bad "no pending attachment in the composer"
fi

info "Send publishes the waiting picture"
tap_layout "Send" >/dev/null || { bad "send button not found"; }
sleep 5
if [ "$(outgoing_images)" = "1" ]; then
    ok "the picture was sent on Send"
else
    bad "the picture was not sent on Send (found $(outgoing_images))"
fi

echo
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
