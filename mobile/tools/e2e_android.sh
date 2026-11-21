#!/usr/bin/env bash
# End-to-end check on an Android emulator (run by .github/workflows/mobile.yml):
# a throw-away VLESS server runs on the CI host (10.0.2.2 from the emulator), the debug APK imports it
# through a vlessclient://add/ link, connects, and the test checks that sing-box picked the node,
# that traffic from the phone reaches the server through the tunnel, and takes screenshots of every tab.
# With a fifth argument (the access log of an Xray XHTTP server on port 10444) it also checks the XHTTP path
# through the app's bundled Xray; with REALITY_PBK set (an Xray Reality + Vision server on port 10445, the
# public key) the Reality path, which goes through the bundled Xray as well.
# At the end it stops the app (the VPN goes down with it) and checks the servers with "Проверить" while the
# tunnel is off.
# usage: [REALITY_PBK=<key>] e2e_android.sh <apk> <server uuid> <server log> <out dir> [xray access log]
set -euo pipefail
APK=$1 UUID=$2 SERVER_LOG=$3 OUT=$4 XRAY_LOG=${5:-}
PBK=${REALITY_PBK:-}
PKG=io.github.dovletix.vlessclient
mkdir -p "$OUT"

shot() { adb exec-out screencap -p > "$OUT/$1.png"; }

# taps the element whose label is exactly $1, found through uiautomator; works only while the screen is still
tap_text() {
  timeout 30 adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1 || return 1
  adb shell cat /sdcard/ui.xml > "$OUT/ui.xml" 2> /dev/null || return 1
  local xy
  xy=$(python3 - "$OUT/ui.xml" "$1" <<'EOF'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for node in re.findall(r"<node [^>]*>", xml):
    if f'content-desc="{sys.argv[2]}"' in node or f'text="{sys.argv[2]}"' in node:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if b:
            x1, y1, x2, y2 = map(int, b.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            break
EOF
)
  [ -n "$xy" ] || return 1
  # shellcheck disable=SC2086
  adb shell input tap $xy
}

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
[ -z "$PBK" ] || LINK="$LINK"$'\n'"vless://$UUID@10.0.2.2:10445?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=www.google.com&pbk=$PBK&sid=0123abcd#CI%20reality"
# node tags follow the order: node-01 plain, node-02 XHTTP, node-03 Reality
REALITY_TAG=node-03
[ -n "$XRAY_LOG" ] || REALITY_TAG=node-02
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
assert p.get("now") in ("node-01", "node-02", "node-03"), "the proxy group did not pick a CI server"
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
if [ -n "$PBK" ]; then
  # Reality + Vision: sing-box -> local SOCKS -> bundled Xray -> the Reality server (Xray 26.11, refuses sing-box itself)
  curl -sS -H "Authorization: Bearer $SECRET" "http://127.0.0.1:12090/proxies/$REALITY_TAG/delay?timeout=10000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" > "$OUT/reality-delay.json" || true
  cat "$OUT/reality-delay.json"; echo
  grep -q '"delay"' "$OUT/reality-delay.json" || { echo "no answer through the Reality node"; adb shell run-as "$PKG" cat files/xray.log || true; exit 1; }
  echo "Reality OK: the request went through the bundled Xray and the Reality server"
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
adb shell run-as "$PKG" cat files/sing-box.log > "$OUT/sing-box.log" || true
adb shell run-as "$PKG" cat files/xray.log > "$OUT/xray-client.log" || true

# "Проверить" while the VPN is off: a sing-box with only the nodes (no TUN) measures them
adb shell am force-stop "$PKG"
for i in $(seq 1 10); do adb shell ip link 2> /dev/null | grep -q tun || break; sleep 1; done
adb shell ip link 2> /dev/null | grep -q tun && { echo "the tunnel is still up after the app was stopped"; exit 1; }
adb shell run-as "$PKG" rm -f files/probe.json files/last-check.json
adb shell am start -W -n "$PKG/.MainActivity"
sleep 5
tap_tab 3
sleep 3
shot 6-servers-off
if tap_text "Проверить"; then
  echo "tapped the check button (uiautomator)"
else
  # fallback: the button sits at the top right, below the status bar (24 or 48 dp)
  size=$(adb shell wm size | tail -1 | sed 's/.*: //' | tr -d '\r'); w=${size%x*}
  dens=$(adb shell wm density | tail -1 | sed 's/.*: //' | tr -d '\r')
  for top in 24 48 36; do
    adb shell input tap "$(python3 -c "print(int($w - 80 * $dens / 160))")" "$(python3 -c "print(int(($top + 32) * $dens / 160))")"
    sleep 2
    if adb shell run-as "$PKG" ls files/probe.json > /dev/null 2>&1; then echo "tapped the check button at ${top} dp"; break; fi
  done
fi
done_check=0
for i in $(seq 1 40); do
  sleep 1
  adb shell ip link 2> /dev/null | grep -q tun && { echo "a tunnel came up during the check"; exit 1; }
  if adb shell run-as "$PKG" cat files/last-check.json > "$OUT/last-check.json" 2> /dev/null && [ -s "$OUT/last-check.json" ]; then done_check=1; break; fi
done
sleep 2
shot 7-servers-checked
adb shell run-as "$PKG" cat files/probe.log > "$OUT/probe.log" 2> /dev/null || true
adb shell run-as "$PKG" cat files/xray-probe.log > "$OUT/xray-probe.log" 2> /dev/null || true
[ "$done_check" = 1 ] || { echo "the check without the tunnel did not finish"; adb logcat -d > "$OUT/logcat.txt"; exit 1; }
python3 - "$OUT/last-check.json" "${XRAY_LOG:+node-02}" "${PBK:+$REALITY_TAG}" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
print("check without the tunnel:", c)
assert c["tunnel"] is False, "the check ran through a tunnel"
for t in ["node-01"] + [t for t in sys.argv[2:] if t]:
    assert c["delays"].get(t), f"{t} did not answer the check without the tunnel"
EOF
sleep 3
adb shell ps -A | grep -q libxray && { echo "the Xray of the check is still running after it ended"; exit 1; }
echo "check without the tunnel OK"
adb logcat -d > "$OUT/logcat.txt"
echo "e2e passed"
