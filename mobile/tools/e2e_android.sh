#!/usr/bin/env bash
# End-to-end check on an Android emulator (run by .github/workflows/mobile.yml):
# a throw-away VLESS server runs on the CI host (10.0.2.2 from the emulator), the debug APK imports it
# through a vlessclient://add/ link, connects, and the test checks that sing-box picked the node,
# that traffic from the phone reaches the server through the tunnel, and takes screenshots of every tab.
# usage: e2e_android.sh <apk> <server uuid> <server log> <out dir>
set -euo pipefail
APK=$1 UUID=$2 SERVER_LOG=$3 OUT=$4
PKG=io.github.dovletix.vlessclient
mkdir -p "$OUT"

shot() { adb exec-out screencap -p > "$OUT/$1.png"; }

# tap a bottom-bar tab by its label (Flutter exposes labels to accessibility, so uiautomator sees them)
tap_label() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null
  adb shell cat /sdcard/ui.xml > "$OUT/ui.xml"
  python3 - "$1" "$OUT/ui.xml" <<'EOF' > "$OUT/tap.txt"
import re, sys
label, path = sys.argv[1], sys.argv[2]
xml = open(path, encoding="utf-8").read()
for node in re.findall(r"<node [^>]*>", xml):
    if re.search(r'(content-desc|text)="[^"]*' + re.escape(label), node):
        m = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            break
EOF
  read -r x y < "$OUT/tap.txt" || { echo "label '$1' not found"; return 1; }
  adb shell input tap "$x" "$y"
}

adb logcat -c || true
adb install -r -g "$APK"
# the VPN consent dialog cannot be tapped reliably in CI: grant it the way the system would
adb shell appops set "$PKG" ACTIVATE_VPN allow

LINK="vless://$UUID@10.0.2.2:10443?type=tcp&security=none#CI%20server"
ENC=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$LINK")
adb shell am start -W -a android.intent.action.VIEW -d "vlessclient://add/$ENC" "$PKG"

adb forward tcp:12090 tcp:12090
SECRET=""
ok=0
for i in $(seq 1 60); do
  sleep 2
  [ -n "$SECRET" ] || SECRET=$(adb shell run-as "$PKG" cat files/settings.json 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["api"]["secret"])' 2>/dev/null || true)
  [ -n "$SECRET" ] || continue
  # up = the tunnel interface exists and the urltest group has measured a node
  if adb shell ip link 2>/dev/null | grep -q tun && \
     curl -fsS -H "Authorization: Bearer $SECRET" http://127.0.0.1:12090/proxies/proxy 2>/dev/null | grep -q '"delay"'; then ok=1; break; fi
done
sleep 5
shot 1-home
adb shell ip addr > "$OUT/ip-addr.txt" || true
[ "$ok" = 1 ] || { echo "VPN did not come up"; adb logcat -d > "$OUT/logcat.txt"; adb shell run-as "$PKG" cat files/sing-box.log > "$OUT/sing-box.log" || true; exit 1; }

curl -fsS -H "Authorization: Bearer $SECRET" http://127.0.0.1:12090/proxies/proxy > "$OUT/proxy.json"
python3 - "$OUT/proxy.json" <<'EOF'
import json, sys
p = json.load(open(sys.argv[1]))
print("urltest group:", p.get("type"), "now:", p.get("now"), "history:", p.get("history"))
assert p.get("now") == "node-01", "the proxy group did not pick the CI server"
EOF

# traffic from a phone process (the shell user) must go through the tunnel and reach the VLESS server
adb shell "printf 'GET /generate_204 HTTP/1.1\r\nHost: connectivitycheck.gstatic.com\r\nConnection: close\r\n\r\n' | toybox nc -w 10 connectivitycheck.gstatic.com 80" > "$OUT/nc.txt" || true
sleep 2
curl -fsS -H "Authorization: Bearer $SECRET" http://127.0.0.1:12090/connections > "$OUT/connections.json" || true
head -3 "$OUT/nc.txt"
grep -q "HTTP/1.1 204" "$OUT/nc.txt" || { echo "no answer to the request from the phone"; exit 1; }
# sing-box sends the server the IP it connected to (sniffing does not override the destination)
grep -q "inbound connection to [0-9.]*:80$" "$SERVER_LOG" || { echo "the request did not reach the VLESS server"; tail -50 "$SERVER_LOG"; exit 1; }
echo "tunnel OK: the request went through the VLESS server"
python3 - "$OUT/connections.json" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))["connections"]
apps = sorted({x["metadata"].get("processPath", "").split(" (")[0] for x in c} - {""})
print("connections:", len(c), "apps seen by the monitor:", apps)
assert apps, "no connection was attributed to an app"
EOF

# let the monitor collect a few samples, then visit every tab
sleep 4
for t in "Программы:2-apps" "Сайты:3-sites" "Серверы:4-servers" "Настройки:5-settings"; do
  tap_label "${t%%:*}"
  sleep 2
  shot "${t##*:}"
done
tap_label "VPN"
sleep 1
adb logcat -d > "$OUT/logcat.txt"
adb shell run-as "$PKG" cat files/sing-box.log > "$OUT/sing-box.log" || true
echo "e2e passed"
