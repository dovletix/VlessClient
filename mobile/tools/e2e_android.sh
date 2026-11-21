#!/usr/bin/env bash
# End-to-end check on an Android emulator (run by .github/workflows/mobile.yml):
# a throw-away VLESS server runs on the CI host (10.0.2.2 from the emulator), the debug APK imports it
# through a vlessclient://add/ link, connects, and the test checks that sing-box picked the node,
# that traffic from the phone reaches the server through the tunnel, and takes screenshots of every tab.
# With a fifth argument (the access log of an Xray XHTTP server on port 10444) it also checks the XHTTP path
# through the app's bundled Xray.
# usage: e2e_android.sh <apk> <server uuid> <server log> <out dir> [xray access log]
set -euo pipefail
APK=$1 UUID=$2 SERVER_LOG=$3 OUT=$4 XRAY_LOG=${5:-}
PKG=io.github.dovletix.vlessclient
mkdir -p "$OUT"

shot() { adb exec-out screencap -p > "$OUT/$1.png"; }

# tap bottom-bar tab number $1 (0..4). uiautomator cannot be used: the screen redraws every second
# (live statistics), so it never reaches the idle state it waits for. The bar is 64 dp high at the bottom.
tap_tab() {
  local size dens w h d
  size=$(adb shell wm size | tail -1 | sed 's/.*: //' | tr -d '\r')
  dens=$(adb shell wm density | tail -1 | sed 's/.*: //' | tr -d '\r')
  w=${size%x*} h=${size#*x}
  d=$(python3 -c "print($dens / 160)")
  adb shell input tap "$(( w * (2 * $1 + 1) / 10 ))" "$(python3 -c "print(int($h - 34 * $d))")"
}

adb logcat -c || true
adb install -r -g "$APK"
# the VPN consent dialog cannot be tapped reliably in CI: grant it the way the system would
adb shell appops set "$PKG" ACTIVATE_VPN allow

LINK="vless://$UUID@10.0.2.2:10443?type=tcp&security=none#CI%20server"
[ -z "$XRAY_LOG" ] || LINK="$LINK"$'\n'"vless://$UUID@10.0.2.2:10444?type=xhttp&security=none&path=%2Fci&mode=auto#CI%20xhttp"
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
assert p.get("now") in ("node-01", "node-02"), "the proxy group did not pick a CI server"
EOF

# traffic from a phone process (the shell user) must go through the tunnel and reach the VLESS server
adb shell "printf 'GET /generate_204 HTTP/1.1\r\nHost: connectivitycheck.gstatic.com\r\nConnection: close\r\n\r\n' | toybox nc -w 10 connectivitycheck.gstatic.com 80" > "$OUT/nc.txt" || true
sleep 2
curl -fsS -H "Authorization: Bearer $SECRET" http://127.0.0.1:12090/connections > "$OUT/connections.json" || true
head -3 "$OUT/nc.txt"
grep -q "HTTP/1.1 204" "$OUT/nc.txt" || { echo "no answer to the request from the phone"; exit 1; }
# sing-box sends the server the IP it connected to (sniffing does not override the destination)
grep -q "inbound connection to [0-9.]*:80$" "$SERVER_LOG" || { [ -n "$XRAY_LOG" ] && grep -q "tcp:[0-9.]*:80 " "$XRAY_LOG"; } || \
  { echo "the request did not reach a VLESS server"; tail -50 "$SERVER_LOG"; exit 1; }
echo "tunnel OK: the request went through the VLESS server"

if [ -n "$XRAY_LOG" ]; then
  # the XHTTP node: sing-box -> local SOCKS -> bundled Xray -> (back through sing-box's xray-in) -> the XHTTP server
  adb shell ps -A | grep libxray > "$OUT/xray-ps.txt" || { echo "the bundled Xray is not running"; exit 1; }
  curl -sS -H "Authorization: Bearer $SECRET" "http://127.0.0.1:12090/proxies/node-02/delay?timeout=10000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" > "$OUT/xhttp-delay.json" || true
  cat "$OUT/xhttp-delay.json"; echo
  grep -q '"delay"' "$OUT/xhttp-delay.json" || { echo "no answer through the XHTTP node"; adb shell run-as "$PKG" cat files/xray.log || true; exit 1; }
  grep -q "accepted" "$XRAY_LOG" || { echo "the XHTTP server saw nothing"; exit 1; }
  echo "XHTTP OK: the request went through the bundled Xray and the XHTTP server"
fi
python3 - "$OUT/connections.json" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))["connections"]
apps = sorted({x["metadata"].get("processPath", "").split(" (")[0] for x in c} - {""})
print("connections:", len(c), "apps seen by the monitor:", apps)
assert apps, "no connection was attributed to an app"
EOF

# let the monitor collect a few samples, then visit every tab
sleep 4
for t in "1:2-apps" "2:3-sites" "3:4-servers" "4:5-settings"; do
  tap_tab "${t%%:*}"
  sleep 2
  shot "${t##*:}"
  if [ "${t%%:*}" = 1 ]; then
    # scroll to the activity list, open the first app and look at its addresses
    size=$(adb shell wm size | tail -1 | sed 's/.*: //' | tr -d '\r'); w=${size%x*} h=${size#*x}
    adb shell input swipe $((w / 2)) $((h * 3 / 4)) $((w / 2)) $((h / 5)) 400
    sleep 2
    shot 2b-apps-activity
  fi
done
tap_tab 0
sleep 1
adb logcat -d > "$OUT/logcat.txt"
adb shell run-as "$PKG" cat files/sing-box.log > "$OUT/sing-box.log" || true
adb shell run-as "$PKG" cat files/xray.log > "$OUT/xray-client.log" || true
echo "e2e passed"
