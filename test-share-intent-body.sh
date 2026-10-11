#!/usr/bin/env bash
# Regression for issue #304 follow-up: a body handed over by another app must
# arrive readable.
#
# The reporter sends a bank receipt from Bank Mellat. Their app escapes the
# URI by mapping UTF-8 bytes onto ISO-8859-1 chars, so the body arrived as
# "Ù…Ø±Ù†" and was sent to the recipient exactly like that. The same app also
# puts the body in the `sms_body` extra on a SENDTO, which nothing read, so the
# composer came up empty.
#
# Every case below is asserted on the text in the composer after a real intent
# is fired through `am start`.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

ADDR="+15551239911"

# Fires an intent, then reads the composer back out of the UI tree. The
# composer holds the draft as plain `text`, so no screenshot is needed.
composer_text() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    eval "$1" >/dev/null 2>&1
    sleep 3
    dump_ui >/dev/null 2>&1 || return 1
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# The composer is the only EditText on the screen. Picking the longest `text`
# instead would pick the contact header, which is as long as a short body and
# is present whether or not the body arrived at all.
for node in re.finditer(r"<node[^>]*>", xml):
    markup = node.group(0)
    if "EditText" not in markup:
        continue
    m = re.search(r'text="([^"]*)"', markup)
    print(m.group(1) if m else "")
    break
PY
}

# Compares the composer against the expected body.
#
# The whitespace-insensitive fallback matters: the composer soft-wraps and
# uiautomator has collapsed some of the runs, so an exact substring match on
# the receipt is not reliable. An empty composer must not match — `"" in x` is
# true for every x, which would make a dropped body look like a pass.
has_marker() {
    python3 - "$1" "$2" <<'PY'
import sys, unicodedata
got, want = sys.argv[1], sys.argv[2]
strip = lambda s: "".join(c for c in s if not unicodedata.category(c).startswith("Cf"))
got, want = strip(got), strip(want)
if not got.strip():
    sys.exit(1)
squash = lambda s: "".join(s.split())
sys.exit(0 if (want in got or got in want or squash(want) in squash(got)) else 1)
PY
}

dismiss_default_sms_prompt() {
    for i in 1 2 3; do
        dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
        grep -q "Set as default SMS app" "$TMP/ui.decoded.xml" || return 0
        tap_text "Not now" >/dev/null 2>&1 || adb_ shell input keyevent KEYCODE_BACK
        sleep 1.5
    done
}

unlock_device() {
    adb_ shell input keyevent 26 >/dev/null 2>&1 || true
    sleep 0.5
    adb_ shell input keyevent 26 >/dev/null 2>&1 || true
    sleep 1
    adb_ shell input swipe 540 1800 540 700 400 >/dev/null 2>&1 || true
    adb_ shell locksettings set-disabled true >/dev/null 2>&1 || true
    sleep 0.5
}

unlock_device

# Bank Mellat's receipt, and the same string after the sender's own fault: it
# escaped the URI by reading UTF-8 bytes as ISO-8859-1, which is what produced
# the unreadable body in #304. Built here rather than pasted so the two forms
# cannot drift apart.
read -r -d '' RECEIPT <<'EOF'
مبلغ 100,000 ریال به کارت 5022 شماره تراکنش 1405/07/15
EOF
RECEIPT=$(printf '%s' "$RECEIPT")
# `iconv` is not usable here: this locale rejects the Persian bytes it is
# being asked to read, and it exits with an empty result rather than the
# mangled string the sender actually produced.
MOJIBAKE=$(python3 -c 'import sys;print(sys.argv[1].encode("utf-8").decode("latin-1"))' "$RECEIPT")
RECEIPT_ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe="-_.~"))' "$RECEIPT")
MOJIBAKE_ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe="-_.~"))' "$MOJIBAKE")
DOUBLE_ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe="-_.~"))' "$RECEIPT_ENC")

info "The bank receipt arrives readable when the sender mangled the encoding"
GOT=$(composer_text "adb_ shell \"am start -a android.intent.action.SENDTO \
    -d 'smsto:$ADDR?body=$MOJIBAKE_ENC' $ACT\"")
if has_marker "$GOT" "$RECEIPT"; then
    ok "Latin-1 mangled body decoded back to Persian"
else
    bad "body not repaired, composer reads: $GOT"
fi

info "A body on the sms_body extra is read, not dropped"
GOT=$(composer_text "adb_ shell \"am start -a android.intent.action.SENDTO \
    -d 'smsto:$ADDR' --es sms_body '$RECEIPT' $ACT\"")
if has_marker "$GOT" "$RECEIPT"; then
    ok "sms_body extra reaches the composer"
else
    bad "sms_body extra ignored, composer reads: $GOT"
fi

info "sms_body wins over a body on the URI, matching other SMS apps"
GOT=$(composer_text "adb_ shell \"am start -a android.intent.action.SENDTO \
    -d 'smsto:$ADDR?body=$MOJIBAKE_ENC' --es sms_body '$RECEIPT' $ACT\"")
if has_marker "$GOT" "$RECEIPT"; then
    ok "sms_body takes precedence over the URI body"
else
    bad "URI body was preferred over sms_body, composer reads: $GOT"
fi

info "EXTRA_TEXT on SENDTO is read"
GOT=$(composer_text "adb_ shell \"am start -a android.intent.action.SENDTO \
    -d 'smsto:$ADDR' --es android.intent.extra.TEXT '$RECEIPT' $ACT\"")
if has_marker "$GOT" "$RECEIPT"; then
    ok "EXTRA_TEXT on SENDTO reaches the composer"
else
    bad "EXTRA_TEXT on SENDTO ignored, composer reads: $GOT"
fi

info "A body escaped twice is decoded, not sent as literal %D9%85"
GOT=$(composer_text "adb_ shell \"am start -a android.intent.action.SENDTO \
    -d 'smsto:$ADDR?body=$DOUBLE_ENC' $ACT\"")
if has_marker "$GOT" "$RECEIPT"; then
    ok "twice-escaped body fully decoded"
else
    bad "second decode pass missing, composer reads: $GOT"
fi

info "A correctly escaped body is unchanged"
GOT=$(composer_text "adb_ shell \"am start -a android.intent.action.SENDTO \
    -d 'smsto:$ADDR?body=$RECEIPT_ENC' $ACT\"")
if has_marker "$GOT" "$RECEIPT"; then
    ok "normally escaped body still decodes"
else
    bad "normal body regressed, composer reads: $GOT"
fi

info "Western text is left alone"
GOT=$(composer_text "adb_ shell \"am start -a android.intent.action.SENDTO \
    -d 'smsto:$ADDR?body=Caf%C3%A9%20na%C3%AFve%20%E2%80%94%2050%25' $ACT\"")
if has_marker "$GOT" "Café naïve — 50%"; then
    ok "Latin-1 accented text is not rewritten"
else
    bad "Western text was altered, composer reads: $GOT"
fi

adb_ shell am force-stop "$PKG" >/dev/null 2>&1

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
