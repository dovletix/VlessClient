# VlessClient — notes for Claude

Windows client for a VLESS subscription: `bin\xray.exe` (outbound to the subscription nodes, SOCKS on 127.0.0.1:20808) + `bin\sing-box.exe` (TUN `vless-tun`, routing rules, mixed proxy on 127.0.0.1:2080). User-facing docs: `README.md`.

This repository is public. `settings.json`, `bin\`, `runtime\` and `CLAUDE.local.md` are git-ignored and hold everything personal (subscription link, API secret, machine notes). Never move such data into tracked files; `settings.example.json` is the template for new users.

## How to control it

- Everything goes through `.\vpn.cmd <command>` (see `vpn help`) or by editing `settings.json` and running `.\vpn.cmd reload`.
- `runtime\xray.json` and `runtime\sing-box.json` are generated on every start/reload — never edit them, change the generator in `vpn.ps1` (`New-XrayConfig`, `New-SingboxConfig`).
- The daemon (`vpn.ps1 daemon`) is a long-running PowerShell that supervises both cores. It runs elevated via scheduled task `VlessClient` and is controlled from a non-elevated shell through flag files (`runtime\stop.flag`, `runtime\reload.flag`). After editing `vpn.ps1` itself, run `.\vpn.cmd restart` — `reload` keeps the old script code in memory.
- Validate without touching the running client: `.\vpn.cmd build tun` (generates configs, runs `xray -test` and `sing-box check`). Note it overwrites `runtime\*.json`; run `reload` afterwards if the client is up.
- To see which rule a connection hit: set `"log_level": "info"` in `settings.json`, reload, read `runtime\sing-box.log`, then set it back to `warn`.
- `setup.ps1` downloads the cores (versions and SHA-256 are pinned at the top of the file) and creates `settings.json`. When bumping a core version, update the hash and re-run `vpn build tun` and `vpn test`.

## Rules, apps and the web UI

- User lists live in `runtime\rules\*.json` (sing-box local rule-sets, written by `Write-RuleSets`). sing-box hot-reloads them, so `vpn add/remove` and the UI apply without a restart. Structural changes (mode, default, node, `ru_direct`) still need `reload`.
- A rule change only affects new connections, so every change also cuts the affected live connections through the Clash API (`Close-ProcConnections` for apps, `Close-HostConnections` for domain/IP lists), ~400 ms after writing the rule-set: sing-box needs up to ~100 ms to pick up the file, and an app that reconnects sooner lands on the old route.
- The UI server should run non-elevated. `vpn ui` from an admin shell starts it through Explorer (`ui\start-server.cmd`) for that reason. `vpn ui restart` first tries to stop the server itself and, if it survives (it is elevated), drops `runtime\ui-kill.flag` so that the elevated daemon kills it.
- UI statistics (`Update-ConnStats`, 1 s tick): per exe totals, bytes split by route (`pBytes` VPN / `dBytes` direct), smoothed speeds (`r*`, bytes per second) and a per-destination map (`hosts`); everything counts from the UI server start. The page (`ui\index.html`) sorts by any column and shows speeds in Mbit/s.
- `settings.json` -> `apps`: named exe groups with `vpn: true|false` (true = through VLESS, false = direct).
- `ru_direct`: geoip/geosite categories extracted from `bin\geoip.dat` / `bin\geosite.dat` by the embedded C# parser (`Export-GeoRules`, cached by `runtime\rules\geo.stamp`). `blocked_geosite` goes to VPN and is checked before the Russian direct rule.
- Web UI: `.\vpn.cmd ui` starts `vpn.ps1 ui-server` (non-elevated, http://localhost:2090/, page in `ui\index.html`, exits after 15 idle minutes). After editing `vpn.ps1` run `.\vpn.cmd ui restart`. Per-exe statistics come from the sing-box Clash API (`settings.json` -> `api`) and exist only while the UI server runs.

## Nodes and real-time traffic (voice, games)

- UDP rides inside TCP (VLESS), so node choice decides voice quality. `vpn quality [sec]` measures UDP loss / latency / jitter (STUN every 50 ms) through every node in a separate xray; `vpn quality live [sec]` probes the running client at three stages (xray only, sing-box proxy, TUN). Compare stages to find which part adds jitter.
- Do not mix good and bad nodes in one balancer. With `node: auto` xray's `leastPing` sends every new flow to whichever node probes fastest at that moment; when the good nodes are busy, new flows (a voice channel is a new UDP flow) land on slow relay nodes. Keep such nodes out with `auto_exclude` (regex on the node name), or pin a node.
- A single pinned node gets a spare automatically: `New-XrayConfig` builds a one-candidate balancer whose `fallbackTag` is the first other node of the auto group, so traffic never hops but survives a dead node (`node_fallback: "off"` disables it).

## IPv6

- `tun.ipv6` = `auto` (default) adds the IPv6 address to the TUN only when a physical adapter has a global IPv6 address (`Test-NativeIPv6`). Without native IPv6 an IPv6 route on the TUN makes apps connect over IPv6 (some DNS servers hand out AAAA anyway): proxied traffic works, direct traffic hangs for 5 s (`dial tcp [2001:...]:443: i/o timeout` in `sing-box.log`).
- Do not "reject" direct IPv6 by rule instead: the TUN accepts the TCP handshake before routing (sniff), so apps see a connected-then-closed socket and do not fall back to IPv4.

## Performance

- Direct traffic through the TUN reaches the same speed as traffic that bypasses it (`curl --interface <LAN IP>` bypasses the TUN and is a handy baseline).
- sing-box spends noticeably more CPU on direct traffic than on proxied traffic (mostly kernel time). `stack` mixed/gvisor/system made no difference in tests; MTU 9000 vs 1500 was a small gain. Every such experiment needs `reload`, which cuts all connections.

## Constraints

- `vpn.ps1` and `setup.ps1` must stay ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI. No PowerShell 7 syntax (`?:`, `??`, `&&`).
- Functions that return arrays use `return , $x`; do not wrap those calls in `@(...)` (it nests the array).
- Coexistence with a corporate VPN: keep `strict_route` off and keep private ranges in `tun.exclude_routes`. The `checkpoint` section (off by default) adds a process rule, IPsec ports and the detected gateway for Check Point Endpoint Security.
- `install`/`uninstall` need elevation (UAC prompt shown to the user).
