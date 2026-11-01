#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
adb_ shell am force-stop "$PKG"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 2
for attempt in $(seq 1 12); do
  dump_ui
  if grep -Eq 'Check for updates|Vérifier les mises à jour' "$TMP/ui.xml"; then break; fi
  adb_ shell input swipe 500 1800 500 500 300
  sleep 1
done
grep -Eq 'Check for updates|Vérifier les mises à jour' "$TMP/ui.xml"
grep -Eq 'Installed version:|Version installée :' "$TMP/ui.xml"
version=$(adb_ shell dumpsys package "$PKG" | sed -n 's/.*versionName=//p' | head -1 | tr -d '\r')
grep -Fq "$version" "$TMP/ui.xml"
point=$(python3 - "$TMP/ui.xml" <<'PY'
import sys,re,xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
for node in root.iter('node'):
 if node.get('clickable')=='true' and any(n.get('text') in ('Check for updates','Vérifier les mises à jour') for n in node.iter('node')):
  x,y,r,b=map(int,re.findall(r'\d+',node.get('bounds')));print((x+r)//2,(y+b)//2);break
else:raise SystemExit('Update control has no accessible click target')
PY
)
adb_ shell input tap $point
info "PASS: installed version $version and actionable manual update check"
