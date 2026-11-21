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
- Rule changes (apps, domains) are written to rule-set files that sing-box hot-reloads; default route / node / Russia switch reconnect.
- The tunnel is the only mode. The mixed proxy on 12080 always runs next to it (the connect check goes through it, and apps that support a proxy may use it); only a non-elevated `--console` run has no TUN.
- IPv6 on the tunnel only when a physical adapter has a real global IPv6 address. Teredo (2001:0::/32 on a Tunnel-type interface) and 6to4 do not count: an IPv6 route on the tunnel without real IPv6 makes direct IPv6 connections hang.
- Updates: manual by default (button in Settings); `auto_update` makes the service check every 12 h and install. The service downloads the MSI from this repo's releases only, checks the SHA-256 digest and runs `msiexec /qn`; the window notices status "installing", schedules its own restart and exits; the MSI closes running copies (util:CloseApplication) so no reboot is needed.
- Ports (localhost): mixed proxy 12080, xray SOCKS 12081, Clash API 12090 (secret in settings), probe ports 12200+.

## Window look and the "Процессы" monitor

- The design follows the web UI of the PowerShell edition (`ui/index.html` of that edition): same palette, pills, switches, chips, process table. `Ui/Theme.cs` holds the dark (default) and light palettes and puts them into `Application.Resources`; the choice is stored in `HKCU\Software\VlessClient\Theme`. Every colour in XAML is a `DynamicResource` with those keys (Bg, Panel, Text, Muted, Line, Accent, Ok, Bad, Warn, their *Soft variants, Chip, Track, Hover, Overlay); never hard-code colours, and never give a style a key that is also a colour key (a `Panel` style once shadowed the `Panel` brush and crashed the window).
- A TabItem's content inherits the TabItem's own Foreground / FontWeight (logical tree), so the tab style sets them to normal text and styles only the header's ContentPresenter.
- `Ui/Traffic.cs` is a port of the web UI's `Update-ConnStats` / `Read-NewLogErrors`: polls the Clash API `/connections` every second (off the UI thread), keeps per-exe and per-host byte counters and speeds, flags a connection that sent data but got no byte back as "no answer" (UDP counted apart), and attributes `ERROR ... open connection to X using outbound/...[tag]: reason` lines of `logs\sing-box.log` to the exe that last connected to X. Polling misses connections that open and close between two samples (short direct requests), like the web UI did.
- `Ui/ProcRow.cs` is one table row; rows are updated in place and reordered with `ObservableCollection.Move`, so expanded rows and tooltips survive the 1 s refresh.
- Snapshots: `VLESSCLIENT_THEME=light` renders the light theme; the snapshot mode never shows message boxes.

## Smart App Control

- Windows 11 Smart App Control (`HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy` `VerifiedAndReputablePolicyState`: 0 off, 1 on, 2 evaluation) blocks our unsigned VlessClient.exe: SCM error 7000 "application control policy has blocked this file", CodeIntegrity 3077, and Windows Installer reports the misleading error 1920 ("insufficient privileges to start system services") and rolls back with 1603.
- `installer/Package.wxs` has a launch condition that refuses to install while the state is 1 and tells the user how to switch it off. The only real fix is code signing — and xray / sing-box are unsigned upstream, so signing only our exe may not be enough.

## Removed modes (history)

- 2.0 had a "local proxy only" mode and 2.1.0 a "selected programs only" mode without TUN (ProxiFyre, wiresock, AGPL, on the Windows Packet Filter NDIS driver `NDISRD`). Both were removed in 2.2.0: they existed because the tunnel looked like a speed bottleneck, and it was not — the cap was the line. sing-box carries ~670 Mbit/s of direct traffic through the TUN on about one core of a desktop CPU. Do not bring them back for speed reasons.
- `Service/OldComponents.cs` cleans up after 2.1.0: on service start (and on uninstall, detached) it stops `ProxiFyreService`, disables it and runs `msiexec /x` for the product codes recorded in `components\installed-by-vlessclient.json` (ProxiFyre first, then the driver; retries while our own upgrade transaction holds the installer, error 1618). Only those products, never a copy the user installed. Remove this class once 2.1.0 is long gone.
- An old `settings.json` with `"mode": "apps"` / `"proxy"` or `ports.apps` loads fine; the keys are ignored and dropped on the next save.
- WinDivert was rejected for packet interception: Microsoft Defender (PUA protection) deletes even the official release as `Misleading:Win32/Malgent!AMTB`; bundling it would get the whole MSI quarantined.

## Testing on the developer's machine

- The developer's own VPN client must keep running during tests: the Claude app reaches the API only through it. Run the new engine side by side with `--console`, `VLESSCLIENT_DATA` / `VLESSCLIENT_BIN` and its own ports, and tell test traffic apart through the test engine's Clash API (`metadata.type`, e.g. `mixed/mixed-in`), not by exit IP.
- Speed baselines: `curl --interface <LAN IP>` bypasses the TUN. Before blaming the tunnel for a speed cap, compare with that baseline and with a phone on the same Wi-Fi.

## Constraints

- Keep the UI text Russian and plain: the main audience cannot read technical messages.
- `legacy/*.ps1` must stay ASCII-only (Windows PowerShell 5.1).
- Build check before committing: `dotnet build src/VlessClient/VlessClient.csproj -c Release`; installer: `installer/build-msi.ps1`.
- Commits use the noreply identity configured in the repo; never the personal e-mail.
