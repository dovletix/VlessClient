# VlessClient — notes for Claude

Windows VPN client for VLESS subscriptions, aimed at non-technical users (one big button) with an "advanced" section for power users. Native C# (.NET Framework 4.8, WPF + WinForms tray), shipped as an MSI. This repository is public: never commit subscription links, server addresses, API secrets or anything from a user's machine. User-facing docs: `README.md`.

## Layout

- `src/VlessClient/` — one exe, several modes:
  - `--service`: the Windows service "VlessClient" (LocalSystem). `Service/Engine.cs` owns everything: subscription, node choice, cores, supervision. `Service/PipeServer.cs` exposes it on the named pipe `VlessClient.Control.v2` (one JSON request per line; any authenticated user may connect).
  - no args / `--tray`: the window and the tray icon (`Ui/`), non-elevated, talks to the service only through the pipe (`Ui/ServiceClient.cs`). One instance per session; a second start just shows the window.
  - `--cleanup`: run by the uninstaller (not on upgrade); deletes `C:\ProgramData\VlessClient`.
  - `--console`: development — engine + pipe inside this process (stop by creating `console.stop` in the data dir). With `VLESSCLIENT_DATA` / `VLESSCLIENT_BIN` it runs without installing anything; not elevated -> proxy-only mode.
  - `--snapshot <dir>`: development — renders every page off-screen to PNG (needs a running engine). Use it to check the UI without disturbing the user's desktop.
- `src/VlessClient/Core/` — settings, subscription parsing, xray / sing-box config builders (ported from the PowerShell edition), geo rule-sets (parser for Xray's geoip.dat / geosite.dat), network facts.
- `installer/` — WiX 4 package (`Package.wxs`), `build-msi.ps1` (cores from `cores.ps1`, pinned versions + SHA-256), `THIRD-PARTY.txt`.
- `.github/workflows/windows-msi.yml` — builds the MSI on every push; a `v*` tag also publishes a GitHub Release, which the in-app updater reads (`Service/Updater.cs`: releases/latest, the `.msi` asset and its `digest`).
- `legacy/` — the old PowerShell edition (`vpn.ps1`). Independent of the MSI; do not run both (two TUNs).

## Behaviour that matters

- Data: `C:\ProgramData\VlessClient` (settings.json, runtime\ configs and rule-sets, logs\). The service resets its ACL to SYSTEM + Administrators full, Users read: the service runs downloaded MSIs and generated configs as SYSTEM.
- The client never touches the Windows proxy settings. The window switches off a Windows proxy that points to a dead 127.0.0.1 port (`Ui/ProxyFix.cs`) — the classic leftover of Happ and similar apps.
- Cores run in a job object with KILL_ON_JOB_CLOSE: when the service dies, xray / sing-box die too and the Wintun adapter with its routes disappears. Verified by killing the engine process.
- Node choice: `node: "auto"` probes every node of the pool (separate xray, one SOCKS port per node, HTTP through each) and pins the fastest working one; the last good node is kept unless another is much faster. Never put several nodes into one balancer: new flows (a voice call) would hop to slow relays. The pinned node gets a spare via a one-candidate balancer with `fallbackTag`.
- Rule changes (apps, domains) are written to rule-set files that sing-box hot-reloads; mode / default route / node / Russia switch reconnect.
- IPv6 on the tunnel only when a physical adapter has a real global IPv6 address. Teredo (2001:0::/32 on a Tunnel-type interface) and 6to4 do not count: an IPv6 route on the tunnel without real IPv6 makes direct IPv6 connections hang.
- Updates: manual by default (button in Settings); `auto_update` makes the service check every 12 h and install. The service downloads the MSI from this repo's releases only, checks the SHA-256 digest and runs `msiexec /qn`; the window notices status "installing", schedules its own restart and exits; the MSI closes running copies (util:CloseApplication) so no reboot is needed.
- Ports (localhost): mixed proxy 12080, xray SOCKS 12081, Clash API 12090 (secret in settings), probe ports 12200+.

## Constraints

- Keep the UI text Russian and plain: the main audience cannot read technical messages.
- `legacy/*.ps1` must stay ASCII-only (Windows PowerShell 5.1).
- Build check before committing: `dotnet build src/VlessClient/VlessClient.csproj -c Release`; installer: `installer/build-msi.ps1`.
- Commits use the noreply identity configured in the repo; never the personal e-mail.
